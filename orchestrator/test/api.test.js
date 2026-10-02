// orchestrator/test/api.test.js — FR-08 integration tests (node:test).
// ---------------------------------------------------------------------------
// Runs WITHOUT Docker: a stub `docker` CLI and a stub provision.sh are placed
// on PATH / in a sandboxed repo copy, so create/status/teardown routes are
// exercised end-to-end. Exit criterion for FR-08: "REST endpoints exist and
// are covered by integration tests for create/status/teardown".
//   run: node --test orchestrator/test/
'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

// ---- sandbox: fake docker + fake provision.sh -------------------------------
let tmp, binDir, server, baseUrl, STATE_DIR;

before(async () => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lc-test-'));
  binDir = path.join(tmp, 'bin'); fs.mkdirSync(binDir);
  STATE_DIR = path.join(tmp, 'state'); fs.mkdirSync(STATE_DIR, { recursive: true });

  // stateful fake docker: containers recorded in $tmp/docker-state.json
  // Stateful fake docker CLI (python-backed for robust JSON manipulation).
const fakeDockerPy = String.raw`
import json, os, sys
S = os.environ["FAKE_DOCKER_STATE"]
st = json.load(open(S)) if os.path.exists(S) else {"containers": {}, "nets": {}}
def cinfo(n):
    c = st["containers"][n]
    return c if isinstance(c, dict) else {}
def save(): json.dump(st, open(S, "w"))
argv = sys.argv[1:]
cmd = argv[0]; rest = argv[1:]
if cmd == "rm":
    for n in rest:
        if n != "-f": st["containers"].pop(n, None)
elif cmd == "network":
    if rest and rest[0] == "create": st["nets"][rest[1]] = 1
    elif rest and rest[0] == "rm":   st["nets"].pop(rest[1], None)
elif cmd == "ps":
    print(chr(10).join(st["containers"]))
elif cmd == "inspect":
    fmt = ""
    names = []
    i = 0
    while i < len(rest):
        if rest[i] == "-f": fmt = rest[i+1]; i += 2; continue
        names.append(rest[i]); i += 1
    missing = [n for n in names if n not in st["containers"]]
    if missing:
        sys.stderr.write(("Error: No such object: %s" % missing[0]) + chr(10)); sys.exit(1)
    for n in names:
        c = cinfo(n)
        hc = c.get("HostConfig", {})
        if "NanoCpus" in fmt:
            print("%s %s %s %s" % (hc.get("Memory",""), hc.get("MemorySwap",""), hc.get("NanoCpus",""), hc.get("PidsLimit","")))
        elif ".State.Cgroupns" in fmt:
            print("default %s-id" % n)
        elif ".State.Health" in fmt and ".State.Status" not in fmt:
            # provision.sh wait_ready polls a HEALTH-ONLY format
            # ('{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
            # — fake containers carry a healthcheck, so report healthy
            # immediately. api.js's status format embeds .State.Health too, but
            # also asks for .State.Status, so it falls through to the
            # name/state/health triple below instead of hitting this branch.
            print("healthy")
        else:
            print("/%s running healthy" % n)
elif cmd == "run":
    if "--name" in argv:
        h = {}
        for flag, key in [("--memory","Memory"),("--memory-swap","MemorySwap"),("--cpus","NanoCpus"),("--pids-limit","PidsLimit")]:
            if flag in argv:
                v = argv[argv.index(flag)+1]
                if key=="NanoCpus": h[key]=int(float(v)*1e9)
                elif key=="PidsLimit": h[key]=int(v)
                else:
                    b=int(v[:-1])*1024*1024 if v.endswith("m") else int(v)
                    h[key]=b
        st["containers"][argv[argv.index("--name") + 1]] = {"HostConfig": h}
elif cmd == "exec":
    # exec <container> sh -c "<accumulate rx_bytes>" -> fake: 1 MB per container
    cid = rest[0] if rest else ""
    print(1000000 + st["containers"].get(cid, {}).get("_rxoff", 0) if isinstance(st["containers"].get(cid), dict) else 1000000)
save()
`;
fs.writeFileSync(path.join(tmp, 'fake_docker.py'), fakeDockerPy);
const fakeDocker = `#!/usr/bin/env bash
exec python3 "$FAKE_DOCKER_PY" "$@"
`;
  process.env.FAKE_DOCKER_PY = path.join(tmp, 'fake_docker.py');
  const dockerPath = path.join(binDir, 'docker');
  fs.writeFileSync(dockerPath, fakeDocker, { mode: 0o755 });

  // sandbox orchestrator dir gets the REAL provision.sh (talks to fake docker)
  const provPath = path.join(tmp, 'orchestrator'); fs.mkdirSync(provPath, { recursive: true });
  fs.copyFileSync(path.join(__dirname, '..', 'provision.sh'), path.join(provPath, 'provision.sh'));
  // digests file: provision.sh sources images/digests.env from ROOT — provide it
  fs.mkdirSync(path.join(tmp, 'images'), { recursive: true });
  fs.writeFileSync(path.join(tmp, 'images', 'digests.env'),
    'WEB_EXPLOITATION_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"\nNETWORK_RECON_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"\nPASSWORD_ATTACKS_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"\nTARGET_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"\nBASE_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"\n');

  // api.js resolves config+scripts under HERE; point HERE at the sandboxed
  // orchestrator dir (fake provision.sh already written there above).
  const linkSrc = provPath;
  for (const f of ['limits.env', 'lifecycle.env']) {
    fs.copyFileSync(path.join(__dirname, '..', f), path.join(linkSrc, f));
  }

  process.env.STATE_DIR = STATE_DIR;
  process.env.WARN_LOG = path.join(STATE_DIR, 'warnings.log');
  process.env.FAKE_DOCKER_STATE = path.join(tmp, 'docker-state.json');
  fs.writeFileSync(process.env.FAKE_DOCKER_STATE, '{"containers":{},"nets":{}}');
  process.env.PATH = `${binDir}:${process.env.PATH}`;
  process.env.PORT = '0';

  // ORCH_HOME makes api.js read the sandbox dir; lib/ must sit beside it.
  const shimCopy = path.join(linkSrc, 'lib'); fs.mkdirSync(shimCopy, { recursive: true });
  fs.copyFileSync(path.join(__dirname, '..', 'lib', 'http_shim.js'), path.join(shimCopy, 'http_shim.js'));
  process.env.ORCH_HOME = linkSrc;
  process.env.PROVISION_BIN = path.join(linkSrc, 'provision.sh');
  // POST /sessions drives the REAL provision.sh against the fake docker CLI

  const mod = require(path.join(__dirname, '..', 'api.js'));
  server = http.createServer(mod.app.handler());
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(() => { if (server) server.close(); });

function req(method, p, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(p, baseUrl);
    const data = body ? JSON.stringify(body) : null;
    const r = http.request(u, { method, headers: data ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) } : {} },
      (res) => { let b = ''; res.on('data', (c) => (b += c)); res.on('end', () => resolve({ status: res.statusCode, json: b ? JSON.parse(b) : null })); });
    r.on('error', reject);
    if (data) r.write(data);
    r.end();
  });
}

test('GET /health', async () => {
  const r = await req('GET', '/health');
  assert.equal(r.status, 200); assert.equal(r.json.ok, true);
});

test('POST /sessions rejects unknown bundle', async () => {
  const r = await req('POST', '/sessions', { bundle: 'nope', id: '9' });
  assert.equal(r.status, 400);
});

test('POST /sessions rejects missing id', async () => {
  const r = await req('POST', '/sessions', { bundle: 'web-exploitation' });
  assert.equal(r.status, 400);
});

test('create → status → teardown lifecycle (FR-08)', async () => {
  const c = await req('POST', '/sessions', { bundle: 'network-recon', id: '42' });
  assert.equal(c.status, 201, JSON.stringify(c.json));
  assert.equal(c.json.status, 'ready');

  const s = await req('GET', '/sessions/42');
  assert.equal(s.status, 200);
  assert.equal(s.json.status, 'ready');
  assert.equal(s.json.containers.length, 2);
  assert.match(s.json.limits.attacker, /512m\/1\.0cpu\/100pids/);   // from limits.env SSoT
  assert.equal(s.json.reaper.grace_s, 120);                          // from lifecycle.env SSoT

  const l = await req('GET', '/sessions');
  assert.ok(l.json.sessions.includes('42'));

  const d = await req('DELETE', '/sessions/42');
  assert.equal(d.status, 200);
  assert.equal(d.json.status, 'torn-down');

  const g = await req('GET', '/sessions/42');
  assert.equal(g.status, 404);
});

test('GET /sessions/:id/events returns audit events (FR-10 surface)', async () => {
  const mod = require(path.join(__dirname, '..', 'api.js'));
  fs.writeFileSync(mod.WARN_LOG,
    '{"event":"idle_warning","session":"7"}\n{"event":"idle_warning","session":"8"}\n');
  const r = await req('GET', '/sessions/7/events');
  assert.equal(r.status, 200);
  assert.equal(r.json.events.length, 1);
  assert.equal(r.json.events[0].event, 'idle_warning');
});

// ---- FR-18 per-lab SSH opt-in through the lifecycle API --------------------
test('POST /sessions rejects non-boolean ssh field (FR-18 validation)', async () => {
  const r = await req('POST', '/sessions', { bundle: 'web-exploitation', id: 'ssh-bad', ssh: 'yes' });
  assert.equal(r.status, 400);
  assert.match(r.json.error, /boolean/);
});

test('POST /sessions accepts ssh:true and reports it back (FR-18 opt-in)', async () => {
  // PROVISION_STUB is NOT set in this suite — the real provision.sh runs
  // against the fake docker; we only need the create response to echo the
  // opt-in. Teardown keeps the sandbox clean.
  const c = await req('POST', '/sessions', { bundle: 'network-recon', id: 'ssh-ok', ssh: true });
  assert.equal(c.status, 201, JSON.stringify(c.json));
  assert.equal(c.json.ssh_enabled, true);
  await req('DELETE', '/sessions/ssh-ok');
});

test('POST /sessions without ssh defaults to opt-out (ssh_enabled:false)', async () => {
  const c = await req('POST', '/sessions', { bundle: 'web-exploitation', id: 'ssh-off' });
  assert.equal(c.status, 201, JSON.stringify(c.json));
  assert.equal(c.json.ssh_enabled, false);
  await req('DELETE', '/sessions/ssh-off');
});

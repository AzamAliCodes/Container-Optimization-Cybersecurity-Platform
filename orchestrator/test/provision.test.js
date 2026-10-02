// orchestrator/test/provision.test.js — regression tests for the target-CMD
// blank-argument bug ("ttyd: missing start command").
// ---------------------------------------------------------------------------
// Background: docker treats ANY trailing argument after the image name as a
// CMD override — even a single empty string. When provision.sh expanded an
// empty TARGET_CMD array into one blank word (e.g. "${TARGET_CMD[*]}" or a
// quoted "$@" pass-through), the target container got Config.Cmd = [""] and
// images/shared/entrypoint.sh exec'd ttyd with no start command → the target
// exited. The fix: ${TARGET_CMD[@]+"${TARGET_CMD[@]}"} — the `set -u`-safe
// idiom that expands to ZERO words for an empty array.
//
// These tests run WITHOUT Docker: a stateful fake docker CLI records every
// argv it receives, so we can assert exactly what `docker run` was handed.
//   run: node --test orchestrator/test/
'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ORCH = path.join(__dirname, '..');

// ---- fake docker CLI (python-backed, stateful, logs every invocation) ------
// Records each `docker run` argv list in $FAKE_DOCKER_LOG (one JSON array per
// line) and stores containers keyed by --name, with Config.Cmd set to whatever
// trailed the image token — i.e. exactly what real docker would record as the
// CMD override. `docker image inspect` answers from the "images" map in the
// state file; health/state formats answer "healthy"/"true" so wait_ready()
// passes without a live daemon.
const FAKE_DOCKER_PY = String.raw`
import json, os, sys
S = os.environ["FAKE_DOCKER_STATE"]
LOG = os.environ.get("FAKE_DOCKER_LOG", "")
st = json.load(open(S)) if os.path.exists(S) else {"containers": {}, "nets": {}, "images": {}}
st.setdefault("images", {})
def save(): json.dump(st, open(S, "w"))
argv = sys.argv[1:]
if LOG:
    with open(LOG, "a") as f: f.write(json.dumps(argv) + chr(10))
cmd = argv[0]; rest = argv[1:]
# flags whose value must not be mistaken for the image token in a docker run
VALFLAGS = {"--name","--network","--label","--memory","--memory-swap",
            "--cpus","--pids-limit","--entrypoint","--format","-f","-w"}
def is_image_token(a, i):
    return (i > 0 and not a[i].startswith("-")
            and a[i] in ("local/target:dev", "local/web-exploitation:dev",
                         "local/network-recon:dev", "local/password-attacks:dev")
            and a[i-1] not in VALFLAGS)
if cmd == "image" and rest[:1] == ["inspect"]:
    img = rest[-1]
    print(json.dumps(st["images"].get(img, {}).get("Cmd")))
elif cmd == "rm":
    for n in rest:
        if n != "-f": st["containers"].pop(n, None)
elif cmd == "network":
    if rest and rest[0] == "create": st["nets"][rest[1]] = 1
    elif rest and rest[0] == "rm":   st["nets"].pop(rest[1], None)
elif cmd == "ps":
    print(chr(10).join(st["containers"]))
elif cmd == "logs":
    # fake target never logged the ttyd failure (no blank CMD override given)
    pass
elif cmd == "inspect":
    fmt = ""; names = []; i = 0
    while i < len(rest):
        if rest[i] in ("-f", "--format"): fmt = rest[i+1]; i += 2; continue
        names.append(rest[i]); i += 1
    for n in names:
        c = st["containers"].get(n, {})
        hc = c.get("HostConfig", {}); cfg = c.get("Config", {})
        if "NanoCpus" in fmt:
            print("%s %s %s %s" % (hc.get("Memory",""), hc.get("MemorySwap",""),
                                   hc.get("NanoCpus",""), hc.get("PidsLimit","")))
        elif ".Config.Cmd" in fmt:
            print(json.dumps(cfg.get("Cmd")))
        elif "Health.Status" in fmt:
            print("healthy")
        elif ".State.Running" in fmt:
            print("true")
        else:
            print("/%s running healthy" % n)
elif cmd == "run":
    name = argv[argv.index("--name")+1] if "--name" in argv else "anon"
    idx = next((i for i in range(1, len(argv)) if is_image_token(argv, i)), None)
    after = argv[idx+1:] if idx is not None else []
    entry = {"HostConfig": {}, "Config": {"Cmd": after}}
    for flag, key in [("--memory","Memory"),("--memory-swap","MemorySwap"),
                      ("--cpus","NanoCpus"),("--pids-limit","PidsLimit")]:
        if flag in argv:
            v = argv[argv.index(flag)+1]
            if key == "NanoCpus": entry["HostConfig"][key] = int(float(v)*1e9)
            elif key == "PidsLimit": entry["HostConfig"][key] = int(v)
            else: entry["HostConfig"][key] = int(v[:-1])*1024*1024 if v.endswith("m") else int(v)
    st["containers"][name] = entry
save();
`;

const DIGESTS = [
  'WEB_EXPLOITATION_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"',
  'NETWORK_RECON_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"',
  'PASSWORD_ATTACKS_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"',
  'TARGET_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"',
  'BASE_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"',
].join('\n') + '\n';

// Run the REAL provision.sh against the fake docker. Returns
// { status, stdout, stderr, calls (logged argv lists), state }.
function provision(sessionId, imageCmd) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'prov-test-'));
  const binDir = path.join(tmp, 'bin'); fs.mkdirSync(binDir);
  fs.writeFileSync(path.join(tmp, 'fake_docker.py'), FAKE_DOCKER_PY);
  fs.writeFileSync(path.join(binDir, 'docker'),
    '#!/usr/bin/env bash\nexec python3 "$FAKE_DOCKER_PY" "$@"\n', { mode: 0o755 });

  // sandbox repo layout: provision.sh resolves ROOT relative to its own dir
  const orchDir = path.join(tmp, 'orchestrator'); fs.mkdirSync(orchDir, { recursive: true });
  fs.copyFileSync(path.join(ORCH, 'provision.sh'), path.join(orchDir, 'provision.sh'));
  fs.copyFileSync(path.join(ORCH, 'limits.env'), path.join(orchDir, 'limits.env'));
  fs.mkdirSync(path.join(tmp, 'images'), { recursive: true });
  fs.writeFileSync(path.join(tmp, 'images', 'digests.env'), DIGESTS);

  const stateFile = path.join(tmp, 'docker-state.json');
  const logFile = path.join(tmp, 'docker-calls.jsonl');
  fs.writeFileSync(stateFile, JSON.stringify({
    containers: {}, nets: {},
    images: imageCmd === null ? {} : { 'local/target:dev': { Cmd: imageCmd } },
  }));

  const env = { ...process.env,
    PATH: `${binDir}:${process.env.PATH}`,
    FAKE_DOCKER_PY: path.join(tmp, 'fake_docker.py'),
    FAKE_DOCKER_STATE: stateFile,
    FAKE_DOCKER_LOG: logFile,
    REGISTRY: 'local', VERSION: 'dev', KEEP_RUNNING: '1' };
  const r = spawnSync('bash', [path.join(orchDir, 'provision.sh'), 'web-exploitation', sessionId], {
    env, encoding: 'utf8',
  });

  const calls = fs.existsSync(logFile)
    ? fs.readFileSync(logFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l))
    : [];
  const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  return { status: r.status, stdout: r.stdout, stderr: r.stderr, calls, state, env };
}

function targetRunCall(calls, sessionId) {
  const runs = calls.filter((a) => a[0] === 'run' && a.includes(`sess-${sessionId}-target`));
  assert.equal(runs.length, 1, 'exactly one docker run for the target container');
  const argv = runs[0];
  const imgIdx = argv.indexOf('local/target:dev');
  assert.ok(imgIdx > 0, 'image name present in docker run argv');
  return argv.slice(imgIdx + 1); // trailing args = what docker records as CMD override
}

test('provision.sh passes ZERO trailing args when the target image has a default CMD', () => {
  const IMG_CMD = ['sh', '-c', 'php -r \'$pdo=new PDO("sqlite:/var/www/html/data/app.db");\' ; exec php -S 0.0.0.0:${TARGET_PORT:-8080} -t /var/www/html'];
  const t = targetRunCall(provision('a1', IMG_CMD).calls, 'a1');
  // THE regression assertion: no "" (or anything else) may trail the image —
  // any single trailing arg, even empty, overrides the built-in CMD and makes
  // ttyd die with "missing start command".
  assert.deepEqual(t, [], `expected zero args after image name, got ${JSON.stringify(t)}`);
});

test('provisioned target .Config.Cmd is never [""] (fake docker inspect)', () => {
  const IMG_CMD = ['sh', '-c', 'php -S 0.0.0.0:8080 -t /var/www/html'];
  const r = provision('a2', IMG_CMD);
  assert.equal(r.status, 0, `provision failed: ${r.stderr}`);
  const tgt = r.state.containers['sess-a2-target'];
  assert.ok(tgt, 'target container recorded by fake docker');
  assert.notDeepEqual(tgt.Config.Cmd, [''], 'Config.Cmd must not be the blank override [""]');
  assert.equal(tgt.Config.Cmd.length, 0, 'no CMD override sent → image default survives');
  // and via `docker inspect -f {{json .Config.Cmd}}` on the provisioned target:
  const inspected = spawnSync('docker', ['inspect', '-f', '{{json .Config.Cmd}}', 'sess-a2-target'], {
    env: r.env, encoding: 'utf8' });
  assert.equal(inspected.status, 0, inspected.stderr);
  assert.notDeepEqual(JSON.parse(inspected.stdout.trim()), [''],
    'inspected Config.Cmd must never be the single-empty-string override');
});

test('target reaches healthy and logs contain no "missing start command"', () => {
  const IMG_CMD = ['sh', '-c', 'php -S 0.0.0.0:8080 -t /var/www/html'];
  const r = provision('a3', IMG_CMD);
  assert.equal(r.status, 0, `provision failed: ${r.stderr}`);
  assert.match(r.stdout, /both containers healthy/);
  const logs = spawnSync('docker', ['logs', 'sess-a3-target'], { env: r.env, encoding: 'utf8' });
  assert.equal(logs.status, 0, logs.stderr);
  assert.doesNotMatch(logs.stdout + logs.stderr, /missing start command/);
});

test('image without a default CMD still gets the canonical fallback CMD verbatim', () => {
  // Regression guard the other way: the ${TARGET_CMD[@]+"..."} idiom must
  // expand a NON-empty array into exactly its elements, each as its own word.
  const r = provision('a4', null); // image inspect returns null → fallback branch
  assert.equal(r.status, 0, `provision failed: ${r.stderr}`);
  const t = targetRunCall(r.calls, 'a4');
  assert.equal(t.length, 3, `fallback CMD should be 3 words, got ${JSON.stringify(t)}`);
  assert.equal(t[0], 'sh');
  assert.equal(t[1], '-c');
  assert.match(t[2], /exec php -S 0\.0\.0\.0:/);
});

// ---- FR-18 per-lab SSH opt-in: provisioning-path behaviour tests ------------
// The static wiring gate lives in ci/smoke.sh step 13; these tests prove the
// RUNTIME resolution order (explicit env > lab-config ssh_enabled > default 0)
// by running the REAL provision.sh against the fake docker and inspecting the
// recorded `docker run` argv for the attacker container.
function attackerEnv(calls, sessionId, key) {
  const runs = calls.filter((a) => a[0] === 'run' && a.includes(`sess-${sessionId}-attacker`));
  assert.equal(runs.length, 1, 'exactly one docker run for the attacker container');
  const argv = runs[0];
  let prev = '';
  for (const tok of argv) {
    if (prev === '--env' && tok.startsWith(`${key}=`)) return tok.split('=')[1];
    prev = tok;
  }
  return undefined;
}

// Sandbox an extra repo dir so we can drop a lab-config under test without
// touching the real lab-configs/ (provision.sh reads $ROOT/lab-configs/<bundle>.yaml).
function provisionWithLabConfig(sessionId, yamlBody, extraEnv) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ssh-optin-'));
  const binDir = path.join(tmp, 'bin'); fs.mkdirSync(binDir);
  fs.writeFileSync(path.join(tmp, 'fake_docker.py'), FAKE_DOCKER_PY);
  fs.writeFileSync(path.join(binDir, 'docker'),
    '#!/usr/bin/env bash\nexec python3 "$FAKE_DOCKER_PY" "$@"\n', { mode: 0o755 });
  const orchDir = path.join(tmp, 'orchestrator'); fs.mkdirSync(orchDir, { recursive: true });
  fs.copyFileSync(path.join(ORCH, 'provision.sh'), path.join(orchDir, 'provision.sh'));
  fs.copyFileSync(path.join(ORCH, 'limits.env'), path.join(orchDir, 'limits.env'));
  fs.mkdirSync(path.join(tmp, 'images'), { recursive: true });
  fs.writeFileSync(path.join(tmp, 'images', 'digests.env'), DIGESTS);
  const cfgDir = path.join(tmp, 'lab-configs'); fs.mkdirSync(cfgDir, { recursive: true });
  if (yamlBody !== null) fs.writeFileSync(path.join(cfgDir, 'web-exploitation.yaml'), yamlBody);
  const stateFile = path.join(tmp, 'docker-state.json');
  const logFile = path.join(tmp, 'docker-calls.jsonl');
  fs.writeFileSync(stateFile, JSON.stringify({ containers: {}, nets: {}, images: {} }));
  const env = { ...process.env,
    PATH: `${binDir}:${process.env.PATH}`,
    FAKE_DOCKER_PY: path.join(tmp, 'fake_docker.py'),
    FAKE_DOCKER_STATE: stateFile, FAKE_DOCKER_LOG: logFile,
    REGISTRY: 'local', VERSION: 'dev', KEEP_RUNNING: '1', ...(extraEnv || {}) };
  const r = spawnSync('bash', [path.join(orchDir, 'provision.sh'), 'web-exploitation', sessionId], { env, encoding: 'utf8' });
  assert.equal(r.status, 0, `provision failed: ${r.stderr}`);
  const calls = fs.readFileSync(logFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  return { calls, stdout: r.stdout };
}

test('FR-18: no lab-config + no env → LAB_SSH_ENABLED=0 injected (default off)', () => {
  const { calls } = provisionWithLabConfig('s1', null, {});
  assert.equal(attackerEnv(calls, 's1', 'LAB_SSH_ENABLED'), '0');
});

test('FR-18: lab-config ssh_enabled: true → LAB_SSH_ENABLED=1 injected', () => {
  const { calls } = provisionWithLabConfig('s2', 'labs:\n  - lab_id: pivot-002\n    ssh_enabled: true\n', {});
  assert.equal(attackerEnv(calls, 's2', 'LAB_SSH_ENABLED'), '1');
});

test('FR-18: lab-config ssh_enabled: false stays off', () => {
  const { calls } = provisionWithLabConfig('s3', 'labs:\n  - lab_id: sqli-001\n    ssh_enabled: false\n', {});
  assert.equal(attackerEnv(calls, 's3', 'LAB_SSH_ENABLED'), '0');
});

test('FR-18: explicit env override wins over lab-config (operator escape hatch)', () => {
  const { calls } = provisionWithLabConfig('s4', 'labs:\n  - lab_id: pivot-002\n    ssh_enabled: true\n', { LAB_SSH_ENABLED: '0' });
  assert.equal(attackerEnv(calls, 's4', 'LAB_SSH_ENABLED'), '0');
});

test('FR-18: target container never receives the SSH flag (attacker-only opt-in)', () => {
  const { calls } = provisionWithLabConfig('s5', 'labs:\n  - lab_id: pivot-002\n    ssh_enabled: true\n', {});
  const runs = calls.filter((a) => a[0] === 'run' && a.includes('sess-s5-target'));
  assert.ok(!JSON.stringify(runs[0]).includes('LAB_SSH_ENABLED'),
    'target must not carry the attacker SSH opt-in env');
});

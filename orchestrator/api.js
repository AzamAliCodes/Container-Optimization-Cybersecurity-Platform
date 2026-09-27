// orchestrator/api.js — Phase 3 session lifecycle API (FR-08, P0).
// ---------------------------------------------------------------------------
// Express + dockerode surface consumed by the platform front-end:
//   POST /sessions          {bundle, id?}        -> create   (FR-08)
//   GET  /sessions/:id                           -> status   (FR-08)
//   DELETE /sessions/:id                           -> teardown (FR-08)
//   GET  /sessions                               -> list ids
//   GET  /sessions/:id/events                    -> reaper warning/audit events (FR-10)
//   GET  /health                                 -> liveness
//
// Provisioning delegates to orchestrator/provision.sh so the docker-run flag
// path (limits FR-06, digests FR-02, isolation NFR-03) has exactly ONE
// implementation; teardown mirrors provision.sh's cleanup contract. The idle
// reaper is a separate process (reaper.sh) — this API only exposes its state.
//
// No external npm deps are required to run or test it: a ~40-line Express
// shim sits in lib/http_shim.js so the module loads on a bare Node host and
// `node --test` integration tests run without `npm install`. In production,
// swap `require('./lib/http_shim')` for real express+dockerode when the
// platform orchestrator repo absorbs this file (PRD §10.1).
'use strict';

const { execFile } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const http = require('http');
const { Router, json } = require('./lib/http_shim');

// ORCH_HOME lets integration tests sandbox the orchestrator dir (fake
// provision.sh + fake docker on PATH) without touching this repo copy.
//   ORCH_HOME — dir holding limits.env/lifecycle.env/provision.sh (default: this dir)
//   PROVISION_BIN — provisioning entrypoint invoked by POST /sessions
const HERE = process.env.ORCH_HOME || __dirname;
const ROOT = path.dirname(HERE);
const PROVISION_BIN = process.env.PROVISION_BIN || path.join(HERE, 'provision.sh');

// ---- config (SSoT files, never hardcoded values) ---------------------------
function readEnvFile(p) {
  const out = {};
  for (const line of fs.readFileSync(p, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z_]+)=(\S+)/); // first token before inline comment
    if (m) out[m[1]] = m[2];
  }
  return out;
}
const LIMITS = readEnvFile(path.join(HERE, 'limits.env'));
const LIFECYCLE = readEnvFile(path.join(HERE, 'lifecycle.env'));
const STATE_DIR = process.env.STATE_DIR || path.join(HERE, '.state');
const WARN_LOG = process.env.WARN_LOG || path.join(STATE_DIR, 'warnings.log');
const KNOWN_BUNDLES = ['web-exploitation', 'network-recon', 'password-attacks'];

// 90s cap: never let a wedged provisioning call hang the API (healthcheck wait is 30s max)
// options overload (e.g. { env }) is supported for callers that must adjust
// the child environment; execFile merges nothing by default, so pass full env.
const sh = (cmd, args, optsOrCb, cb) =>
  typeof optsOrCb === 'function'
    ? execFile(cmd, args, { cwd: ROOT, timeout: 90000 }, optsOrCb)
    : execFile(cmd, args, { cwd: ROOT, timeout: 90000, ...optsOrCb }, cb);

// ---- routes -----------------------------------------------------------------
const app = Router();

app.get('/health', (_req, res) => res.json({ ok: true, phase: 3 }));

// GET /benchmarks — serve measured before/after data from the canonical JSON
// so demo UIs never hardcode metrics. Source of truth: docs/before-after-measurements.json
app.get('/benchmarks', (_req, res) => {
  const measPath = path.join(ROOT, 'docs', 'before-after-measurements.json');
  try {
    const raw = fs.readFileSync(measPath, 'utf8');
    const data = JSON.parse(raw);
    // Return a UI-friendly subset
    res.json({
      source: 'docs/before-after-measurements.json',
      date: data.date,
      host: data.host,
      images: data.images,
      idle_footprint_mib: data.idle_footprint_mib,
      image_reduction_pct: data.image_reduction_pct,
      concurrency: data.concurrency,
      caveats: data.caveats,
    });
  } catch (e) {
    res.status(503).json({ error: 'benchmark data not available', detail: e.message });
  }
});

// POST /sessions  {bundle, id, ssh?}  — create (FR-08)
// `ssh: true` is the FR-18 per-lab SSH opt-in: forwarded to provision.sh as
// LAB_SSH_ENABLED=1 (sshd stays OFF for every session that doesn't ask).
app.post('/sessions', (req, res) => {
  json(req, res, () => {                    // parse body, then run the handler
  const { bundle, id, ssh } = req.body || {};
  if (!bundle || !KNOWN_BUNDLES.includes(bundle)) {
    return res.status(400).json({ error: `bundle must be one of ${KNOWN_BUNDLES.join(', ')}` });
  }
  if (id === undefined || !/^[0-9A-Za-z_-]+$/.test(String(id))) {
    return res.status(400).json({ error: 'id required ([0-9A-Za-z_-]+)' });
  }
  if (ssh !== undefined && typeof ssh !== 'boolean') {
    return res.status(400).json({ error: 'ssh must be a boolean when present (FR-18 opt-in)' });
  }
  fs.mkdirSync(STATE_DIR, { recursive: true });
  if (process.env.PROVISION_STUB === '1') {   // test seam: no-Docker harnesses
    fs.writeFileSync(path.join(STATE_DIR, `session-${id}.meta`), `started=${Math.floor(Date.now() / 1000)}\nbundle=${bundle}\n`);
    return res.status(201).json({ session: String(id), bundle, status: 'ready', stubbed: true });
  }
  // FR-05 pull-only provisioning through the single canonical path.
  // KEEP_RUNNING=1: provision.sh's default EXIT trap tears the pair down on
  // exit (CI smoke mode); the API owns teardown via DELETE /sessions / reaper.
  sh(PROVISION_BIN, [bundle, String(id)],
    { env: { ...process.env, KEEP_RUNNING: '1', ...(ssh === true ? { LAB_SSH_ENABLED: '1' } : {}) } },
    (err, stdout, stderr) => {
    if (err) return res.status(500).json({ error: 'provision failed', log: (stderr || '') + (stdout || '') });
    fs.writeFileSync(path.join(STATE_DIR, `session-${id}.meta`), `started=${Math.floor(Date.now() / 1000)}\nbundle=${bundle}\n`);
    res.status(201).json({ session: String(id), bundle, status: 'ready', ssh_enabled: ssh === true });
  });
  });                                    // end json(...)
});

// GET /sessions/:id — status (FR-08): container states + reaper posture
// NOTE: the health segment is written WITHOUT spaces around the Go-template
// action (`{{if .State.Health}}{{...}}{{else}}none{{end}}`). provision.sh's
// wait_ready polls with a `{{if .State.Health}}`-style format string; the
// test-suite fake docker CLI discriminates the two callers on that token, and
// real `docker inspect` treats both spellings identically. Keep them distinct.
app.get('/sessions/:id', (req, res) => {
  const sid = req.params.id;
  sh('docker', ['inspect', '-f', '{{.Name}} {{.State.Status}}{{if .State.Health}} {{.State.Health.Status}}{{else}} none{{end}}',
    `sess-${sid}-attacker`, `sess-${sid}-target`], (err, stdout, stderr) => {
    if (err && String(stderr).includes('No such object')) {
      return res.status(404).json({ session: sid, status: 'not-found' });
    }
    if (err) return res.status(500).json({ error: String(stderr) });
    const containers = stdout.trim().split('\n').map((l) => {
      const [name, state, health] = l.split(/\s+/);
      return { name: name.replace(/^\//, ''), state, health };
    });
    const warned = fs.existsSync(path.join(STATE_DIR, `idle-${sid}.warned`));
    let samples_low = 0;
    try { samples_low = parseInt(fs.readFileSync(path.join(STATE_DIR, `idle-${sid}.low`), 'utf8'), 10) || 0; } catch {}
    res.json({
      session: sid,
      status: warned ? 'idle-warning' : containers.every((c) => c.health === 'healthy') ? 'ready' : 'starting',
      containers, samples_low,
      limits: { attacker: `${LIMITS.ATTACKER_MEMORY}/${LIMITS.ATTACKER_CPUS}cpu/${LIMITS.ATTACKER_PIDS_LIMIT}pids`,
                target: `${LIMITS.TARGET_MEMORY}/${LIMITS.TARGET_CPUS}cpu/${LIMITS.TARGET_PIDS_LIMIT}pids` },
      reaper: { poll_s: +LIFECYCLE.IDLE_POLL_INTERVAL_S, flag_after_s: +LIFECYCLE.IDLE_CONSECUTIVE_SAMPLES * +LIFECYCLE.IDLE_POLL_INTERVAL_S, grace_s: +LIFECYCLE.REAPER_GRACE_PERIOD_S },
    });
  });
});

app.get('/sessions', (_req, res) => {
  sh('docker', ['ps', '--format', '{{.Names}}'], (err, stdout) => {
    if (err) return res.status(500).json({ error: 'docker ps failed' });
    const ids = [...new Set(stdout.split('\n')
      .map((n) => (n.match(/^sess-(.+)-(attacker|target)$/) || [])[1]).filter(Boolean))];
    res.json({ sessions: ids.sort() });
  });
});

// DELETE /sessions/:id — teardown (FR-08): same contract as provision cleanup
app.delete('/sessions/:id', (req, res) => {
  const sid = req.params.id;
  sh('docker', ['rm', '-f', `sess-${sid}-attacker`, `sess-${sid}-target`], (e1) => {
    sh('docker', ['network', 'rm', `sess-${sid}-net`], (e2) => {
      for (const f of ['prev', 'low', 'warned']) {
        try { fs.unlinkSync(path.join(STATE_DIR, `idle-${sid}.${f}`)); } catch {}
      }
      try { fs.unlinkSync(path.join(STATE_DIR, `session-${sid}.meta`)); } catch {}
      res.json({ session: sid, status: 'torn-down', partial_errors: [e1, e2].filter(Boolean).length });
    });
  });
});

// GET /sessions/:id/events — audit trail of warnings/reaps for this session (FR-10)
app.get('/sessions/:id/events', (req, res) => {
  const sid = req.params.id;
  let events = [];
  try {
    events = fs.readFileSync(WARN_LOG, 'utf8').split('\n').filter(Boolean)
      .map((l) => JSON.parse(l)).filter((e) => e.session === sid);
  } catch { /* no events yet */ }
  res.json({ session: sid, events });
});

// ---- listen (skipped under `node --test`) -----------------------------------
const PORT = +(process.env.PORT || 8080);
const HOST = process.env.HOST || '0.0.0.0';

// Add CORS middleware
function addCorsHeaders(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return true;
  }
  return false;
}

if (require.main === module) {
  const server = http.createServer((req, res) => {
    // Handle CORS preflight
    if (addCorsHeaders(req, res)) {
      return;
    }
    
    // Add CORS headers to all responses
    const originalEnd = res.end;
    res.end = function(chunk, encoding) {
      addCorsHeaders(req, res);
      originalEnd.call(res, chunk, encoding);
    };
    
    app.handler()(req, res);
  });
  
  server.listen(PORT, HOST, () =>
    console.log(`lifecycle API on ${HOST}:${PORT} (phase 3, FR-08)`));
}
module.exports = { app, PORT, STATE_DIR, WARN_LOG, KNOWN_BUNDLES };

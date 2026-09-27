// orchestrator/lib/http_shim.js — minimal Express-compatible surface.
// ---------------------------------------------------------------------------
// Implements exactly what api.js uses: Router() with get/post/delete/use,
// req.body/params, res.status().json(), and a node-http handler factory.
// Purpose: FR-08 endpoints + integration tests run on a bare Node host with no
// `npm install` (air-gapped CI). Production wiring replaces this with real
// express; API of this shim is a strict subset of Express so the swap is a
// one-line require change in api.js.
'use strict';

function jsonBodyParser(req, res, next) {
  if (req.method === 'GET' || req.method === 'DELETE') { req.body = {}; return next(); }
  let raw = '';
  req.on('data', (c) => { raw += c; if (raw.length > 1e6) req.destroy(); });
  req.on('end', () => {
    try { req.body = raw ? JSON.parse(raw) : {}; } catch { req.body = null; }
    next();
  });
}

function Router() {
  const routes = [];       // {method, pattern:[seg], handler}
  const middlewares = [];

  function add(method, p) {
    return (a, b) => {
      const handler = typeof a === 'function' ? a : b;
      const pattern = typeof a === 'function' ? p : a;
      routes.push({ method, segs: pattern.replace(/^\//, '').replace(/\/$/, '').split('/'), handler });
    };
  }

  const r = {
    use: (mw) => { if (typeof mw === 'function') middlewares.push(mw); },
    get: add('GET'), post: add('POST'), delete: add('DELETE'),
    handler: () => (req, res) => {
      const url = new URL(req.url, 'http://localhost');
      const parts = url.pathname.replace(/^\//, '').replace(/\/$/, '').split('/');
      for (const route of routes) {
        if (route.method !== req.method || route.segs.length !== parts.length) continue;
        const params = {};
        let ok = true;
        for (let i = 0; i < route.segs.length; i++) {
          const s = route.segs[i];
          if (s.startsWith(':')) params[s.slice(1)] = decodeURIComponent(parts[i]);
          else if (s !== parts[i]) { ok = false; break; }
        }
        if (!ok) continue;
        req.params = params;
        res.status = (code) => { res.statusCode = code; return res; };
        res.json = (obj) => { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(obj)); };
        let idx = 0;
        const next = () => {
          if (idx < middlewares.length) return middlewares[idx++](req, res, next);
          try { route.handler(req, res, next); }
          catch (e) { res.status(500).json({ error: String(e && e.message || e) }); }
        };
        return next();
      }
      res.statusCode = 404;
      res.end(JSON.stringify({ error: 'not found', path: url.pathname }));
    },
  };
  return r;
}

module.exports = { Router, json: jsonBodyParser };

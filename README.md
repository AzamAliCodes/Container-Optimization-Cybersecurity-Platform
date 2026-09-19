# Container Optimization — Cybersecurity Learning Platform

Per-session container footprint optimization for a Kali-attacker + vulnerable-target
container pair provisioning platform.

## Requirements

| Tool | Version | Needed for |
|---|---|---|
| Docker Engine | ≥ 24.x (BuildKit default) | building images, provisioning sessions, monitoring |
| Node.js | ≥ 18 | orchestrator API, benchmark ramp stage |
| bash | 4+ | all `*.sh` scripts |
| python3 | any | serving the demo UI locally |

No `npm install` anywhere — the orchestrator runs on bare Node
(see `orchestrator/lib/http_shim.js`). You do **not** need to build images to view
the demo UI.

## Run it locally

### Option A — demo dashboard (fastest, no image build)

```bash
cd Container-Optimization-Cybersecurity-Platform
./start-demo.sh
```

This starts the orchestrator API on port 8080, serves the repo root over HTTP on
port 3000 (falls back to 3001 if busy) and opens `http://localhost:3000/demo.html`
in your browser. Press Ctrl+C to stop both processes.

The page is monochrome by design and polls the API every 5 seconds. Click
**Start Demo Session** to create a `tech-lead-demo` pair — this does need the
images built (Option B step 1) and a running Docker daemon.

Other UI variants, same server:

| File | Use |
|---|---|
| `demo.html` | main dashboard with the before/after comparison table |
| `demo-webpage.html` | wider dashboard, adds a live container list |
| `demo-simple.html` | minimal version, metrics only |

Run the pieces manually if you'd rather not use the script:

```bash
PORT=8080 node orchestrator/api.js &                  # API
python3 -m http.server 3000                           # static files
# then open http://localhost:3000/demo.html
```

CLI-only demo (no browser) — creates a session, shows containers/stats/networks,
then tears it down:

```bash
./demo.sh
```

### Option B — full platform end to end

```bash
cd Container-Optimization-Cybersecurity-Platform

# 1. Build images. Use the canonical script — it wires PLATFORM_BASE through to
#    every stage (raw `docker build` defaults to platform/base:phase1, so
#    building lab-base under another tag without --build-arg PLATFORM_BASE fails).
#    Multi-arch (amd64/arm64) is handled via TARGETARCH in images/base/Dockerfile.
./images/build.sh all
#    for local-dev tags instead: REGISTRY=local VERSION=dev ./images/build.sh all

# 2. Provision one session pair directly (attacker + target, limits enforced)
./orchestrator/provision.sh web-exploitation demo-session-1

# 3. Or drive it through the lifecycle API (port 8080 by default)
PORT=8080 node orchestrator/api.js &
curl -s -X POST localhost:8080/sessions \
     -H 'content-type: application/json' \
     -d '{"bundle":"web-exploitation","id":"demo-session-1"}'
curl -s localhost:8080/sessions/demo-session-1          # status
curl -s localhost:8080/sessions/demo-session-1/events   # lifecycle events
curl -s -X DELETE localhost:8080/sessions/demo-session-1 # teardown

# 4. Idle reaper (warns, then reaps sessions idle past the threshold; FR-10)
IDLE_THRESHOLD_S=600 ./orchestrator/reaper.sh

# 5. Disk hygiene prune (FR-14: dangling images + build cache; retention policy
#    is documented in the script header, --install-cron prints the crontab line)
DRY_RUN=1 ./orchestrator/prune.sh        # report-only first run

# 6. Per-lab SSH opt-in (FR-18): default OFF. Enable via API body {"ssh":true},
#    env LAB_SSH_ENABLED=1, or lab-config ssh_enabled:true
curl -s -X POST localhost:8080/sessions -H 'content-type: application/json' \
     -d '{"bundle":"network-recon","id":"pivot-demo","ssh":true}'

# 7. Local session env via Compose instead of provision.sh (same flags/limits)
set -a; . orchestrator/limits.env; set +a
docker compose --env-file orchestrator/limits.env -f compose/session.yml up -d

# 8. Monitoring stack (cAdvisor → Prometheus → Grafana)
docker compose -f compose/monitoring.yml up -d
#    Grafana: http://localhost:3000 (admin/admin), dashboard "Per-Session Resource Usage"

# 9. Tests — no real Docker needed (fake CLI injected by the harness)
node --test orchestrator/test/
bash ci/smoke.sh
```

### Troubleshooting

| Symptom | Fix |
|---|---|
| `docker: command not found` / cannot connect | Docker Desktop isn't running — start it, then `docker ps` |
| Demo page shows "Offline" | API isn't up. `curl localhost:8080/sessions`; restart with `PORT=8080 node orchestrator/api.js` |
| Session create fails on missing image | Build first: `./images/build.sh all`, or set `BUNDLE_IMAGE`/`TARGET_IMAGE` to your local tags |
| Session create fails with `network ... already exists` | An earlier run left an orphan network. `provision.sh` now clears stale containers/network for the session id first; to sweep all of them: `for n in $(docker network ls -q --filter name=sess-); do docker network rm $n; done` |
| Port 3000 busy | `start-demo.sh` falls back to 3001; watch the printed URL |
| Port 8080 busy | `PORT=8081 node orchestrator/api.js` and point the page at that port |

`DELETE /sessions/:id` removes both containers **and** the session network, so a
normal create/teardown cycle leaves nothing behind. Networks only accumulate if
containers are removed by other means (`docker rm`, `docker system prune`, a killed
run) — the sweep above clears those.

Practical notes: image digests come from `images/digests.env` (FR-02); for
tag-based local builds set `REGISTRY=local VERSION=dev` plus matching
`BUNDLE_IMAGE`/`TARGET_IMAGE` overrides, or clear the digest pin. Resource limits
live in `orchestrator/limits.env` (single source of truth). A real Docker daemon
is required for build, provisioning, Compose and monitoring; the tests and the
benchmark unit stages are not.

## Repo layout

```
images/                # Multi-stage base + lab bundles + vulnerable target
orchestrator/          # Lifecycle API, provision/reaper/prune scripts, limits.env
compose/               # session.yml (one pair) + monitoring.yml (cAdvisor→Prom→Grafana)
benchmark/             # Phase 0/5 harness — bash driver + Node ramp; model.py capacity model
legacy-images/         # "current-state" reproduction images for the Phase 0 baseline
lab-configs/           # Lab → bundle/target config stubs (validates FR-18 assumption)
monitoring/            # Prometheus + Grafana provisioning
ci/, .github/          # Smoke test + image publish workflow
docs/                  # Baseline/final reports, decisions, methodology, scaling strategy
demo*.html, *.sh       # Local demo UI and runner scripts (not part of the platform)
```

`agentlog.md` and `PRD-*.md` are local working documents and are git-ignored.

## Phases

| Phase | What | Where |
|---|---|---|
| 0 Baseline | Reproduce legacy bloat, measure before-state | `benchmark/`, `legacy-images/`, `docs/baseline-report.md` |
| 1 Image optimization | Multi-stage bundles, shared base, Compose | `images/`, `compose/`, `ci/`, `docs/phase1/` |
| 2 Resource limits | cgroup enforcement (limits.env SSoT) | `orchestrator/limits.env`, `provision.sh` |
| 3 Lifecycle | Idle reaper + lifecycle API | `orchestrator/api.js`, `reaper.sh`, `lib/detect_idle.sh` |
| 4 Monitoring | cAdvisor/Prometheus/Grafana | `compose/monitoring.yml`, `monitoring/` |
| 5 Benchmark & report | After/Before comparison, scaling doc | `benchmark/model.py`, `docs/final-benchmark-report.md`, `docs/scaling-strategy.md` |

## Benchmarks

```bash
./benchmark/run.sh legacy          # Phase 0 baseline (current-state images)
./benchmark/run.sh opt             # same harness against optimized images
```

Individual stages (all write JSON into a `benchmark/reports/run-<ts>-<pair>/` dir,
which is git-ignored):

```bash
./benchmark/01-images.sh  <run-dir>   # image sizes
./benchmark/02-coldstart.sh <run-dir> # provision→ready, BENCH_RUNS repetitions
./benchmark/03-idle.sh  <run-dir> 1   # idle RAM/CPU/procs for pair 1
./benchmark/04-ramp.js                 # concurrent-pair ramp to exhaustion (BENCH_OUT_DIR=...)
./benchmark/05-report.sh  <run-dir>   # summary.json + report.md
```

Results land in `docs/baseline-report.md` (curated) and `benchmark/reports/` (raw).
See `benchmark/README.md` for knobs (`RAMP_DWELL_S`, `EXHAUST_MEM_FRAC`, `IDLE_SAMPLE_S`, …)
and `docs/decisions.md` for methodology + host caveats.

## Key documents

- `docs/final-benchmark-report.md` — before/after matrix, KPI scorecard, sign-off gates G1–G4, §6 DoD sign-off record + §12 open-question resolutions
- `docs/scaling-strategy.md` — FR-15: density limits, capacity formula, sharding path, triggers, cost model
- `docs/bundle-authoring-guide.md` — lab-author guide for new bundles (image skeleton, CI registration, Compose validation workflow, FR-18 SSH opt-in policy)
- `docs/audit-real-measurements.md` + `.json` — **measured** idle/cold-start/concurrency figures from this host, with reproduction commands. The legacy baseline is not re-measurable here (no legacy images); the optimized side is fully measured.
- `benchmark/model.py` — auditable offline capacity model; every quoted number traces here or to raw JSON under `benchmark-output/`. Regenerate both with `python3 benchmark/model.py`

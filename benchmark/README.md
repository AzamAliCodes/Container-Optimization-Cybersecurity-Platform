# Phase 0 / Phase 5 Benchmark Harness

Dependency-free harness implementing the PRD's **Appendix A methodology** across the
**Appendix B** test matrix. One driver serves both the Phase 0 baseline and the Phase 5
optimised run — only the image set changes.

## Quick start

```bash
./run.sh legacy    # Phase 0 baseline (platform/{attacker,target}:legacy)
./run.sh opt       # Phase 5 optimised run (platform/{attacker,target}:opt)
```

Output: `benchmark/reports/run-<UTC-ts>-<pair>/` containing
`images.json`, `coldstart.json`, `idle.json`, `ramp.json`, `summary.json`, `report.md`
(plus `ramp.stdout`). The driver always tears down its `bm-*` containers/networks on exit
(via `trap`).

## Stages

| Script | Measures | Key output |
|---|---|---|
| `01-images.sh <dir>` | image sizes via `docker image inspect .Size` | `images.json` |
| `02-coldstart.sh <dir>` | provision → both-ready, `BENCH_RUNS` reps → median | `coldstart.json` |
| `03-idle.sh <dir> <pair#>` | settle, then median idle RAM/CPU/procs over window | `idle.json` |
| `04-ramp.js` (env `BENCH_OUT_DIR=<dir>`) | concurrent pairs before exhaustion | `ramp.json` |
| `05-report.sh <dir>` | aggregates all of the above | `summary.json`, `report.md` |
| `lib.sh` | shared helpers: naming, readiness probe, `host_stats`, teardown | — |

## Knobs (env vars, defaults in `lib.sh`)

| Var | Default | Meaning |
|---|---|---|
| `LAB_PAIR` | `legacy` | image-set label; also drives `IMG_ATTACKER`/`IMG_TARGET` |
| `BENCH_RUNS` | `3` | cold-start repetitions (median reported) |
| `IDLE_SETTLE_S` | `30` | wait after cold-start before sampling |
| `IDLE_SAMPLE_S` / `IDLE_INTERVAL_S` | `60` / `5` | idle sampling window / cadence |
| `RAMP_DWELL_S` | `8` | dwell per added pair (readiness + metric convergence) |
| `RAMP_MAX_PAIRS` | `24` | hard cap for the ramp |
| `EXHAUST_CPU_PCT` / `EXHAUST_CPU_SUSTAIN_S` | `90` / `60` | CPU trigger |
| `EXHAUST_MEM_FRAC` | `0.92` | memory trigger (fraction of host total) |
| `RAMP_POLL_S` | `2` | ramp metric poll interval |
| `COLD_START_SLA_S` | `60` | legacy cold-start guard (10s SLA is a Phase 5 target) |

## Design notes / gotchas

- **No `HEALTHCHECK` in Phase 0 images** — readiness is probed directly by the harness
  (attacker `docker exec` + target HTTP 200 on the per-session network). FR-07 healthchecks
  arrive in Phase 1 and replace this probe.
- **`docker stats` has no `--filter` flag** — `stats()`/`host_stats()` enumerate all
  containers and select `bm-*` client-side. Do not reintroduce `--filter` there.
  (`docker ps` *does* OR multiple `name=` filters, so multi-filter teardown loops are fine.)
- **Attacker stays resident only if stdin stays open** — a plain `bash`/`msfconsole` PID 1
  exits on EOF when run headless, so the legacy entrypoint pins stdin with
  `tail -f /dev/null`. Without that, pairs die mid-ramp and results are meaningless.
- **Exhaustion counts**: only pairs surviving a full dwell are credited to `max_pairs`;
  the pair that trips a threshold is excluded (`peak = n - 1`).
- Cleanup is scoped to the `bm-*`/`bm-net-*` prefixes so unrelated containers on the host
  are never touched.

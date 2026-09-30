# Audit — real measurements on this host

Every figure below was produced by running the platform on this machine
(macOS, Docker Desktop) on **2026-10-01**. Commands are reproducible; no number
here is copied from another document. Raw JSON is at
`docs/audit-real-measurements.json`.

Host: 8 vCPU, 8.0 GiB RAM, Docker server 29.8.0.

## Measured: optimized pair

`platform/web-exploitation:phase1` (attacker) + `platform/target:phase1` (target),
run with the `orchestrator/limits.env` quotas (attacker 512m/1.0cpu/100 pids,
target 256m/0.5cpu/50 pids).

| Metric | Measured | Previous claim in demo UI |
|---|---|---|
| Attacker idle RAM | **17.4–17.9 MiB** (median ~17.6) | 17.49 MiB — close, but was unsourced |
| Target idle RAM | **26.5–26.9 MiB** (median ~27.6) | 27.36 MiB — close, but was unsourced |
| Pair total idle RAM | **~44–45 MiB** | 44.85 MiB |
| Attacker idle CPU | 0.00–1.90% | 1.93% |
| Target idle CPU | 0.01–6.76% | 1.81% |
| Attacker procs | **2** | 2 — correct |
| Target procs | **3** | 3 — correct |

The memory and process-count figures in the demo UI happen to match reality.
They had no source; they are now sourced.

## Measured: cold start

Readiness was measured as **target Docker healthcheck `healthy`**, i.e. the
app port is actually accepting connections — not merely `State.Running`.

| Run | Wall-clock to healthy |
|---|---|
| 1 | 3771 ms |
| 2 | 4248 ms |
| 3 | 3673 ms |
| **median** | **~3.8 s** |

**The demo UI's `~400ms` is wrong by ~9×.** The old `02-coldstart.sh` probe only
checked `State.Running`, so it measured `docker run -d` returning, not the lab
being usable. `docs/decisions.md` specifies an HTTP-200 readiness check that
was never implemented.

## Measured: concurrency (the headline KPI)

Pairs were started incrementally, quotas enforced, then held and checked for
health.

| Pairs | Containers | Result |
|---|---|---|
| 12 | 24 | all healthy, stable |
| 30 | 60 | all healthy, stable |
| **63** | **125** | stable; 1 target still in `Created` when sampled |

At 30 pairs the pair memory totalled ~1308 MiB across 60 containers
(17.6 MiB attacker, 27.6 MiB target average). At 63 pairs the host was
compressed but not swapping; 62 targets + 63 attackers ran concurrently.

**The demo UI's "10-20 pairs on 8GB" and the report's "182 pairs" are both
wrong.** The real measured figure on this 8 GB host is **≥60 pairs**, an order
of magnitude above the demo's claim and ~3× above the report's own model
prediction of 39.

## Why the previous numbers were wrong

1. **Cold start** — readiness probe never checked the app port.
2. **Concurrency** — `model.py` budgets *worst-case committed quota*
   (768 MiB/pair), not measured working set (~44 MiB/pair). Every capacity
   figure therefore understates by ~17×.
3. **Per-host pair counts** — the "10-20 / 42-60" numbers drop the
   `EXHAUST_MEM_FRAC` safety term the model itself applies
   (`⌊32768/768⌋=42` vs the model's own `39`).

## What is NOT measured here

**SUPERSEDED — the legacy baseline has since been built and measured.**
See `docs/before-after-measurements.md`: the legacy images were rebuilt from
`legacy-images/` and run against the optimized stack under an identical protocol
(attacker 3650 MiB, target 955 MiB, 446.5 MiB idle/pair, 37-pair ceiling).

The original Phase 0 records this document fell back on
(`benchmark/benchmark-output/run1/images.json`, 3464.8 / 910.5 MiB) have since been
**retracted and removed from version control** — a single un-replicated hand-written
record, not a harness transcript. The re-measured sizes differ (3650 / 955 MiB).

## Reproducing

```bash
set -a; . orchestrator/limits.env; set +a
# one pair, real healthcheck-gated cold start
docker run -d --name cs-att --memory=$ATTACKER_MEMORY --cpus=$ATTACKER_CPUS platform/web-exploitation:phase1
docker run -d --name cs-tgt --memory=$TARGET_MEMORY --cpus=$TARGET_CPUS platform/target:phase1
watch -n2 'docker stats --no-stream cs-att cs-tgt'
docker top cs-att | tail -n +2 | wc -l   # expect 2
docker top cs-tgt | tail -n +2 | wc -l   # expect 3
# ramp: start pairs in a loop, then docker ps --filter name=ramp- --format '{{.Status}}'
docker rm -f $(docker ps -aq --filter name=ramp-)
```

## Finding: run directory labels are swapped

`benchmark/reports/run-20260929T153820Z-opt/` contains
`platform/attacker:legacy` with sizes `"n/a"`, while
`run-20260929T153949Z-legacy/` contains `platform/web-exploitation:phase1`
with the *optimized* sizes 326.2 / 261.8. The directories are mislabelled, and
neither contains a `summary.json` or `report.md` — `run.sh` always writes both,
so **neither benchmark run completed.** The "opt" run is also timestamped 89 s
*before* the "legacy" run, which is impossible for a before/after comparison.

This is why the "optimized baseline" of 326.2 MiB measures a pre-existing
Phase-1 bundle rather than anything this project optimized.
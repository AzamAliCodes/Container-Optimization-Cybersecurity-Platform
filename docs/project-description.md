# Container Resource Optimization at Scale

**Title:** Optimization of Containerized Lab Infrastructure for Concurrent Learner Sessions

## Problem statement

Each learner session on the lab platform spins up its own dedicated target and
attacker Docker containers. These containers are heavier than necessary — the
attacker image in particular bundles a large offensive-security toolset, resulting
in high RAM and CPU consumption per session.

With many learners active simultaneously, the host cannot support enough
concurrent sessions without significant additional hardware headroom, making the
platform costly to run and difficult to scale to a full cohort or enterprise
customer base.

The engineering team is required to design and implement a lightweight,
resource-optimized containerization strategy that reduces the per-session
footprint of both the target and attacker containers while preserving full lab
functionality, and to demonstrate measurable improvement in the number of
concurrent sessions a given host can support.

## Technical root cause

1. **Monolithic attacker image.** Built on a full Kali Linux base
   (`kalilinux/kali-rolling`) with a top-10 tools metapackage layered on top,
   pulling in several hundred MB to multiple GB of binaries, wordlists and
   framework dependencies (Metasploit, sqlmap, hydra) that remain resident in
   every container instance regardless of which exploit path a given lab
   actually exercises.

2. **No multi-stage builds.** Build-time artifacts (apt caches, compilers,
   temporary archives used to compile ttyd from source) are not discarded from
   the final image layer, inflating both image size on disk and the container's
   in-memory footprint once started.

3. **No resource quotas.** No CPU or memory limits are applied at container start
   (no `--cpus` / `--memory` equivalent in the orchestrator's `docker run` or
   Compose configuration), so each session's containers can consume host
   resources without a ceiling. Long-running or idle sessions continue to hold
   memory allocated to background services (sshd, msfconsole, ttyd) rather than
   having it reclaimed.

4. **No shared base-layer strategy.** Each session provisions containers
   independently without a shared, cached base layer, so Docker cannot reuse
   common image layers efficiently across concurrent sessions — causing
   redundant layer reads/writes and slower container start times that compound
   as concurrency increases.

## Minimum features

| # | Feature | Implementation | Status |
|---|---|---|---|
| 1 | Lightweight multi-stage Docker builds | `images/base/Dockerfile` (multi-stage `AS dl` / `AS tools`), `images/build.sh` | Done |
| 2 | Base image selection/trimming | debian-slim base + curated tool layer; `metasploit-framework` absent, msf lazy-started per-lab | Done |
| 3 | Per-container resource limits | `orchestrator/limits.env` as single source of truth (attacker 512m/1.0cpu/100 pids, target 256m/0.5cpu/50 pids), enforced in `provision.sh` + Compose, parity-gated in `ci/smoke.sh` | Done |
| 4 | Shared/cached image layers | one shared `platform/base:phase1` every bundle builds `FROM`, so layers are reused across all sessions | Done |
| 5 | Container lifecycle management | `orchestrator/api.js` (create/status/events/delete), `reaper.sh` (idle reaping), `prune.sh` (disk hygiene) | Done |
| 6 | Per-session resource monitoring | `compose/monitoring.yml` (cAdvisor → Prometheus → Grafana), dashboard "Per-Session Resource Usage" | Done |
| 7 | Before/after benchmarking | `benchmark/run.sh`, stages 01–05, `model.py` capacity model | Harness done; live before/after pending |
| 8 | Documented horizontal-scaling strategy | `docs/scaling-strategy.md` (density limits, capacity formula, sharding path, triggers, cost model) | Done |

## Required tools

| Tool | Where it is used |
|---|---|
| Docker / Docker Desktop with multi-stage builds | `images/build.sh`, all Dockerfiles |
| Lightweight base images (debian-slim) | `images/base/Dockerfile` |
| Docker Compose | `compose/session.yml` (one pair), `compose/monitoring.yml` (telemetry) |
| cgroups resource controls | `orchestrator/limits.env` → `--memory` / `--cpus` / `--pids-limit` |
| Docker BuildKit | shared base-layer caching + cache mounts in `images/build.sh` |
| cAdvisor / Prometheus / Grafana | `monitoring/`, wired in `compose/monitoring.yml` |
| Load-testing / benchmarking (bash + Node) | `benchmark/01`–`05`, `04-ramp.js` |
| Node.js orchestrator | `orchestrator/api.js`, `scheduler.js`, `host-agent.js` |

## Engineering team outcome

> Demonstrate a target/attacker container pair with a measurably reduced RAM and
> CPU footprint compared to the current baseline, and show — through
> benchmarking — that the optimized setup supports a materially higher number of
> concurrent sessions on the same host hardware.

### Measured on this host (8 vCPU / 8 GiB, Docker 29.8.0)

| Metric | Legacy baseline | Optimized | Improvement |
|---|---|---|---|
| Attacker image size | 3650 MiB | **342 MiB** | **90.6% ↓** |
| Target image size | 955 MiB | **275 MiB** | **71.2% ↓** |
| Idle RAM per pair | 446.5 MiB (401.5 att + 45.0 tgt) | **45.4 MiB** (17.9 att + 27.6 tgt) | **89.8% ↓ (9.8×)** |
| Idle processes per pair | 15 | **5** | 15 → 5 |
| Cold start to healthy | not re-measurable | **4.4 s** (4365/4982/4036 ms) | — |
| Max pairs, 8 GB host | **37** | **62** | **1.7×** |

Both image sets were built and run on this host under an identical protocol.
Method, raw JSON and reproduction commands: `docs/before-after-measurements.md`.

### Honest status

Both sides are now measured on the same host: the legacy baseline was rebuilt
from `legacy-images/` (full Kali single-stage with resident msfconsole + sshd, no
quotas) and compared against the optimized stack under an identical protocol.

Two prior claims were fabricated and have been removed (PR #2): a "~400 ms" cold
start that was labelled *"estimated from demo"* and then reported as a median, and
idle-RAM / pair-count figures that no artifact supported. The root cause was a
readiness probe that checked `.State.Running` instead of the app port, so it
measured `docker run` rather than the lab. That probe is fixed and its output
(4.4 s) is what appears above.

**The ≥3× concurrency target is not met on this host: measured 1.7× (37 → 62 pairs).**

This is the most important finding, and it is not a measurement error. The legacy
pair runs with **no limits at all**, so macOS treated its memory as reclaimable and
compressed ~3.4 GB rather than failing — the baseline was never actually capped and
borrowed unbounded host slack. The optimized pair runs under hard cgroup quotas.
9.8× less memory per pair therefore did not translate linearly into sessions.

The measured 1.7× is close to the capacity model's 2.1× projection, which suggests
the model is roughly right and the ≥3× ambition was optimistic. On a host with a hard
ceiling (bare metal, a fixed VM balloon, or `--memory` applied to the legacy pair for a
like-for-like comparison) the per-pair advantage should translate further; macOS memory
compression is not reproducible on Linux, and that would need re-measuring.
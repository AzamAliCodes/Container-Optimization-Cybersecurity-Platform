# FR-15 — Horizontal Scaling Strategy

**Audience:** Infra/Hosting Owner + Finance/Ops (PRD §15 DoD requires both reviews).
**Scope:** documented strategy only — multi-host implementation is an explicit PRD non-goal.
All capacity numbers here are emitted by `benchmark/model.py` (regenerate:
`python3 benchmark/model.py`; machine-readable copy:
`benchmark-output/phase5-model/capacity-model.json`) or trace to Phase 0 raw JSON.
Constants marked **(A)** are [ASSUMPTION]s that Phase 5 gate G1 (live same-host re-run,
see `docs/final-benchmark-report.md` §6) must replace before these figures are contractual.

## 1. Single-host density limits (where one box stops being enough)

The reference host (8 vCPU / 32 GiB, PRD §11 (A)) supports **39 concurrent session-pairs**
post-optimisation; the model's per-resource bounds (pairs):

| Bound | Legacy | Optimized | Notes |
|---|---|---|---|
| RAM (committed = cgroup limit sum, 768 MiB/pair) | 25 | **39 ← binding** | worst-case accounting; working-set basis would be ~126 (report §3) |
| CPU (90 % sustained incl. burst policy) | 18 | 185 | legacy unbounded bursts dominate this bound |
| PIDs (host budget 6000 (A) ÷ 150/pair) | 40 | 40 | pids-limit 100+50 makes this predictable for the first time |
| Disk (usable − reserve − images-once ÷ marginal 50 MiB (A)) | 603 | 4890 | FR-16 shared layers turn disk from a real constraint into a non-issue |

Headroom rule of thumb: **RAM-committed is the planning bound (~37 pairs), PID is the hard
ceiling (~40), and either can be reached while the host still "looks idle"** — which is why
monitoring (§5 triggers) watches committed headroom, not just utilisation.

Legacy comparison: 18 pairs → 37 pairs = **2.1× (A)** on conservative committed-RAM
accounting; ≥3× is reachable on the working-set basis the §5 KPI specifies but is only
claimable after gate G1 (see final report §3 gap statement).

## 2. Capacity formula (for Ops to plug real hosts into)

```
MaxPairs(host) = floor( min(
    (0.95·MemTotal − MemOverhead) / PairRAM,          # committed = ATTACKER_MEMORY+TARGET_MEMORY
    cpu_bound with burst policy (model.py solve()),   # 0.90·vCPU budget
    PIDBudget / (ATTACKER_PIDS_LIMIT+TARGET_PIDS_LIMIT),
    (DiskUsable − DiskReserve − ImagesOnce) / MarginalDiskPerPair
) )
```
Inputs live in exactly two files: `orchestrator/limits.env` (per-pair) and
`benchmark/model.py` constants (per-host + overheads). Changing a limit changes every
downstream projection atomically.

Sessions-per-cohort planning: `HostsNeeded = ceil(PeakConcurrentPairs / MaxPairs)` at the
**peak concurrency percentile**, not average — sessions are long-lived learner labs, so
cohort start times bunch (schedule cohorts ≥ 30 min apart to flatten the ramp; cold-start
contention slope in the model is 150 ms/pair (A)).

## 3. Path to multi-host sharding (design, not implementation)

**Session-affinity model.** A session-pair is the unit of placement and never splits:
attacker+target share one host (per-session Docker bridge network, no cross-host east-west
traffic; keeps FR-08 isolation boundary local). Learner traffic (ttyd WebSocket + target HTTP)
is already connection-oriented through the reverse proxy, so affinity = "pin pair → host".

- **Placement service**: extend the orchestrator API (Phase 3 pattern) with a scheduler that
  keeps a per-host score = max(committed-RAM %, PID %, disk %) and places each new pair on the
  lowest-score host that stays under the 80 % admission line (§5 trigger math). Score inputs
  already exist: Prometheus metrics per host (Phase 4 stack) + `docker inspect` limits.
- **State**: the only shared state today is (a) session registry (id → host, bundle digest,
  created-at, last-activity) and (b) reaper decisions. Registry moves to a small replicated
  store (Postgres or Redis-with-AOF); reaper becomes per-host agent + central policy push —
  the existing `reaper.sh` logic ports unchanged because it consumes the same idle-detection
  signal (`lib/detect_idle.sh`). No learner persistent state exists by design (labs are
  disposable), which is what keeps multi-host cheap.
- **Image distribution**: CI pushes digest-pinned images to one registry (FR-04/05 already
  assume this). New hosts run a warm-up pull of `platform/base` + active bundles before
  admission (the shared-layer family means one pull serves all bundles); optional registry
  mirror/`p2p-trust` later. Cold-start SLA holds only for pre-pulled images — admission
  control must check image presence, not just resources.
- **Monitoring topology**: per-host cAdvisor/Prometheus (already digest-pinned in
  `compose/monitoring.yml`) + federated/global Grafana view; alert rules scale by label
  (`instance`) without edits.

## 4. Trigger thresholds for adding a host

Explicit escalation ladder (all measured by the Phase 4 stack; sustained-window definitions
match Appendix A):

| Trigger | Threshold | Action |
|---|---|---|
| T1 — soft | Any host > 70 % committed-RAM headroom consumed **or** > 28 pairs for 15 min (70 % of 39) | Ops plans next host (lead time buffer) |
| T2 — admission throttle | Any host ≥ 80 % of MaxPairs (= 31 pairs ref-host) **or** PID usage ≥ 80 % | Scheduler stops placing new pairs there |
| T3 — hard add | Fleet-wide ≥ 2 hosts at T2 simultaneously **or** any provision rejected for capacity in a rolling hour **or** cold-start p95 > 8 s (SLA margin burn-down) | Add host now |
| T4 — emergency | Available mem < 5 % or CPU > 90 % sustained 60 s on any host (Appendix A exhaustion) | Reaper aggressive mode + drain; investigate overcommit |

T2's 80 % line is the same fraction the model uses for its burst-credit cutoff — i.e. beyond
it, idle-state projections stop being valid and tail latency degrades nonlinearly.

## 5. Per-session cost model (Finance/Ops)

Let `H` = fully-loaded $/host-month (compute + storage + egress + ops amortisation),
`P` = MaxPairs (§2). Then:

```
$/concurrent-pair-month = H / P                     (density metric, §5 KPI driver)
$/session-hour          = H / (P · 730 h · util)    (util = busy-hours fraction per pair)
```

Worked example with placeholder `H = $320/mo` (finance to supply actuals):

| Scenario | P | $/concurrent-pair-month | vs legacy |
|---|---|---|---|
| Legacy single host (no limits, 18 pairs before burst-exhaustion) | 18 | **$17.8** | — |
| Optimized single host | 39 | **$8.2** | **−54 %** |
| Optimized, 3-host fleet @ T2 admission (31 effective pairs/host) | 93 | **$10.3** | −42 % vs legacy; fleet buys HA + drain headroom at a small density tax (per-host reserve) |

Key finance point: optimisation converts an *unbounded* per-session footprint into a
*guaranteed* one (cgroup limits), so cost-per-learner becomes a deterministic linear formula
in peak concurrency — capacity planning replaces incident response. The old model required
~1 extra host per 18 pairs **plus** degraded-performance risk; the new one needs 1 per 39
pairs with bounded blast radius per session.

## 6. Non-goals & review checklist

Out of scope (PRD §4): Kubernetes migration, autoscaling groups, GPU labs, multi-tenant
network segmentation beyond per-session isolation. This doc deliberately stops at "how we'd
get there and when we'd pull the trigger."

- [ ] Infra/Hosting Owner: confirm §3 placement/state design fits the existing orchestrator roadmap; confirm reference-host spec (§11 assumption).
- [ ] Finance/Ops: replace `H=$320` placeholder with actuals; validate cohort peak-concurrency assumptions.
- [ ] Both: re-review after Phase 5 gate G1 replaces (A) constants with live measurements.

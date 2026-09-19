# Phase 0 Baseline — Methodology, Decisions, and Caveats

## What was measured, and how

All measurements follow PRD **Appendix A** and cover the **Appendix B** test matrix. The
harness is `benchmark/` and is deliberately parameterised so the *same* driver runs the
Phase 0 baseline (`LAB_PAIR=legacy`) and the Phase 5 optimised run (`LAB_PAIR=opt`).

| Stage | Script | Measures |
|---|---|---|
| 1 | `01-images.sh` | attacker/target image size (`docker image inspect .Size`) |
| 2 | `02-coldstart.sh` | provision → both-ready, `BENCH_RUNS` times, median reported |
| 3 | `03-idle.sh` | idle RAM / CPU / process count after settle window |
| 4 | `04-ramp.js` | max concurrent pairs before exhaustion threshold |
| 5 | `05-report.sh` | aggregates stages 1–4 into `summary.json` + `report.md` |

### Methodology decisions
- **Median of 3 runs** (Appendix A) for cold-start; idle metrics are the median of samples
  across the sampling window.
- **Readiness probe** = attacker `docker exec` succeeds AND target HTTP 200 on the
  per-session network. The legacy images define no `HEALTHCHECK` (that is FR-07, introduced
  in Phase 1), so the harness probes readiness directly. Phase 1 replaces this with a real
  `HEALTHCHECK` the orchestrator polls.
- **Exhaustion threshold** (Appendix A): aggregate container CPU ≥ 90% sustained 60s, OR
  container memory sum ≥ 92% of host total, OR a pair failing to become ready within the
  cold-start guard.
- **"Max concurrent before exhaustion"** counts only pairs that survived a full dwell
  *without* tripping a threshold. The pair that trips the threshold is not counted.

## Baseline stack definition (what "before" means)

There was no pre-existing orchestrator or image in this repository, so Phase 0 reproduces
the **current-state pattern described in the PRD** as runnable images:

`legacy-images/attacker/` — reproduces the pre-optimisation attacker:
- `FROM kalilinux/kali-rolling` (unpinned, "latest" semantics) — FR-02
- Single stage, apt cache + index lists baked in — FR-01
- Heavy toolset via apt (metasploit-framework, nmap, sqlmap, hydra, wordlists), standing in
  for the `kali-tools-top10` metapackage — FR-03
- `sshd` installed **and auto-started** at boot — FR-18 violation
- `msfconsole` **auto-started and held resident** at boot — FR-18 violation
- Runs as `root`, no `USER` — NFR-03 violation
- No `HEALTHCHECK` — FR-07 absence
- No resource limits at runtime — FR-06 absence

`legacy-images/target/` — reproduces the bloated target: full `debian:bookworm` (not slim),
single stage with `build-essential` retained and apt caches baked, apache2+mod_php serving a
small vulnerable app, root, no healthcheck, no limits.

> **msfconsole residency note.** `msfconsole` exits immediately when its stdin reaches EOF.
> A naive background launch therefore does **not** reproduce the legacy behaviour. The
> entrypoint keeps stdin open with `tail -f /dev/null | msfconsole -q`, which is what makes
> the framework hold its ~300 MiB resident — i.e. it faithfully reproduces the FR-18 waste
> the PRD describes. Without this the baseline is understated.

## Caveats — read before using these numbers

1. **This host is not the reference host.** The PRD §11 reference host is an
   **[ASSUMPTION]**: 8 vCPU / 32 GB RAM / NVMe / Ubuntu 24.04. These measurements were taken
   on a **macOS machine with Docker Desktop allocating only ~4 GB RAM / 8 vCPU** to the
   LinuxKit VM. Consequences:
   - **Max-concurrency here is a dev-host floor, not a capacity number.** It is bounded by
     the 4 GB VM allocation, not by real host memory. It must be re-measured on the 32 GB
     reference host before any capacity/cost claim is made.
   - Idle RAM/CPU and image size are *host-independent* and therefore trustworthy.
2. **Representative toolset, not the literal top-10 metapackage.** Per the agreed Phase 0
   decision, the attacker installs a ~5-tool heavy set rather than the full
   `kali-tools-top10`, so the build fits the constrained dev host. The *pattern* (single
   stage, baked caches, resident frameworks) is faithfully reproduced; the exact
   production image size is to be confirmed against the real registry.
3. **Image size is compressed-report dependent.** `docker image inspect .Size` is the
   uncompressed size. Confirm against the registry manifest when comparing to a published
   artifact.

## FR-18 assumption check

The PRD's Phase 0 exit criteria require validating "no lab needs msfconsole preloaded at
session start" against the lab inventory. No lab inventory exists in this repository yet
(`lab-configs/` is a stub), so **this validation is deferred**: it cannot be signed off until
the Lab Content Team supplies the real lab inventory. The baseline deliberately
auto-starts msfconsole to *demonstrate* the waste that lazy-starting (FR-18) would remove.

## Phase 0 exit criteria status

| Criterion | Status |
|---|---|
| Benchmark harness v1 runs unattended | Done — `benchmark/run.sh` |
| Image sizes documented | Done — see `docs/baseline-report.md` |
| Idle RAM / CPU / process count documented | Done |
| Cold-start documented | Done |
| Max concurrent sessions documented | Done, **dev-host floor only** (caveat 1) |
| Numbers signed off by Platform Engineering | Pending human sign-off |
| FR-18 assumption validated vs lab inventory | **Blocked** — no lab inventory exists yet |

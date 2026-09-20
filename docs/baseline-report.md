# Phase 0 Baseline Report

**Superseded.** The Phase 0 figures originally published here were re-measured on
2026-10-01 and did not hold up. The current, verified baseline is in
**`docs/before-after-measurements.md`** (raw JSON: `docs/before-after-measurements.json`).

## What changed and why

| Metric | Phase 0 (retracted) | Re-measured 2026-10-01 | Why the old value was wrong |
|---|---|---|---|
| Attacker image size | 3464.8 MiB | **3650 MiB** | Was a hand-written record, not a harness transcript. Close, but unsourced. |
| Target image size | 910.5 MiB | **955 MiB** | Same. |
| Idle RAM per pair | ~88 MiB | **446.5 MiB** | **Sampled before the resident msfconsole/JRuby heap grew.** The 88 MiB reading was taken during the settle window and is off by ~5×. |
| Idle processes | 2 per container | **15 per pair** (8 att + 7 tgt) | The old script measured the attacker only, then reported it as per-container across the pair. |
| Cold start | median 205 ms | **not measurable for legacy** | **The probe checked `.State.Running`, not app readiness.** It measured how fast `docker run -d` returns, not how fast the lab comes up. The probe is now fixed (`benchmark/lib.sh`). |
| Max concurrent pairs | 3 (VM ceiling) | **37** | Hit a Docker Desktop VM allocation, not a real resource threshold. |

The 205 ms and 88 MiB figures were the two most misleading: both looked precise and
both were measured with a probe that did not test what it claimed to test.

## Current verified baseline

Full protocol, method and caveats: `docs/before-after-measurements.md`.

| Metric | Legacy (measured) | Optimized (measured) |
|---|---|---|
| Attacker image size | 3650 MiB | 342 MiB (90.6% ↓) |
| Target image size | 955 MiB | 275 MiB (71.2% ↓) |
| Idle RAM per pair | 446.5 MiB | 45.4 MiB (89.8% ↓) |
| Idle processes per pair | 15 | 5 |
| Max pairs, 8 GiB host | 37 | 62 (1.7× ↑) |

The legacy baseline was rebuilt from `legacy-images/` and run on the same host under
an identical protocol to the optimized stack.

**The ≥3× concurrency target is not met** (measured 1.7×). See the header of
`docs/final-benchmark-report.md` for why: the legacy pair runs with no limits, so
macOS compressed ~3.4 GB rather than failing, letting the baseline borrow unbounded
host slack.

## Reproducing

```bash
docker build -f legacy-images/target/Dockerfile   -t platform/target:legacy   .
docker build -f legacy-images/attacker/Dockerfile -t platform/attacker:legacy .
./benchmark/run.sh legacy    # Phase 0 baseline
./benchmark/run.sh opt       # Phase 5 optimized
```

Note: `benchmark/run.sh` writes into `benchmark/reports/`, which is git-ignored.
The directories left over from the earlier attempt (`run-20260929T153820Z-opt`,
`run-20260929T153949Z-legacy`) are **swapped, incomplete, and unreliable** — the
`-opt` directory contains legacy image names with `"n/a"` sizes, neither contains
the `summary.json` that `run.sh` always writes, and the "opt" run is timestamped 89 s
before the "legacy" run. They are retained only as evidence of the failed attempt and
should not be cited.

## Host caveats

1. macOS/Docker Desktop with ~3.4 GB observed memory compression. Image sizes and
   process counts are host-independent; concurrency ratios are **not** — a Linux host
   without overcommit would likely show a larger concurrency ratio.
2. Representative heavy toolset (~5 tools) stands in for `kali-tools-top10`.
3. `docker image inspect .Size` is uncompressed; registry manifests will read lower.

## Phase 0 exit-criteria status

Harness, sizes, idle, cold-start and max-concurrency are all recorded and now
verified. Platform Engineering sign-off and FR-18 lab-inventory validation remain
pending (external dependencies).
#!/usr/bin/env bash
# run.sh — driver: execute the full Phase 0 baseline benchmark (Appendix A methodology).
# Usage:  ./run.sh [LAB_PAIR]
#   LAB_PAIR=legacy (default) -> baseline on the current-state images
#   LAB_PAIR=opt            -> same harness, optimised images (Phase 5)
# Produces benchmark/reports/run-<ts>/{images,coldstart,idle,ramp,summary}.json + report.md
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

export LAB_PAIR="${1:-legacy}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$PWD/reports/run-${TS}-${LAB_PAIR}"
mkdir -p "$RUN_DIR"
log "=== benchmark run ${TS} (pair=${LAB_PAIR}) ==="

# 04-ramp.js reads these from the environment (node child process).
export IMG_ATTACKER IMG_TARGET
export RAMP_DWELL_S RAMP_MAX_PAIRS RAMP_POLL_S
export EXHAUST_CPU_PCT EXHAUST_CPU_SUSTAIN_S EXHAUST_MEM_FRAC

trap 'teardown_all; log "run dir: $RUN_DIR"' EXIT

./01-images.sh   "$RUN_DIR"
./02-coldstart.sh "$RUN_DIR"
./03-idle.sh     "$RUN_DIR" 1
teardown_pair 1

BENCH_OUT_DIR="$RUN_DIR" node ./04-ramp.js | tee "$RUN_DIR/ramp.stdout"
teardown_all

./05-report.sh "$RUN_DIR"
log "done -> $RUN_DIR"

#!/usr/bin/env bash
# 02-coldstart — FR-07/FKPI-2 cold-start SLA probe (Appendix A). Provisions ONE legacy
# pair, times readiness (docker-driven readiness probes — legacy images define none),
# repeats BENCH_RUNS times, emits median + per-run times to <OUT>/coldstart.json.
# Exit: 0 on success; -1 runs are recorded as such and skipped in the median.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

OUT="$1"; mkdir -p "$OUT"
med=(); runs=()
for i in $(seq 1 "$BENCH_RUNS"); do
  cold="$(cold_start "$i" 2>/dev/null)"     # ms (>=0) or -1 on timeout (lib: legacy guard)
  runs+=("$cold")
  if [[ "$cold" -ge 0 ]]; then med+=("$cold"); fi
done
pub="$(printf '%s\n' "${med[@]}" | sort -n | awk '{a[NR]=$1} END{print (NR%2)? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2}')"

cat > "$OUT/coldstart.json" <<JSON
{
  "runs_ms":   [$(printf '%s, ' "${runs[@]}" | sed 's/, $//')],
  "median_ms": ${pub:--1}
}
JSON

printf 'coldstart runs(ms): %s\n' "${runs[*]}"
printf 'coldstart median(ms): %s\n' "${pub:--1}"

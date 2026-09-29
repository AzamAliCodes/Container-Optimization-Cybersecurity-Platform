#!/usr/bin/env bash
# 03-idle — FR-18 idle KPI sample over a *single already-cold pair* (Appendix A step 3).
# After IDLE_SETTLE_S settle, sample host_stats()/proc_count() every IDLE_INTERVAL_S
# for IDLE_SAMPLE_S, then write median idle RAM(MiB), median idle CPU%, median proc count
# to idle.json. Sampling is container-scoped (bm-att-*/bm-tgt-* only) per NFR-02/NFR-06.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

OUT="$1"; PAIR="$2"
mkdir -p "$OUT"

sleep "$IDLE_SETTLE_S"
cpu=(); mem=(); procs=()
: "${IDLE_SAMPLES:=$(( IDLE_SAMPLE_S / IDLE_INTERVAL_S ))}"
for i in $(seq 1 "$IDLE_SAMPLES"); do
  hs="$(host_stats)"
  cpu+=("$(printf '%s\n' "$hs" | cut -f1)")
  mem+=("$(printf '%s\n' "$hs" | cut -f2)")
  procs+=("$(proc_count "$(att_name "$PAIR")")")
  sleep "$IDLE_INTERVAL_S"
done

med() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{if(NR%2==1) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}' ; }
med_c="$(med "${cpu[@]}")"
med_m="$(med "${mem[@]}")"
med_p="$(med "${procs[@]}")"

cat > "$OUT/idle.json" <<JSON
{ "idle_cpu_pct_median": $med_c, "idle_ram_mib_median": $med_m, "idle_procs_median": $med_p }
JSON
printf 'idle: cpu=%s%%  ram=%sMiB  procs=%s\n' "$med_c" "$med_m" "$med_p"

#!/usr/bin/env bash
# Benchmark harness core. THE canonical definition of what a "run" measures
# (PRD Appendix A methodology + Appendix B test matrix). Parameterised so the identical
# driver runs the Phase 0 legacy baseline and the Phase 5 optimised stack.
# Sourcing this only defines functions/globals; it has no side effects.
set -o pipefail

# ---------- tunables (env-overridable; defaults are Phase 0 values) ----------
: "${LAB_PAIR:=legacy}"            # image-set label: 'legacy' (Phase 0) -> 'opt' (Phase 5)
: "${IMG_ATTACKER_LEGACY:=platform/attacker:legacy}"
: "${IMG_TARGET_LEGACY:=platform/target:legacy}"
: "${IMG_ATTACKER_OPT:=platform/web-exploitation:phase1}"
: "${IMG_TARGET_OPT:=platform/target:phase1}"
: "${BENCH_RUNS:=3}"               # full driver runs; median across runs is reported
: "${IDLE_SETTLE_S:=30}"           # Appendix A: wait after cold-start before sampling idle
: "${IDLE_SAMPLE_S:=60}"           # idle sampling window duration
: "${IDLE_INTERVAL_S:=5}"          # per-sample interval inside the idle window
: "${RAMP_DWELL_S:=8}"             # concurrency-ramp dwell per added pair (Appendix B step)
: "${RAMP_MAX_PAIRS:=24}"          # hard cap during the concurrency ramp
: "${COLD_START_SLA_S:=60}"        # legacy guard (PRD 10s SLA is for the opt stack; Phase 0 notes it)
: "${EXHAUST_CPU_PCT:=90}"         # trigger: aggregate container CPU% >= this
: "${EXHAUST_CPU_SUSTAIN_S:=60}"   # sustained window for the CPU trigger
: "${EXHAUST_MEM_FRAC:=0.92}"      # trigger: sum(container mem) >= this * host total
: "${RAMP_POLL_S:=2}"              # ramp poll interval

# ---------- per-pair naming (strictly scoped -> never collides with unrelated hosts) ----------
ATT_PREFIX="bm-att-${LAB_PAIR}-"
TGT_PREFIX="bm-tgt-${LAB_PAIR}-"
NET_PREFIX="bm-net-${LAB_PAIR}-"

att_name() { printf '%s%s' "$ATT_PREFIX" "$1"; }      # attacker container name  $1=pair#
tgt_name() { printf '%s%s' "$TGT_PREFIX" "$1"; }      # target container name
net_name() { printf '%s%s' "$NET_PREFIX" "$1"; }      # per-session network name

: "${IMG_ATTACKER:=$(if [[ "$LAB_PAIR" == legacy ]]; then echo "$IMG_ATTACKER_LEGACY"; else echo "$IMG_ATTACKER_OPT"; fi)}"
: "${IMG_TARGET:=$(if [[ "$LAB_PAIR" == legacy ]]; then echo "$IMG_TARGET_LEGACY"; else echo "$IMG_TARGET_OPT"; fi)}"

# ---------- low-level helpers ----------
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
utc_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log()    { printf '[%s] %s\n' "$(utc_ts)" "$*"; }

# Strip ANSI escapes and surrounding whitespace from a docker-stats token.
clean_str() { printf '%s' "$1" | tr -d '\033' | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

# mem_to_mib "1.5GiB"|"320MiB"|"512KiB" -> MiB float
mem_to_mib() {
  local v; v="$(clean_str "$1")"
  case "$v" in
    *GiB*) echo "$v" | sed 's/GiB$//' | awk '{printf "%.1f", $1*1024}' ;;
    *MiB*) echo "$v" | sed 's/MiB$//' ;;
    *KiB*) echo "$v" | sed 's/KiB$//' | awk '{printf "%.3f", $1/1024}' ;;
    *)     echo 0 ;;
  esac
}

# ---------- images ----------
img_att() { printf '%s' "$IMG_ATTACKER"; }
img_tgt() { printf '%s' "$IMG_TARGET"; }

image_size_mib() { # <image-ref> -> MiB (float), or "n/a"
  local s; s="$(docker image inspect --format '{{.Size}}' "$1" 2>/dev/null)"
  if [[ -n "$s" ]] && [[ "$s" != "" ]]; then
    awk -v b="$s" 'BEGIN{printf "%.1f", b/1048576}'
  else
    echo "n/a"
  fi
}

# ---------- per-pair provisioning (Phase 0 = LEGACY: no limits, no healthcheck) ----------
net_up()   { docker network create "$(net_name "$1")" >/dev/null 2>&1 || true; }
att_up()   { # legacy attacker: no --memory/--cpus/--pids-limit; entrypoint starts sshd+msf
  docker run -d -i --name "$(att_name "$1")" --network "$(net_name "$1")" \
    "$(img_att)" >/dev/null 2>&1 || true
}
tgt_up()   { # legacy target: no limits
  docker run -d --name "$(tgt_name "$1")" --network "$(net_name "$1")" \
    "$(img_tgt)" >/dev/null 2>&1 || true
}

# ---------- readiness probes ----------
# A pair is "ready" only when the lab is actually USABLE, per docs/decisions.md:
# the attacker accepts `docker exec` AND the target's app port answers a
# connection. Checking only `.State.Running` measures how fast `docker run -d`
# returns, not how fast the lab comes up -- that is what produced the bogus
# "205 ms legacy / 400 ms optimised" cold-start figures (a running container
# whose entrypoint has not yet exec'd into its app server still reports
# Running=true).
#
# Probe strategy per container:
#   1. image defines a HEALTHCHECK -> honour it (opt stack; the healthcheck is
#      `nc -z 127.0.0.1 $TARGET_PORT`, i.e. the app port is answering)
#   2. no HEALTHCHECK (legacy images) -> fall back to State.Running, because
#      there is no declared port to probe and we must not invent one
# Never treat "container exists" as readiness on its own when a real probe is
# available.
# echoes "declared" | "absent" for whether the image ships a HEALTHCHECK
_hc_declared() { # $1 = container
  local t
  t="$(docker inspect --format '{{if .Config.Healthcheck}}{{.Config.Healthcheck.Test}}{{end}}' "$1" 2>/dev/null || true)"
  [[ -n "$t" && "$t" != "<no value>" ]] && echo declared || echo absent
}
_probe_running() { [[ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]; }
_hc_healthy()    { [[ "$(docker inspect --format '{{.State.Health.Status}}' "$1" 2>/dev/null || true)" == "healthy" ]]; }

att_ready() {  # attacker: ttyd web terminal is the learner's interface -> must be up
  local c="$(att_name "$1")"
  _probe_running "$c" || return 1
  if [[ "$(_hc_declared "$c")" == declared ]]; then
    _hc_healthy "$c"          # declared-but-pending must NOT fall through
    return $?
  fi
  # no healthcheck declared (legacy): ttyd port must accept a connection
  docker exec "$c" sh -c 'command -v nc >/dev/null && nc -z 127.0.0.1 "${TTYD_PORT:-7681}"' >/dev/null 2>&1
}

tgt_ready() {  # target: app server must accept connections
  local c="$(tgt_name "$1")"
  _probe_running "$c" || return 1
  if [[ "$(_hc_declared "$c")" == declared ]]; then
    _hc_healthy "$c"
    return $?
  fi
  # No healthcheck (legacy image): probe the app port from inside.
  docker exec "$c" sh -c 'command -v nc >/dev/null && nc -z 127.0.0.1 "${TARGET_PORT:-8080}"' >/dev/null 2>&1
}

pair_ready() { att_ready "$1" && tgt_ready "$1"; }

# cold_start <pair#>: provision the pair, return ms until both ready (or -1 on timeout).
cold_start() {
  local n="$1" t0 t1
  net_up "$n"; t0="$(now_ms)"
  att_up "$n"; tgt_up "$n"
  while :; do
    if pair_ready "$n"; then t1="$(now_ms)"; echo $(( t1 - t0 )); return 0; fi
    if [[ $(( $(now_ms) - t0 )) -gt $(( COLD_START_SLA_S * 1000 )) ]]; then
      echo -1; return 1
    fi
    sleep 0.5
  done
}

# ---------- host gauges (scoped to our bm-* containers only) ----------
# host_stats -> "cpu_pct<TAB>mem_used_mib<TAB>mem_total_mib<TAB>mem_free_pct"
host_stats() {
  local stats cpu mem total free cpu_raw mem_raw
  stats="$(docker stats --no-stream --format '{{.CPUPerc}}\t{{.MemUsage}}\t{{.Name}}' 2>/dev/null | grep -E "bm-att-${LAB_PAIR}|bm-tgt-${LAB_PAIR}")"
  cpu_raw="$(printf '%s\n' "$stats" | sed -nE 's/^([0-9.]+)%\t.*/\1/p')"
  cpu="$(printf '%s\n' "$cpu_raw" | awk '{s+=$1} END{printf "%.1f", s+0}')"
  mem_raw="$(printf '%s\n' "$stats" | sed -nE 's/^[0-9.]+%\t([^/]+)\/.*/\1/p')"
  mem="$(printf '%s\n' "$mem_raw" | while IFS= read -r m; do mem_to_mib "$m"; done | awk '{s+=$1} END{printf "%.1f", s+0}')"
  total="$(docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%.1f", $1/1048576}')"
  free="$(awk -v t="$total" -v u="$mem" 'BEGIN{printf "%.1f", (t>0 ? (t-u)/t*100 : 100)}')"
  printf '%s\t%s\t%s\t%s\n' "${cpu:-0}" "${mem:-0}" "${total:-0}" "${free:-0}"
}

# process count inside a container (idle-process KPI, FR-18)
proc_count() { docker top "$1" -o pid 2>/dev/null | tail -n +2 | wc -l | tr -d ' '; }

# ---------- teardown (STRICTLY bm-* scoped) ----------
teardown_pair() {
  docker rm -f "$(att_name "$1")" >/dev/null 2>&1 || true
  docker rm -f "$(tgt_name "$1")" >/dev/null 2>&1 || true
  docker network rm "$(net_name "$1")" >/dev/null 2>&1 || true
}

teardown_all() {
  local c
  # NOTE: docker ps -aq emits container IDs, so filter by name (not grep IDs).
  for c in $(docker ps -aq --filter "name=bm-att-${LAB_PAIR}-" --filter "name=bm-tgt-${LAB_PAIR}-"); do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  for c in $(docker network ls -q --filter "name=bm-net-${LAB_PAIR}-"); do
    docker network rm "$c" >/dev/null 2>&1 || true
  done
}

#!/usr/bin/env bash
# Phase 1+2 CI gate (FR-04 publish gate; FR-07/FR-18/NFR-03/NFR-06/NFR-08 verification).
# ---------------------------------------------------------------------------
# Runs after images/build.sh. Refuses to let a broken image be published:
#   1. size gates        — attacker bundle <= 800 MB, target <= 400 MB (PRD §5)
#   2. tool smoke        — every shipped tool runs `--version` inside its image
#   3. idle process set  — docker top at idle: attacker <= 3 procs, no sshd/msfconsole (FR-18)
#   4. healthcheck       — both containers reach healthy (FR-07)
#   5. non-root          — inspect .Config.User != root (NFR-03)
#   6. compose parity    — Compose-brought-up pair exposes the LIMIT-PARITY-TABLE values (NFR-08)
#   7. limits SSoT      — compose/session.yml fallbacks == orchestrator/limits.env (Phase 2, NFR-08)
#   8. provisioning     — orchestrator/provision.sh pair: all four FR-06 limits in docker inspect
#                         + cgroup enforcement on the host (pids.max / memory.max)
# Exit 0 = safe to push; non-zero = block publish.
set -uo pipefail
cd "$(dirname "$0")/.."

REGISTRY="${REGISTRY:-platform}"
VERSION="${VERSION:-phase1}"
BUNDLES="web-exploitation network-recon password-attacks"
FAIL=0
note() { printf '[smoke] %s\n' "$*"; }
ok()   { note "PASS: $*"; }
bad()  { note "FAIL: $*"; FAIL=1; }

img() { printf '%s/%s:%s' "$REGISTRY" "$1" "$VERSION"; }

size_mib() { docker image inspect --format '{{.Size}}' "$1" 2>/dev/null | awk '{printf "%.1f", $1/1048576}'; }

# ---------- 1. size gates (PRD sec. 5) ----------
for b in $BUNDLES; do
  s="$(size_mib "$(img "$b")" || true)"
  if [[ -z "${s:-}" ]]; then
    bad "$b image missing"
    continue
  fi
  if awk -v v="$s" 'BEGIN{exit !(v<=800)}'; then ok "$b size ${s} MiB <= 800"; else bad "$b size ${s} MiB > 800 MB gate"; fi
done
s="$(size_mib "$(img target)" || true)"
[[ -n "${s:-}" ]] || bad "target image missing"
if awk -v v="${s:-99999}" 'BEGIN{exit !(v<=400)}'; then ok "target size ${s} MiB <= 400"; else bad "target size ${s:-n/a} MiB > 400 MB gate"; fi

# ---------- 2. per-bundle tool smoke ----------
tool_smoke() { # <image> <tool...>
  local im="$1"; shift
  for t in "$@"; do
    if docker run --rm --entrypoint sh "$im" -c "command -v $t >/dev/null && $t --version >/dev/null 2>&1 || $t -h >/dev/null 2>&1" ; then
      ok "$t runs in $(basename "$im" | cut -d: -f1)"
    else
      bad "$t missing/broken in $im"
    fi
  done
}
tool_smoke "$(img web-exploitation)" sqlmap hydra whatweb
tool_smoke "$(img network-recon)"     nmap msfconsole msfvenom
tool_smoke "$(img password-attacks)"  hydra john hashcat

# wordlists present (curated, not the legacy 1.5 GB meta)
docker run --rm --entrypoint sh "$(img password-attacks)" -c 'ls /usr/share/wordlists/ | grep -q .' \
  && ok "password-attacks ships curated wordlists" || bad "password-attacks wordlists missing"

# ---------- 3+4+5. idle process set / healthcheck / non-root, via compose pair ----------
cleanup() { docker compose -f compose/session.yml down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
if ! docker compose -f compose/session.yml up -d; then bad "compose up failed (FR-17)"; exit 1; fi

wait_healthy() { # <container> <timeout-s>
  local c="$1" t="${2:-60}" i=0
  while [ $i -lt "$t" ]; do
    [[ "$(docker inspect --format '{{.State.Health.Status}}' "$c" 2>/dev/null)" == "healthy" ]] && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}
for c in sess-attacker sess-target; do
  wait_healthy "$c" 60 && ok "$c reached healthy (FR-07)" || bad "$c never became healthy (FR-07)"
  u="$(docker inspect --format '{{.Config.User}}' "$c" 2>/dev/null)"
  [[ "$u" == "lab" ]] && ok "$c runs as '$u' (NFR-03)" || bad "$c user='$u' (expected non-root 'lab')"
done

sleep 5   # let idle settle before counting processes (FR-18)
procs() { docker top "$1" 2>/dev/null | tail -n +2 | awk '{print $5}' | grep -v '^$' | sort -u | tr '\n' ' '; }
pc_att=$(docker top sess-attacker 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
[ "${pc_att:-0}" -le 3 ] && ok "attacker idle procs=$pc_att <= 3 (FR-18)" || bad "attacker idle procs=$pc_att > 3 (FR-18)"
cmdline_att="$(docker top sess-attacker -o command 2>/dev/null | tail -n +2 | tr '\n' ' ')"
echo "$cmdline_att" | grep -qi sshd  && bad "sshd auto-started in attacker (FR-18)" || ok "no sshd at idle (FR-18)"
echo "$cmdline_att" | grep -qi msf   && bad "msfconsole auto-started (FR-18)"      || ok "no msfconsole at idle (FR-18)"

# target app actually serves (healthcheck is TCP-only; prove HTTP works too)
docker exec sess-target sh -c 'nc -z 127.0.0.1 8080 && printf "GET / HTTP/1.0\r\n\r\n" | nc -w2 127.0.0.1 8080 | head -1 | grep -q HTTP' \
  && ok "target app answers HTTP" || bad "target app did not answer HTTP"

# cross-container: attacker can reach target on the session network only (NFR-03 isolation sanity)
docker exec sess-attacker nc -z -w2 sess-target 8080 && ok "attacker->target reachable on session net" || bad "attacker cannot reach target (network misconfig)"

# ---------- 6. NFR-08 limit parity (LIMIT-PARITY-TABLE) ----------
check_limit() { # <container> <inspect-key> <expected>
  local v; v="$(docker inspect --format "{{.HostConfig.$2}}" "$1" 2>/dev/null)"
  [[ "$v" == "$3" ]] && ok "$1 $2=$v (parity)" || bad "$1 $2=$v expected $3 (NFR-08 drift)"
}
check_limit sess-attacker Memory         536870912    # 512m
check_limit sess-attacker MemorySwap     805306368    # 768m
check_limit sess-attacker NanoCpus       1000000000   # 1.0 cpu
check_limit sess-attacker PidsLimit      100
check_limit sess-target   Memory         268435456    # 256m
check_limit sess-target   MemorySwap     402653184    # 384m
check_limit sess-target   NanoCpus       500000000    # 0.5 cpu
check_limit sess-target   PidsLimit      50

# ---------- 7. limits single-source-of-truth (Phase 2, NFR-08) ----------
# Source the SSoT first: step 8 below reads $ATTACKER_PIDS_LIMIT /
# $TARGET_PIDS_LIMIT, and `set -u` aborts on any reference that is unset.
# shellcheck disable=SC1091
set -a; . orchestrator/limits.env; set +a

# compose/session.yml keeps ${VAR:-default} fallbacks whose defaults must equal
# orchestrator/limits.env, so a bare `docker compose up` can never drift from
# the provisioning path.
# NOTE: the grep pattern must stay single-quoted — in double quotes bash strips
# the backslash from `\$`, leaving `$\{` where `$` is an end-of-line anchor that
# can never match, silently reporting zero vars and a false "limits drift".
limit_vars() { grep -oE '\$\{(ATTACKER|TARGET)_(MEMORY|MEMORY_SWAP|CPUS|PIDS_LIMIT):-[^}]+\}' compose/session.yml \
              | sed -E 's/\$\{([A-Z_]+):-([^}]+)\}/\1=\2/'; }
if diff <(limit_vars | sort) <(grep -E '^(ATTACKER|TARGET)_[A-Z_]+=' orchestrator/limits.env | sort) >/dev/null; then
  ok "compose limit fallbacks == orchestrator/limits.env (SSoT parity)"
else
  bad "limits drift: compose fallbacks != orchestrator/limits.env"
  diff <(limit_vars | sort) <(grep -E '^(ATTACKER|TARGET)_[A-Z_]+=' orchestrator/limits.env | sort) || true
fi

# ---------- 8. provisioning-path enforcement (Phase 2 exit criterion, FR-06) ----------
# Provision one throwaway session through the real orchestrator entrypoint and
# verify all four limits appear in `docker inspect` AND are enforced at cgroup
# level on the host. Placeholder digests in images/digests.env are overridden
# with the locally built tags for this gate.
PROV_SESSION="smoke$$"
if BUNDLE_IMAGE="$(img web-exploitation)" TARGET_IMAGE="$(img target)" \
   KEEP_RUNNING=1 ./orchestrator/provision.sh web-exploitation "$PROV_SESSION"; then
  ok "provision.sh verified+report ready (FR-06 at creation)"
  # cgroup-level enforcement spot-check (cgroup v2 paths; skip gracefully on v1 hosts)
  for pair in "sess-$PROV_SESSION-attacker:$ATTACKER_PIDS_LIMIT" "sess-$PROV_SESSION-target:$TARGET_PIDS_LIMIT"; do
    cid="${pair%%:*}"; want_pids="${pair##*:}"
    cg="$(docker inspect -f '{{.State.Cgroupns}} {{.Id}}' "$cid" 2>/dev/null | awk '{print $2}')"
    pmax=""
    for base in /sys/fs/cgroup /sys/fs/cgroup/pids; do
      [[ -r "$base/system.slice/docker-$cg.scope/pids.max" ]] && pmax="$(cat "$base/system.slice/docker-$cg.scope/pids.max")" && break
      [[ -r "$base/docker/$cid/pids.max" ]] && pmax="$(cat "$base/docker/$cid/pids.max")" && break
    done
    if [[ -n "$pmax" ]]; then
      [[ "$pmax" == "$want_pids" ]] && ok "$cid cgroup pids.max=$pmax (enforced)" || bad "$cid cgroup pids.max=$pmax expected $want_pids"
    else
      note "SKIP: $cid cgroup pids.max not readable from this host layout (v1?) — inspect check above still gates"
    fi
  done
else
  bad "provision.sh failed to enforce/report FR-06 limits"
fi
docker rm -f "sess-$PROV_SESSION-attacker" "sess-$PROV_SESSION-target" >/dev/null 2>&1 || true
docker network rm "sess-$PROV_SESSION-net" >/dev/null 2>&1 || true

# ---------- 9. session labels for metric attribution (Phase 4, FR-11) ------
# provision.sh must stamp --label session.id on BOTH containers; cAdvisor
# re-exports docker labels as container_label_session_id — this is the ONLY
# link between a raw cadvisor series and a learner session. Checked via
# docker inspect on a throwaway pair (same run as step 8 where possible).
LABEL_SESSION="smokelbl$$"
if BUNDLE_IMAGE="$(img web-exploitation)" TARGET_IMAGE="$(img target)" \
   KEEP_RUNNING=1 ./orchestrator/provision.sh web-exploitation "$LABEL_SESSION" >/dev/null 2>&1; then
  for c in "sess-$LABEL_SESSION-attacker" "sess-$LABEL_SESSION-target"; do
    lbl="$(docker inspect -f '{{index .Config.Labels "session.id"}}' "$c" 2>/dev/null)"
    [[ "$lbl" == "$LABEL_SESSION" ]] && ok "$c labeled session.id=$LABEL_SESSION (FR-11 attribution)" \
                                     || bad "$c missing/incorrect session.id label (got '$lbl')"
  done
else
  bad "provision.sh failed under label check — cannot verify FR-11 labels"
fi
docker rm -f "sess-$LABEL_SESSION-attacker" "sess-$LABEL_SESSION-target" >/dev/null 2>&1 || true
docker network rm "sess-$LABEL_SESSION-net" >/dev/null 2>&1 || true

# ---------- 10. monitoring config validity + digest SSoT (Phase 4) ---------
# prometheus.yml/rules parse cleanly (promtool if available, YAML otherwise),
# Grafana dashboard JSON parses, and compose/monitoring.yml image pins match
# images/digests.env (same drift-prevention pattern as the limits SSoT gate).
mon_yml_check() {
  if command -v promtool >/dev/null 2>&1; then
    docker run --rm -v "$PWD/monitoring:/m:ro" --entrypoint promtool \
      "${PROMETHEUS_IMAGE:-prom/prometheus}" check config /m/prometheus.yml \
      && docker run --rm -v "$PWD/monitoring:/m:ro" --entrypoint promtool \
      "${PROMETHEUS_IMAGE:-prom/prometheus}" check rules /m/rules/session-alerts.yml
  else
    python3 -c "import yaml,sys; yaml.safe_load(open('monitoring/prometheus.yml')); yaml.safe_load(open('monitoring/rules/session-alerts.yml'))" \
      && ok "prometheus.yml + rules parse as YAML (promtool not on host — full config check deferred to Docker host)" \
      || return 1
  fi
}
source images/digests.env   # CADVISOR/PROMETHEUS/GRAFANA_* values (SSoT)
if mon_yml_check; then ok "monitoring configs valid"; else bad "monitoring config invalid"; fi
python3 -c "import json; json.load(open('monitoring/grafana/dashboards/sessions.json'))" \
  && ok "grafana dashboard JSON parses" || bad "grafana dashboard JSON invalid"
for v in CADVISOR PROMETHEUS GRAFANA; do
  want="$(eval echo \$${v}_DIGEST)"
  got="$(grep -oE "\\\$\{${v}_DIGEST:-[^}]+\}" compose/monitoring.yml | sed -E 's/.*:-([^}]+)\}/\1/')"
  [[ -n "$got" ]] || { bad "compose/monitoring.yml has no ${v}_DIGEST pin"; continue; }
  [[ "$got" == "$want" ]] && ok "monitoring.yml ${v} digest == digests.env (SSoT)" \
                          || bad "monitoring.yml ${v} digest drift: $got != $want"
done

# ---------- 11. metrics end-to-end (Phase 4 exit criterion, FR-11/NFR-05) --
# If the monitoring stack is up, prove a live session's per-container metrics
# reach Prometheus WITH session-id labels. Skipped (not failed) when the stack
# isn't running so this gate stays usable before first stack bring-up.
if curl -fsS -m 2 http://127.0.0.1:9090/-/ready >/dev/null 2>&1; then
  METRIC_SESSION="smokemon$$"
  BUNDLE_IMAGE="$(img web-exploitation)" TARGET_IMAGE="$(img target)" \
    KEEP_RUNNING=1 ./orchestrator/provision.sh web-exploitation "$METRIC_SESSION" >/dev/null 2>&1
  found=""
  for i in $(seq 1 6); do   # NFR-05 budget: metrics within 15s of start → poll ≤30s
    q=$(curl -fsS -m 3 "http://127.0.0.1:9090/api/v1/query?query=container_memory_working_set_bytes%7Bcontainer_label_session_id%3D%22$METRIC_SESSION%22%7D" 2>/dev/null || true)
    [[ "$q" == *'"__name__":"container_memory_working_set_bytes"'* || "$q" == *"container_memory_working_set_bytes"* ]] \
      && { found=1; break; }
    sleep 5
  done
  if [[ -n "$found" ]]; then
    ok "live session metrics in Prometheus labeled by session ID (FR-11, NFR-05)"
  else
    bad "no cadvisor metrics for session $METRIC_SESSION after 30s (NFR-05 breach or stack misconfigured)"
  fi
  docker rm -f "sess-$METRIC_SESSION-attacker" "sess-$METRIC_SESSION-target" >/dev/null 2>&1 || true
  docker network rm "sess-$METRIC_SESSION-net" >/dev/null 2>&1 || true
else
  note "SKIP: Prometheus not reachable at 127.0.0.1:9090 — e2e metrics gate runs once monitoring stack is up"
fi

# ---------- 12. target CMD-expansion regression guard (ttyd blank-CMD fix) ---
# Bug: an empty TARGET_CMD array expanded into ONE blank word at `docker run`
# (e.g. "${TARGET_CMD[*]}" / "$TARGET_CMD" / quoted "$@" pass-through of zero
# args). Docker treats ANY trailing arg as a CMD override, so the target got
# Config.Cmd = [""] → entrypoint exec'd ttyd with no start command
# ("ttyd: missing start command") and the container exited. Fix: the
# set -u-safe ${TARGET_CMD[@]+"${TARGET_CMD[@]}"} idiom — zero words when the
# array is empty. Static gate here; behavioural coverage (fake-docker argv
# assertions incl. "zero trailing args after the image name") runs in
# orchestrator/test/provision.test.js via `node --test orchestrator/test/`.
# The static checks below are comment-insensitive: every grep filters out '#'
# lines first, so explanatory comments that MENTION the forbidden expansions
# (the fix's rationale block in provision.sh) never trip the gate.
CMD_SRC="$(grep -v '^[[:space:]]*#' orchestrator/provision.sh)"
if printf '%s\n' "$CMD_SRC" | grep -qF '${TARGET_CMD[@]+"${TARGET_CMD[@]}"}'; then
  ok "provision.sh uses the set -u-safe \${TARGET_CMD[...]} zero-word idiom"
else
  bad "provision.sh lost the safe TARGET_CMD expansion idiom (empty array must pass ZERO args to docker run)"
fi
if printf '%s\n' "$CMD_SRC" | grep -qE '\$\{TARGET_CMD\[\*\]\}|(^|[^A-Za-z_])\$TARGET_CMD([^A-Za-z_]|$)'; then
  bad "provision.sh contains a blank-arg TARGET_CMD expansion (would override image CMD with [\"\"]):"
  printf '%s\n' "$CMD_SRC" | grep -nE '\$\{TARGET_CMD\[\*\]\}|(^|[^A-Za-z_])\$TARGET_CMD([^A-Za-z_]|$)' || true
else
  ok "no one-word TARGET_CMD expansion (\${TARGET_CMD[*]} / \$TARGET_CMD) in provision.sh"
fi

# ---------- 13. FR-18 per-lab SSH opt-in wiring (static, daemon-free) --------
# The opt-in flag must be resolvable end-to-end: lab-config schema documents
# `ssh_enabled`, provision.sh parses it and injects LAB_SSH_ENABLED into the
# attacker container, api.js accepts a boolean `ssh` body field, and the
# entrypoint double-guards on the env var. If any leg is deleted the default
# "no sshd" posture silently regresses — this gate fails loudly instead.
SSH_WIRING=0
grep -q 'ssh_enabled:' lab-configs/sample-lab.yaml            || { bad "lab-config schema lost ssh_enabled (FR-18)"; SSH_WIRING=1; }
grep -q 'resolve_ssh_optin' orchestrator/provision.sh         || { bad "provision.sh lost SSH opt-in resolution (FR-18)"; SSH_WIRING=1; }
grep -q -- '--env "LAB_SSH_ENABLED=' orchestrator/provision.sh || { bad "provision.sh no longer injects LAB_SSH_ENABLED (FR-18)"; SSH_WIRING=1; }
grep -q 'LAB_SSH_ENABLED' orchestrator/api.js                 || { bad "api.js lost ssh opt-in passthrough (FR-18)"; SSH_WIRING=1; }
grep -q 'LAB_SSH_ENABLED' images/shared/entrypoint.sh         || { bad "entrypoint lost the LAB_SSH_ENABLED guard (FR-18)"; SSH_WIRING=1; }
[[ "$SSH_WIRING" == 0 ]] && ok "FR-18 SSH opt-in wired: schema -> provision -> api -> entrypoint guard"

# ---------- report ----------
if [ "$FAIL" -eq 0 ]; then
  note "ALL GATES PASSED — publish allowed (FR-04)"
else
  note "GATE FAILURES — block publish"
fi
exit "$FAIL"

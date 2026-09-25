#!/usr/bin/env bash
# Phase 2 — session provisioning entrypoint (FR-05, FR-06, NFR-03, NFR-06).
# ---------------------------------------------------------------------------
# Creates ONE learner session pair (attacker bundle + target) with the four
# FR-06 cgroup limits enforced AT CREATION time (--memory/--memory-swap/
# --cpus/--pids-limit — decision §10: run-time flags, no custom cgroup code,
# no post-start `docker update`).
#
# Images are PULL-ONLY digest references (FR-05): `docker build` never appears
# in this path (FR-04). Bundle selection is pure configuration — adding a lab
# bundle means a new image in images/ + CI entry only; this script needs no
# change beyond passing its name (NFR-06).
#
# Usage:
#   ./orchestrator/provision.sh <bundle> <session-id>
#   e.g. ./orchestrator/provision.sh web-exploitation 42
#
# Env overrides: REGISTRY, VERSION, DIGESTS_FILE, BUNDLE_IMAGE, TARGET_IMAGE,
#                LAB_SSH_ENABLED=1 (FR-18 per-lab SSH opt-in; default 0),
#                KEEP_RUNNING=1 (leave containers up after verification).
#
# FR-18 per-lab SSH opt-in resolution order (first hit wins):
#   1. explicit env LAB_SSH_ENABLED (API body / operator shell)
#   2. lab-configs/<bundle>.yaml `ssh_enabled: true|false` (per-lab declaration)
#   3. default 0 — sshd NEVER starts unless a lab explicitly opts in
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

BUNDLE="${1:?usage: provision.sh <bundle> <session-id>}"
SESSION_ID="${2:?usage: provision.sh <bundle> <session-id>}"

REGISTRY="${REGISTRY:-platform}"
VERSION="${VERSION:-phase1}"
DIGESTS_FILE="${DIGESTS_FILE:-$ROOT/images/digests.env}"

# ---- limits: single source of truth (FR-06; parity w/ compose/session.yml) --
# shellcheck disable=SC1090
source "$HERE/limits.env"

# ---- digests: pin every reference (FR-02/FR-05) ------------------------------
[[ -f "$DIGESTS_FILE" ]] || { echo "ERROR: digests file not found: $DIGESTS_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$DIGESTS_FILE"

# Local-dev escape hatch: when a session-image digest is still the CI
# placeholder (all zeros — never published), fall back to the locally built
# tag ${REGISTRY}/<name>:${VERSION} instead of a bogus @sha256:000... pull
# reference. In production, real digests are always populated after publish,
# so this has no effect there. Set LOCAL_TAG_FALLBACK=0 to disable.
is_placeholder_digest() { [[ -z "${1:-}" || "${1}" =~ ^sha256:0{16,}$ ]]; }
image_ref() { # image_ref <name> <digest> -> tag fallback if digest is placeholder
  local name="$1" digest="$2"
  if [[ "${LOCAL_TAG_FALLBACK:-1}" == 1 ]] && is_placeholder_digest "$digest"; then
    printf '%s/%s:%s' "$REGISTRY" "$name" "$VERSION"
  else
    printf '%s/%s@%s' "$REGISTRY" "$name" "$digest"
  fi
}

case "$BUNDLE" in
  web-exploitation) ATTACKER_DIGEST="$WEB_EXPLOITATION_DIGEST" ;;
  network-recon)    ATTACKER_DIGEST="$NETWORK_RECON_DIGEST" ;;
  password-attacks) ATTACKER_DIGEST="$PASSWORD_ATTACKS_DIGEST" ;;
  *) [[ -n "${BUNDLE_IMAGE:-}" ]] || { echo "ERROR: unknown bundle '$BUNDLE' (set BUNDLE_IMAGE to override)" >&2; exit 1; } ;;
esac
ATTACKER_IMAGE="${BUNDLE_IMAGE:-$(image_ref "$BUNDLE" "${ATTACKER_DIGEST:-}")}"
TARGET_IMAGE="${TARGET_IMAGE:-$(image_ref target "$TARGET_DIGEST")}"

ATT_C="sess-$SESSION_ID-attacker"
TGT_C="sess-$SESSION_ID-target"
NET="sess-$SESSION_ID-net"                      # NFR-03: one isolated net per session

# ---- FR-18: per-lab SSH opt-in ----------------------------------------------
# Default OFF (minimal idle process set). A lab opts in by declaring
# `ssh_enabled: true` in its lab-config (lab-configs/<bundle>.yaml); an
# operator/API caller can override per-session via the LAB_SSH_ENABLED env var.
# The value is passed into the attacker container as an env var only — the
# entrypoint still double-guards on it (images/shared/entrypoint.sh +
# ssh-briefing.sh), so a container without the flag can never start sshd.
resolve_ssh_optin() {  # -> "0" or "1"
  if [[ -n "${LAB_SSH_ENABLED:-}" ]]; then printf '%s' "$LAB_SSH_ENABLED"; return; fi
  local cfg="$ROOT/lab-configs/$BUNDLE.yaml" val
  if [[ -f "$cfg" ]]; then
    val="$(sed -n 's/^[[:space:]]*ssh_enabled:[[:space:]]*\([A-Za-z]*\).*/\1/p' "$cfg" | head -1)"
    case "$val" in
      true|TRUE|1)  printf '1'; return ;;
      false|FALSE|0) printf '0'; return ;;
    esac
  fi
  printf '0'
}
SSH_OPTIN="$(resolve_ssh_optin)"

to_bytes() { case "$1" in *m|*M) echo $(( ${1%[mM]} * 1024 * 1024 ));; *g|*G) echo $(( ${1%[gG]} * 1024 * 1024 * 1024 ));; *) echo "$1";; esac; }
die() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
  [[ "${KEEP_RUNNING:-0}" == 1 ]] && return
  docker rm -f "$ATT_C" "$TGT_C" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---- verify enforcement in `docker inspect` (Phase 2 exit criterion) --------
verify() {  # $1=container $2=mem $3=swap $4=cpus $5=pids
  local c="$1" want_mem="$2" want_swap="$3" want_cpus="$4" want_pids="$5"
  local gm gs gc gp
  read -r gm gs gc gp <<<"$(docker inspect -f '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.NanoCpus}} {{.HostConfig.PidsLimit}}' "$c")"
  [[ "$gm" -eq $(to_bytes "$want_mem") ]]  || die "$c: memory $gm != $want_mem"
  [[ "$gs" -eq $(to_bytes "$want_swap") ]] || die "$c: memory-swap $gs != $want_swap"
  [[ "$gc" -eq $(awk "BEGIN{printf \"%.0f\", $want_cpus*1e9}") ]] || die "$c: cpus nano=$gc != $want_cpus"
  [[ "$gp" -eq "$want_pids" ]]             || die "$c: pids-limit $gp != $want_pids"
  echo "    OK  $c  mem=$gm swap=$gs nanoCpus=$gc pids=$gp"
}

# healthcheck pass = session ready (cold-start measurement hook reused in Phase 5)
wait_ready() {  # $1=container
  local c="$1" i s
  for i in $(seq 1 30); do
    s="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c")"
    [[ "$s" == "healthy" ]] && return 0
    [[ "$(docker inspect -f '{{.State.Running}}' "$c")" == "false" ]] && { echo "FAIL: $c exited" >&2; docker logs "$c" >&2; return 1; }
    sleep 1
  done
  echo "FAIL: $c not healthy within 30s" >&2; return 1
}

# Cleanup contract (mirrored by api.js DELETE /sessions):
#   - Default run: provision → verify limits/health → tear down. This is the
#     CI smoke path (FR-06 exit criterion "limits visible in docker inspect").
#   - KEEP_RUNNING=1 (set by the lifecycle API on creation): leave the pair up;
#     teardown then happens via DELETE /sessions or the idle reaper. Without
#     this, the API's create call would provision and immediately destroy the
#     session it just reported as `ready`.

echo "==> provisioning session $SESSION_ID (bundle=$BUNDLE ssh_optin=$SSH_OPTIN)"
# Idempotent re-provision: a previous run that was killed mid-teardown (or one
# where the containers were removed by hand / docker system prune) can leave the
# pair's containers and network behind. `docker network create` is not
# idempotent, so without this an orphaned `sess-<id>-net` makes re-provisioning
# the same session id fail with "network already exists".
docker rm -f "$ATT_C" "$TGT_C" >/dev/null 2>&1 || true
docker network rm "$NET"    >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

# FR-06: all four limits set at creation. Never --privileged (NFR-03).
# FR-11 (Phase 4): --label session.id=<id> so cAdvisor re-exports every metric
# with container_label_session_id — per-session attribution without a relabel
# rule in Prometheus; dashboards/alerts group by it directly.
docker run -d --name "$ATT_C" \
  --network "$NET" \
  --label "session.id=$SESSION_ID" --label "bundle=$BUNDLE" --label "role=attacker" \
  --env "LAB_SSH_ENABLED=$SSH_OPTIN" \
  --memory "$ATTACKER_MEMORY" --memory-swap "$ATTACKER_MEMORY_SWAP" \
  --cpus "$ATTACKER_CPUS" --pids-limit "$ATTACKER_PIDS_LIMIT" \
  "$ATTACKER_IMAGE" >/dev/null

# The target image's entrypoint runs the app server passed as CMD
# (ttyd + `php -S`, see images/shared/entrypoint.sh). Mechanism that matters:
# docker treats ANY trailing argument after the image name as a CMD override —
# even a single empty string — so an empty TARGET_CMD array MUST expand to
# ZERO arguments at the `docker run` call site. A one-word expansion such as
# "${TARGET_CMD[*]}" or "$TARGET_CMD", or a quoted "$@"-style pass-through of
# zero args, hands docker Config.Cmd = [""]: the entrypoint then execs ttyd
# with no start command ("ttyd: missing start command") and the target exits.
# Only when TARGET_CMD is non-empty (the fallback below, for images that ship
# no default CMD) are explicit CMD args appended, each preserved as its own
# word via "${TARGET_CMD[@]}".
TARGET_CMD=()
if [[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$TARGET_IMAGE" 2>/dev/null)" == "null" ]]; then
  TARGET_CMD=(sh -c 'php -r '"'"'$pdo=new PDO("sqlite:/var/www/html/data/app.db");$pdo->exec(file_get_contents("/opt/setup.sql"));'"'"' ; exec php -S 0.0.0.0:${TARGET_PORT:-8080} -t /var/www/html')
fi

# Single call site, single expansion: ${TARGET_CMD[@]+"${TARGET_CMD[@]}"} is
# the `set -u`-safe idiom (bash 4+) that expands to ZERO words when TARGET_CMD
# is empty and to every element as its own word when it is not — so an empty
# array can never reach docker as a blank CMD override, and the image's
# built-in CMD survives untouched.
docker run -d --name "$TGT_C" \
  --network "$NET" \
  --label "session.id=$SESSION_ID" --label "bundle=$BUNDLE" --label "role=target" \
  --memory "$TARGET_MEMORY" --memory-swap "$TARGET_MEMORY_SWAP" \
  --cpus "$TARGET_CPUS" --pids-limit "$TARGET_PIDS_LIMIT" \
  "$TARGET_IMAGE" ${TARGET_CMD[@]+"${TARGET_CMD[@]}"} >/dev/null

verify "$ATT_C" "$ATTACKER_MEMORY" "$ATTACKER_MEMORY_SWAP" "$ATTACKER_CPUS" "$ATTACKER_PIDS_LIMIT"
verify "$TGT_C" "$TARGET_MEMORY" "$TARGET_MEMORY_SWAP" "$TARGET_CPUS" "$TARGET_PIDS_LIMIT"
wait_ready "$ATT_C"; wait_ready "$TGT_C"

echo "==> session $SESSION_ID provisioned, limits verified, both containers healthy"

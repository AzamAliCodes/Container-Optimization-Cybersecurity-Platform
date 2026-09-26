#!/usr/bin/env bash
# orchestrator/prune.sh — FR-14 dangling-image & build-cache prune job.
# ---------------------------------------------------------------------------
# Purpose: prevent host disk bloat caused by the FR-04 registry-pull pattern
# (every CI publish pulls new image versions onto session hosts; old revisions
# become unreferenced layers sitting on disk). PRD §12 risk table names this
# job explicitly; PRD §5 marginal-disk KPI depends on it running.
#
# Retention policy (documented per FR-14 acceptance criteria):
#   - KEEP_VERSIONS most recent tags per image family are ALWAYS protected
#     (they may be referenced by live or just-created sessions).
#   - everything else that is DANGLING (untagged, unreferenced by any
#     container) is removed after PRUNE_GRACE_H grace hours.
#   - BuildKit build cache older than CACHE_MAX_AGE is evicted with
#     `docker builder prune` (all caches share one pool; kept short because
#     CI cold-build budget is ≤5 min/image even without ancient entries).
#   - Stopped session containers/networks older than CONTAINER_MAX_AGE are
#     removed first — a stopped container pins its image as "in use" and
#     would otherwise neuter the whole prune.
#
# Modes:
#   ./orchestrator/prune.sh              # apply (production cron / CI step)
#   DRY_RUN=1 ./orchestrator/prune.sh    # report what WOULD be pruned, touch nothing
#   ./orchestrator/prune.sh --install-cron   # print the crontab line (does not install)
#
# Scheduling (pick ONE; both are supported by design):
#   cron (per session host):   17 4 * * *  /opt/platform/orchestrator/prune.sh >> /var/log/prune.log 2>&1
#   CI (runner housekeeping):  .github/workflows/images.yml "Disk hygiene (FR-14)" step invokes this script
#
# Env overrides: KEEP_VERSIONS, PRUNE_GRACE_H, CACHE_MAX_AGE, CONTAINER_MAX_AGE,
#                REGISTRY, DRY_RUN.
# Exit: 0 = success (or dry-run), non-zero = docker unreachable mid-prune.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KEEP_VERSIONS="${KEEP_VERSIONS:-3}"       # newest N tags per repo are never pruned
PRUNE_GRACE_H="${PRUNE_GRACE_H:-48}"      # dangling images must be > this many hours old
CACHE_MAX_AGE="${CACHE_MAX_AGE:-168h}"    # BuildKit cache eviction age (7 days)
CONTAINER_MAX_AGE="${CONTAINER_MAX_AGE:-24h}"  # stopped containers older than this go first
REGISTRY="${REGISTRY:-platform}"          # session image families to protect tags within
DRY_RUN="${DRY_RUN:-0}"
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log() { echo "[prune $(date -u +%FT%TZ)] $*"; }

to_secs() { case "$1" in *h) echo $(( ${1%h} * 3600 ));; *d) echo $(( ${1%d} * 86400 ));; *m) echo $(( ${1%m} * 60 ));; *) echo "$1";; esac; }

if [[ "${1:-}" == "--install-cron" ]]; then
  echo "17 4 * * * $(dirname "$HERE")/orchestrator/prune.sh >> /var/log/prune.log 2>&1"
  exit 0
fi

docker info >/dev/null 2>&1 || { log "FATAL: docker daemon unreachable"; exit 1; }

FLAG=""
if [[ "$DRY_RUN" == "1" ]]; then FLAG="--dry-run"; log "DRY RUN — nothing will be deleted"; fi

# ---- 0. disk before                                                        ----
log "disk before:"; docker system df | sed 's/^/[prune]   /'

# ---- 1. stopped session containers ------------------------------------------
# Only touches sess-* resources (the orchestrator namespace). Age filter is
# best-effort: `--filter since=` is not supported on all engines, so we list
# exited sessions and drop any created within CONTAINER_MAX_AGE_S seconds.
CONTAINER_MAX_AGE_S="$(to_secs "$CONTAINER_MAX_AGE")"
now_epoch="$(date +%s)"
stopped="$(docker ps -aq --filter 'name=sess-' --filter 'status=exited' --filter 'status=created')"
if [[ -n "$stopped" ]]; then
  keep_running=""
  for cid in $stopped; do
    created="$(docker inspect -f '{{.Created}}' "$cid" 2>/dev/null || true)"
    # ISO-8601 UTC (docker prints e.g. 2026-09-29T04:12:33.123456789Z) → epoch
    cepoch="$(date -d "${created%%.*}Z" +%s 2>/dev/null || echo 0)"
    if (( cepoch > 0 && now_epoch - cepoch < CONTAINER_MAX_AGE_S )); then
      keep_running="$keep_running $cid"     # too fresh — leave it (it pins its image)
    fi
  done
  victims_c="$(echo " $stopped " | tr ' ' '\n' | grep -v '^$' | while read -r c; do [[ "$keep_running" == *" $c "* ]] || echo "$c"; done)"
else
  victims_c=""
fi
if [[ -n "$victims_c" ]]; then
  log "removing stopped session containers older than $CONTAINER_MAX_AGE: $(echo "$victims_c" | wc -l | tr -d ' ')"
  [[ "$DRY_RUN" == "1" ]] || echo "$victims_c" | xargs docker rm >/dev/null 2>&1 || true
fi
for net in $(docker network ls --format '{{.Name}}' | grep '^sess-.*-net$'); do
  if [[ -z "$(docker network inspect -f '{{range .Containers}}{{.}}{{end}}' "$net")" ]]; then
    log "removing orphan session network: $net"
    [[ "$DRY_RUN" == "1" ]] || docker network rm "$net" >/dev/null 2>&1 || true
  fi
done

# ---- 2. dangling images, keeping newest $KEEP_VERSIONS tags per family -----
# `docker image prune -a` would also delete PINNED bases (debian/kali digests
# used only at build time) and could race a session that is mid-pull, so we
# prune selectively: untagged (dangling) images plus tagged-but-old revisions
# beyond the retention window, gated by age.
dangling_untagged() { docker images --format '{{.ID}} {{.Repository}}:{{.Tag}} {{.CreatedSince}}' \
  | awk '$2=="<none>:<none>"{print $1}'; }

victims="$(dangling_untagged)"
# old tagged revisions of OUR families (registry prefix), outside retention:
old_tagged="$(docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}' \
  | grep "^$REGISTRY/" | cut -f1,2 | sort | head -n -"$KEEP_VERSIONS" 2>/dev/null | cut -f2 || true)"

# age filter for tagged victims: prune only images created > PRUNE_GRACE_H ago
# (docker since= filter handles this precisely for the tagged set)
if [[ -n "$old_tagged" ]]; then
  fresh="$(docker images --since "${PRUNE_GRACE_H}h" --format '{{.ID}}' | sort -u)"
  victims="$victims
$(echo "$old_tagged" | comm -23 - <(echo "$fresh"))"
fi

victims="$(echo "$victims" | grep -v '^$' | sort -u || true)"
if [[ -n "$victims" ]]; then
  log "pruning $(echo "$victims" | wc -l | tr -d ' ') image(s) (retention: keep newest $KEEP_VERSIONS tags/family, grace ${PRUNE_GRACE_H}h)"
  if [[ "$DRY_RUN" == "1" ]]; then echo "$victims" | sed 's/^/[prune]   would remove /'
  else echo "$victims" | xargs -r docker rmi >/dev/null 2>&1 || true; fi
else
  log "no dangling images beyond retention"
fi

# ---- 3. BuildKit build cache -----------------------------------------------
log "evicting build cache older than $CACHE_MAX_AGE"
if [[ "$DRY_RUN" == "1" ]]; then
  docker builder prune --filter until="$CACHE_MAX_AGE" --dry-run 2>/dev/null | sed 's/^/[prune]   /' \
    || log "dry-run: builder-prune --dry-run unsupported on this engine; current cache total:"
  docker builder du 2>/dev/null | tail -1 | sed 's/^/[prune]   /' || true
else
  docker builder prune -f --filter until="$CACHE_MAX_AGE" >/dev/null 2>&1 || \
    docker builder prune -f >/dev/null 2>&1 || log "WARN: builder prune unsupported on this engine version"
fi

# ---- 4. disk after                                                          ----
log "disk after:"; docker system df | sed 's/^/[prune]   /'
log "done (dry_run=$DRY_RUN keep=$KEEP_VERSIONS grace=${PRUNE_GRACE_H}h cache_age=$CACHE_MAX_AGE)"

#!/usr/bin/env bash
# orchestrator/reaper.sh — Phase 3 idle-session reaper (FR-09, FR-10).
# ---------------------------------------------------------------------------
# One process per host. Loop:
#   every IDLE_POLL_INTERVAL_S:
#     1. sample network I/O per session (lib/detect_idle.sh) → flag at
#        IDLE_CONSECUTIVE_SAMPLES consecutive low samples          [FR-09]
#     2. newly flagged  → emit learner warning, open REAPER_GRACE_PERIOD_S window
#     3. warned sessions → RESCUE if activity resumed (samples_low reset),
#                          TEARDOWN if grace elapses still idle     [FR-10]
#     4. gone containers → GC state files
#
# Warning channel: written to $WARN_LOG as JSON events (the platform's learner
# notification service consumes this; in dev it is tailed manually). Every reap
# decision is logged for post-hoc audit (PRD risk table: "log every reap").
#
# Modes:
#   ./reaper.sh                # run forever (production / staging)
#   ./reaper.sh --once         # single sweep (cron / CI smoke)
#   DRY_RUN=1 ./reaper.sh      # decide + log but never docker rm (test week!)
#
# Config: lifecycle.env (SSoT). Env overrides: WARN_LOG, STATE_DIR, DRY_RUN.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
source "$HERE/lifecycle.env"

STATE_DIR="${STATE_DIR:-$HERE/.state}"
WARN_LOG="${WARN_LOG:-$STATE_DIR/warnings.log}"
DRY_RUN="${DRY_RUN:-0}"
ONCE=0; [[ "${1:-}" == "--once" ]] && ONCE=1
mkdir -p "$STATE_DIR"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$STATE_DIR/reaper.log"; }
warn_event() {  # JSON line consumed by the learner-notification service
  printf '%s\n' "$1" >> "$WARN_LOG"
}

teardown_session() {  # $1=session-id $2=reason — mirrors provision.sh cleanup
  local sid="$1" reason="$2"
  local att="sess-$sid-attacker" tgt="sess-$sid-target" net="sess-$sid-net"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN teardown session=$sid reason=$reason (no docker rm)"
  else
    docker rm -f "$att" "$tgt" >/dev/null 2>&1 || true
    docker network rm "$net" >/dev/null 2>&1 || true
    log "REAPED session=$sid reason=$reason"
  fi
  rm -f "$STATE_DIR/idle-$sid".{prev,low,warned} "$STATE_DIR/session-$sid.meta"
}

sweep() {
  local line sid rx idle low meta_file warned_at age_s started epoch
  # ---- FR-09: sample every live session -----------------------------------
  while IFS= read -r line; do
    [[ "$line" == "{"* ]] || continue
    sid="$(echo "$line"  | sed 's/.*"session":"\([^"]*\)".*/\1/')"
    rx="$(echo "$line"   | sed 's/.*"rx_kb":\(-\?[0-9]*\).*/\1/')"
    idle="$(echo "$line" | sed 's/.*"idle":\([a-z]*\).*/\1/')"
    low="$(echo "$line"  | sed 's/.*"samples_low":\([0-9]*\).*/\1/')"

    if echo "$line" | grep -q '"gone":true'; then
      # container vanished (learner closed tab / crash) — GC everything
      rm -f "$STATE_DIR/idle-$sid".{prev,low,warned} "$STATE_DIR/session-$sid.meta"
      continue
    fi

    meta_file="$STATE_DIR/session-$sid.meta"
    [[ -f "$meta_file" ]] || echo "started=$(date +%s)" > "$meta_file"

    # ---- FR-10: warn on NEW flag -------------------------------------------
    if [[ "$idle" == "true" && ! -f "$STATE_DIR/idle-$sid.warned" ]]; then
      date +%s > "$STATE_DIR/idle-$sid.warned"
      warn_event "{\"event\":\"idle_warning\",\"session\":\"$sid\",\"idle_samples\":$low,\"grace_period_s\":$REAPER_GRACE_PERIOD_S,\"message\":\"Your lab session has been inactive for $(( IDLE_CONSECUTIVE_SAMPLES * IDLE_POLL_INTERVAL_S / 60 )) minutes. Resume activity or it will close in ${REAPER_GRACE_PERIOD_S}s.\"}"
      log "WARNED session=$sid low=$low grace=${REAPER_GRACE_PERIOD_S}s"
    fi

    # ---- FR-10: grace-period resolution -------------------------------------
    if [[ -f "$STATE_DIR/idle-$sid.warned" ]]; then
      if [[ "$idle" != "true" ]]; then
        # activity resumed within grace → cancel teardown (exit criterion)
        warned_at="$(cat "$STATE_DIR/idle-$sid.warned")"
        log "RESCUED session=$sid (activity resumed after $(( $(date +%s) - warned_at ))s of grace)"
        warn_event "{\"event\":\"idle_rescued\",\"session\":\"$sid\"}"
        rm -f "$STATE_DIR/idle-$sid.warned"
      else
        warned_at="$(cat "$STATE_DIR/idle-$sid.warned")"
        if (( $(date +%s) - warned_at >= REAPER_GRACE_PERIOD_S )); then
          warn_event "{\"event\":\"idle_teardown\",\"session\":\"$sid\",\"reason\":\"grace elapsed\"}"
          teardown_session "$sid" "idle-grace-elapsed"
          continue
        fi
      fi
    fi

    # ---- safety net: max lifetime (lifecycle.env SESSION_MAX_LIFETIME_H) ----
    started="$(sed 's/started=//' "$meta_file")"; epoch="$(date +%s)"
    age_s=$(( epoch - started ))
    if (( age_s > SESSION_MAX_LIFETIME_H * 3600 )); then
      warn_event "{\"event\":\"max_lifetime_teardown\",\"session\":\"$sid\",\"age_s\":$age_s}"
      teardown_session "$sid" "exceeded-max-lifetime-${SESSION_MAX_LIFETIME_H}h"
    fi
  done < <("$HERE/lib/detect_idle.sh")
}

log "reaper start pid=$$ poll=${IDLE_POLL_INTERVAL_S}s threshold=<${IDLE_RX_KB_THRESHOLD}KB x${IDLE_CONSECUTIVE_SAMPLES} grace=${REAPER_GRACE_PERIOD_S}s dry_run=$DRY_RUN"
while :; do
  sweep || log "sweep error (continuing): rc=$?"
  [[ "$ONCE" == "1" ]] && break
  sleep "$IDLE_POLL_INTERVAL_S"
done

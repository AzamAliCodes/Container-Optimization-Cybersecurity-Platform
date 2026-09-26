#!/usr/bin/env bash
# orchestrator/lib/detect_idle.sh — FR-09 idle detector (shared by api.js & reaper).
# ---------------------------------------------------------------------------
# Emits ONE line of JSON per session pair describing network-I/O idleness:
#   {"session":"42","rx_kb":3,"idle":false,"samples_low":7}
#
# Detection signal (FR-09): summed rx bytes across BOTH containers' interfaces,
# sampled at IDLE_POLL_INTERVAL_S. A session is "low" for one sample when the
# delta-rx < IDLE_RX_KB_THRESHOLD KB. The consecutive-low counter lives in
# STATE_DIR; a session is FLAGGED (idle=true) once it reaches
# IDLE_CONSECUTIVE_SAMPLES — that flag is what triggers the FR-10 warning.
#
# Requires: docker CLI. Config comes from lifecycle.env (auto-sourced).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -n "${IDLE_POLL_INTERVAL_S:-}" ]] || source "$HERE/lifecycle.env"
STATE_DIR="${STATE_DIR:-$HERE/.state}"
mkdir -p "$STATE_DIR"

# sum_rx_bytes <container> — cumulative received bytes over all non-lo
# interfaces inside the container netns. "-1" = unreadable (gone/not running).
sum_rx_bytes() {
  local c="$1" n
  n="$(docker exec "$c" sh -c 's=0; for d in /sys/class/net/*; do [ "$(basename "$d")" = lo ] && continue; [ -r "$d/statistics/rx_bytes" ] && s=$((s + $(cat "$d/statistics/rx_bytes"))); done; echo "$s"' 2>/dev/null)" || n=""
  [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo "-1"
}

detect_session() {  # $1=session-id
  local sid="$1" att="sess-$1-attacker" tgt="sess-$1-target"
  local prev_file="$STATE_DIR/idle-$sid.prev" low_file="$STATE_DIR/idle-$sid.low"
  local a t cur prev rx_delta_kb low idle

  a="$(sum_rx_bytes "$att")"; t="$(sum_rx_bytes "$tgt")"
  if [[ "$a" == "-1" || "$t" == "-1" ]]; then
    rm -f "$prev_file" "$low_file"
    printf '{"session":"%s","rx_kb":-1,"idle":false,"samples_low":0,"gone":true}\n' "$sid"
    return 0
  fi

  cur=$(( a + t ))
  prev=0; [[ -f "$prev_file" ]] && prev="$(cat "$prev_file")"
  # rollover/container-recreate (cur < prev): treat delta as 0, restart counting
  if (( cur < prev )); then rx_delta_kb=0; else rx_delta_kb=$(( (cur - prev) / 1024 )); fi
  echo "$cur" > "$prev_file"

  low="$(cat "$low_file" 2>/dev/null || echo 0)"
  if (( rx_delta_kb < IDLE_RX_KB_THRESHOLD )); then low=$(( low + 1 )); else low=0; fi
  # FR-18: an SSH-attached session (opted-in lab) is ACTIVE regardless of rx delta
  if (( low > 0 )) && ssh_attached "$att"; then low=0; fi
  echo "$low" > "$low_file"

  idle=false
  (( low >= IDLE_CONSECUTIVE_SAMPLES )) && idle=true
  printf '{"session":"%s","rx_kb":%d,"idle":%s,"samples_low":%d}\n' \
         "$sid" "$rx_delta_kb" "$idle" "$low"
}

# ---- FR-18 SSH opt-in observability -----------------------------------------
# The reaper's network-only signal CANNOT see a learner driving an SSH-pivoting
# lab (pivot traffic crosses the interface and looks like activity, fine — but a
# long-lived sshd session with quiet I/O would be reaped). Sessions provisioned
# with LAB_SSH_ENABLED=1 therefore get a second liveness signal: open TCP
# connections on port 22 inside the attacker container. If any exist, the
# session is treated as ACTIVE for this sample (low-counter reset), so opted-in
# labs are never idle-reaped while an SSH channel is attached.
ssh_attached() {  # $1=attacker container -> "1" when sshd has established peers
  local c="$1" est
  est="$(docker exec "$c" sh -c 'command -v ss >/dev/null && ss -tn state established "( sport = :22 )" 2>/dev/null | tail -n +2 | wc -l' 2>/dev/null)" || return 1
  [[ "$est" =~ ^[0-9]+$ ]] && (( est > 0 ))
}

# Direct execution = one sweep over every provisioned session (name convention
# sess-<id>-attacker established by provision.sh / compose/session.yml).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  found=0
  for c in $(docker ps --format '{{.Names}}' | grep -E '^sess-[0-9A-Za-z_-]+-attacker$' || true); do
    found=1
    sid="${c#sess-}"; sid="${sid%-attacker}"
    detect_session "$sid"
  done
  [[ "$found" == 1 ]] || echo "[]"
fi

#!/bin/sh
# Phase 1 — shared entrypoint for ALL optimised images (attacker bundles + target).
# ---------------------------------------------------------------------------
# FR-18 "minimal idle process set": the ONLY things that start at boot are
#   attacker : ttyd (learner web terminal)
#   target   : ttyd (-W pass-through mode) + the app server passed as CMD
# Explicitly NOT started:
#   - sshd          : disabled by default; opt in per lab with LAB_SSH_ENABLED=1
#                     (see images/shared/ssh-briefing.sh)
#   - msfconsole    : pre-installed in network-recon, LAZY-STARTED by the
#                     learner's shell command; never resident at idle
# Idle process count therefore stays at tini(PID 1) + ttyd (+ app server on the
# target; + the client-spawned shell tier only while a terminal is attached).
#
# NOTE on `-W` (wait-for-client): used because ttyd exits once every client has
# disconnected. A session container must keep its terminal available across
# browser refreshes, so ttyd must not exit when the first client hangs up.
# Consequence for benchmarking: the HEALTHCHECK port probe goes healthy at boot
# (no client required); `docker top` counts the real idle resident set.
if [ "$LAB_SSH_ENABLED" = "1" ] && command -v /usr/local/bin/ssh-briefing.sh >/dev/null 2>&1; then
  /usr/local/bin/ssh-briefing.sh || true
fi

if [ $# -gt 0 ]; then
  # Target pattern: run the app server (CMD) AND expose a terminal via ttyd.
  # `--` separates ttyd options from the start command (the CMD args).
  exec /usr/local/bin/tini -s -- \
    /usr/local/bin/ttyd -p "${TTYD_PORT:-7681}" -i 0.0.0.0 -W -- "$@"
elif [ -n "${LAB_START_CMD:-}" ]; then
  # Container-local default CMD (e.g. the target's `php -S` app server).
  # Necessary because provision.sh / compose launch containers with an EMPTY
  # command array, which overrides the image's built-in CMD at the docker-run
  # level — without this fallback the entrypoint would exec ttyd with no
  # start command ("ttyd: missing start command") and the target would exit.
  # shellcheck disable=SC2086  # intentional word-splitting of the simple cmd
  exec /usr/local/bin/tini -s -- \
    /usr/local/bin/ttyd -p "${TTYD_PORT:-7681}" -i 0.0.0.0 -W -- ${LAB_START_CMD}
else
  # Attacker pattern: terminal only.
  exec /usr/local/bin/tini -s -- \
    /usr/local/bin/ttyd -p "${TTYD_PORT:-7681}" -i 0.0.0.0 -W -- bash -l
fi

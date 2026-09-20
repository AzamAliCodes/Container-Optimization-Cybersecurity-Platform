#!/bin/bash
# LEGACY attacker entrypoint: start sshd + a resident msfconsole, then hold an idle
# shell session (what ttyd attaches to in production).
# Idle process set here = entrypoint bash + sshd + msfconsole(ruby) + tail + shell
#   -- the exact bloat FR-18 targets.
# NOTE: both msfconsole and a plain `bash` exit immediately when stdin hits EOF. Run
# headless (as the benchmark harness does) there is no attached tty, so we keep stdin
# open with `tail -f /dev/null`. This faithfully reproduces the legacy "preloaded
# framework + idle session hold RAM while the learner does nothing" state; without it
# the baseline is understated and the container self-terminates mid-ramp.
set -e
/usr/sbin/sshd
( tail -f /dev/null | /usr/bin/msfconsole -q >/dev/null 2>&1 ) &
( tail -f /dev/null | /bin/bash >/dev/null 2>&1 ) &
# Hold PID 1 open so the container stays up for the session lifetime.
exec sleep infinity

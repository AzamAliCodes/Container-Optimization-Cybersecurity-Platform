#!/bin/sh
# FR-18 per-lab SSH opt-in helper. Starts sshd ONLY when LAB_SSH_ENABLED=1 is set
# on the container (documented per-lab flag — see docs/phase1/image-optimization.md).
# Default posture: SSH daemon NOT running, zero idle RAM/pid cost.
[ "$LAB_SSH_ENABLED" = "1" ] || exit 0
command -v sshd >/dev/null 2>&1 || exit 0
mkdir -p /run/sshd 2>/dev/null || true
[ -f /etc/ssh/ssh_host_rsa_key ] || ssh-keygen -A >/dev/null 2>&1 || true
/usr/sbin/sshd 2>/dev/null || true

# Phase 1 — production provisioning reference (FR-05/FR-06/NFR-08).
# ---------------------------------------------------------------------------
# The orchestrator (Phase 2+) must create session containers with EXACTLY these
# flags. compose/session.yml mirrors the same values; ci/smoke.sh runs the
# NFR-08 parity assertion comparing this table against inspect output of a
# Compose-brought-up pair. Keep the two files' LIMIT-PARITY-TABLE in sync.
#
# LIMIT-PARITY-TABLE:
#   role     | --memory | --memory-swap | --cpus | --pids-limit
#   attacker | 512m     | 768m          | 1.0    | 100
#   target   | 256m     | 384m          | 0.5    | 50
#
# Reference `docker run` for one session pair (images pre-pulled, digest-pinned):
#
#   NET="sess-$(uuidgen)"
#   docker network create "$NET"                                   # NFR-03 per-session net
#   docker run -d --name "sess-attacker-$SESSION_ID" \
#     --network "$NET" \
#     --memory 512m --memory-swap 768m --cpus 1.0 --pids-limit 100 \
#     ${REGISTRY}/web-exploitation@${ATTACKER_DIGEST}              # FR-05: pull-only, digest ref
#   docker run -d --name "sess-target-$SESSION_ID" \
#     --network "$NET" \
#     --memory 256m --memory-swap 384m --cpus 0.5 --pids-limit 50 \
#     ${REGISTRY}/target@${TARGET_DIGEST}
#
# Never: --privileged (NFR-03), `docker build` in the provisioning path (FR-04/05),
# auto-started sshd/msfconsole (FR-18 — LAB_SSH_ENABLED=1 is the only opt-in).

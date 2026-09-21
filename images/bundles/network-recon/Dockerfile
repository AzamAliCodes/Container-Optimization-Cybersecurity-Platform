# Phase 1 — ATTACKER BUNDLE: network-recon (FR-03, FR-16).
ARG KALI_BASE=kalilinux/kali-rolling@sha256:30399bd65187e06525008dd13eecc2b3439d26a82b2c6b0ba32dee72bd843117
ARG PLATFORM_BASE=platform/base:phase1

FROM ${KALI_BASE} AS tools
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      nmap metasploit-framework \
 && rm -rf /var/lib/apt/lists/* && apt-get clean

# Stage the tool payload into /payload inside the Kali lineage. Upstream
# packaging drifts (e.g. ncat/nping no longer ship as separate binaries in
# current Kali nmap), so we resolve paths with command -v / find HERE
# (tolerant) instead of via brittle file-level COPY --from=tools directives.
RUN set -eu; \
    mkdir -p /payload/usr/bin /payload/usr/sbin /payload/usr/lib \
             /payload/usr/share; \
    for b in nmap msfconsole msfvenom msfdb; do \
      src="$(command -v "$b" || true)"; \
      if [ -z "$src" ]; then \
        echo "[bundle] ERROR: required binary '$b' not found in tools stage" >&2; \
        exit 1; \
      fi; \
      case "$src" in \
        /sbin/*|/usr/sbin/*) cp -a "$src" "/payload/usr/sbin/$b" ;; \
        *)                   cp -a "$src" "/payload/usr/bin/$b" ;; \
      esac; \
    done; \
    for b in ncat nping ndiff zenmap; do \
      src="$(command -v "$b" || true)"; \
      [ -n "$src" ] && cp -a "$src" "/payload/usr/bin/$b" || true; \
    done; \
    for f in /usr/bin/msf*; do \
      [ -e "$f" ] && cp -a "$f" /payload/usr/bin/ || true; \
    done; \
    for d in nmap metasploit-framework; do \
      [ -d "/usr/share/$d" ] && cp -a "/usr/share/$d" "/payload/usr/share/$d" || true; \
    done; \
    [ -d /usr/lib/nmap ] && cp -a /usr/lib/nmap /payload/usr/lib/nmap || true; \
    [ -x /payload/usr/bin/msfconsole ] || [ -x /payload/usr/sbin/msfconsole ]; \
    echo "[bundle] staged network-recon payload (ncat present: $( [ -e /payload/usr/bin/ncat ] && echo yes || echo no ))"

FROM ${PLATFORM_BASE}
USER root

# --- tool payload from the throwaway Kali stage (single tolerant COPY) ------
COPY --from=tools /payload/ /

# Shared libraries the copied binaries link against:
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libpcap0.8 liblua5.4-0 libssh2-1 libssl3 zlib1g libpcre2-8-0 \
      ruby python3 postgresql \
 && rm -rf /var/lib/apt/lists/* && apt-get clean

COPY images/shared/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY images/shared/ssh-briefing.sh /usr/local/bin/ssh-briefing.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/ssh-briefing.sh

HEALTHCHECK --interval=2s --timeout=2s --start-period=3s --retries=20 \
  CMD nc -z 127.0.0.1 "${TTYD_PORT:-7681}" || exit 1

USER lab
WORKDIR /home/lab
EXPOSE 7681
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
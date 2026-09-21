# Phase 1 — ATTACKER BUNDLE: password-attacks (FR-03, FR-16).
# ---------------------------------------------------------------------------
# Credential-attack labs need exactly: hydra, john, hashcat + curated wordlists.
# Lightest bundle — no frameworks. Same throwaway-Kali-stage extraction pattern.
ARG KALI_BASE=kalilinux/kali-rolling@sha256:30399bd65187e06525008dd13eecc2b3439d26a82b2c6b0ba32dee72bd843117
ARG PLATFORM_BASE=platform/base:phase1

FROM ${KALI_BASE} AS tools
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      hydra john hashcat seclists \
 && rm -rf /var/lib/apt/lists/* && apt-get clean

# Stage the tool payload + curated wordlists into /payload inside the Kali
# lineage. Upstream seclists renames/moves individual files over time, so we
# resolve paths with globs HERE (tolerant) instead of via brittle file-level
# COPY --from=tools directives that hard-fail the whole build when one
# filename drifts.
RUN set -eu; \
    mkdir -p /payload/usr/bin /payload/usr/sbin /payload/usr/lib \
             /payload/usr/share/wordlists; \
    # --- binaries ---------------------------------------------------------
    for b in hydra hashcat; do \
      src="$(command -v "$b")"; \
      cp -a "$src" "/payload/usr/bin/$b"; \
    done; \
    jsrc="$(command -v john || true)"; \
    if [ -n "$jsrc" ]; then \
      case "$jsrc" in \
        /sbin/*|/usr/sbin/*) cp -a "$jsrc" "/payload/usr/sbin/john" ;; \
        *)                   cp -a "$jsrc" "/payload/usr/bin/john" ;; \
      esac; \
    else \
      echo "[bundle] ERROR: john binary not found in tools stage" >&2; exit 1; \
    fi; \
    # --- tool data directories (optional per upstream packaging) ----------
    for d in hydra john hashcat; do \
      [ -d "/usr/share/$d" ] && cp -a "/usr/share/$d" "/payload/usr/share/$d" || true; \
    done; \
    [ -d /usr/lib/hydra ] && cp -a /usr/lib/hydra /payload/usr/lib/hydra || true; \
    # --- curated lists ONLY (legacy shipped the ~1.5 GB `wordlists` meta) --
    found=0; \
    for pat in \
      '/usr/share/seclists/Passwords/Common-Credentials/10k-top-worst-passwords*' \
      '/usr/share/seclists/Passwords/Common-Credentials/best1050*' \
      '/usr/share/seclists/Usernames/top-usernames-shortlist*'; do \
      for f in $pat; do \
        [ -e "$f" ] || continue; \
        cp -n "$f" /payload/usr/share/wordlists/ && found=$((found+1)); \
      done; \
    done; \
    if [ "$found" -eq 0 ]; then \
      echo "[bundle] ERROR: no curated wordlists matched in seclists:" >&2; \
      ls -la /usr/share/seclists/Passwords/Common-Credentials/ 2>/dev/null | head -20 >&2; \
      exit 1; \
    fi; \
    echo "[bundle] staged $found curated wordlist(s) from seclists"

FROM ${PLATFORM_BASE}
USER root

# --- tool payload from the throwaway Kali stage (single tolerant COPY) ------
COPY --from=tools /payload/ /

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libpcre2-8-0 libssl3 zlib1g libgomp1 libsqlite3-0 libpcap0.8 \
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

# Phase 1 — OPTIMISED TARGET (FR-01, FR-02, FR-16, FR-18).
# ---------------------------------------------------------------------------
# Replaces legacy-images/target (full debian:bookworm + build-essential + vim
# baked, apt caches in layers, root, no healthcheck). Same vulnerable app
# (SQLi demo) served by PHP's built-in server — apache2+mod_php replaced by a
# single `php -S` process (fewer resident procs → FR-18 idle-count KPI).
# Derives from platform/base → shares ALL base layers with every attacker
# bundle via OverlayFS (FR-16 marginal-disk KPI).
ARG PLATFORM_BASE=platform/base:phase1
FROM ${PLATFORM_BASE}

USER root

# php-cli + sqlite ext only; lists removed in the same RUN (FR-01 hygiene).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      php-cli php-sqlite3 php-xml \
 && rm -rf /var/lib/apt/lists/* && apt-get clean

COPY legacy-images/target/src/index.php /var/www/html/index.php
COPY legacy-images/target/src/setup.sql /opt/setup.sql
RUN mkdir -p /var/www/html/data && chown -R lab:lab /var/www/html /opt/setup.sql

COPY images/shared/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY images/shared/ssh-briefing.sh /usr/local/bin/ssh-briefing.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/ssh-briefing.sh

# Create a simple startup script for the target to avoid quoting issues
RUN echo '#!/bin/sh' > /usr/local/bin/start-target.sh && \
    echo 'php -r '"'"'$pdo=new PDO("sqlite:/var/www/html/data/app.db");$pdo->exec(file_get_contents("/opt/setup.sql"));'"'"'' >> /usr/local/bin/start-target.sh && \
    echo 'exec php -S 0.0.0.0:8080 -t /var/www/html' >> /usr/local/bin/start-target.sh && \
    chmod +x /usr/local/bin/start-target.sh

# Create target-specific entrypoint that starts PHP server immediately
RUN echo '#!/bin/sh' > /usr/local/bin/entrypoint-target.sh && \
    echo 'if [ "$LAB_SSH_ENABLED" = "1" ] && command -v /usr/local/bin/ssh-briefing.sh >/dev/null 2>&1; then' >> /usr/local/bin/entrypoint-target.sh && \
    echo '  /usr/local/bin/ssh-briefing.sh || true' >> /usr/local/bin/entrypoint-target.sh && \
    echo 'fi' >> /usr/local/bin/entrypoint-target.sh && \
    echo '' >> /usr/local/bin/entrypoint-target.sh && \
    echo '# Start the PHP server in background' >> /usr/local/bin/entrypoint-target.sh && \
    echo '/usr/local/bin/start-target.sh &' >> /usr/local/bin/entrypoint-target.sh && \
    echo '' >> /usr/local/bin/entrypoint-target.sh && \
    echo '# Start ttyd for terminal access (without -W so it doesn'\''t wait for client)' >> /usr/local/bin/entrypoint-target.sh && \
    echo 'exec /usr/local/bin/tini -s -- /usr/local/bin/ttyd -p "${TTYD_PORT:-7681}" -i 0.0.0.0 -- bash -l' >> /usr/local/bin/entrypoint-target.sh && \
    chmod +x /usr/local/bin/entrypoint-target.sh

# FR-07 healthcheck: target is "ready" when the app port answers TCP connect.
HEALTHCHECK --interval=2s --timeout=2s --start-period=3s --retries=20 \
  CMD nc -z 127.0.0.1 "${TARGET_PORT:-8080}" || exit 1

ENV TTYD_PORT=7681 TARGET_PORT=8080
# NFR-03: non-root. Bind>1024 so `lab` can serve without CAP_NET_BIND_SERVICE.
USER lab
WORKDIR /home/lab
EXPOSE 7681 8080
ENTRYPOINT ["/usr/local/bin/entrypoint-target.sh"]

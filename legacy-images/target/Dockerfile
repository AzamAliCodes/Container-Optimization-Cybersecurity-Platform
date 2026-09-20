# LEGACY / CURRENT-STATE REPRODUCTION -- target image (Phase 0 baseline).
# Current-state target bloat patterns reproduced:
#   - FROM debian:bookworm (full, unpinned -- not even slim)           [FR-02]
#   - Single stage, apt cache + index lists BAKED in                    [FR-01]
#   - Heavy single-stage install: apache2 + mod_php + default-mysql-client (+ retained
#     build-essential as representative of a baked build toolchain) + vim [FR-01]
#   - runs as root, no USER                                             [NFR-03]
#   - NO HEALTHCHECK                                                    [FR-07]
#   - no resource limits at runtime                                     [FR-06]
# Build: docker build -f legacy-images/target/Dockerfile -t platform/target:legacy .

FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      apache2 \
      php \
      libapache2-mod-php \
      php-sqlite3 \
      default-mysql-client \
      build-essential \
      vim \
 && mkdir -p /var/www/html/data

COPY legacy-images/target/src/ /var/www/html/
COPY legacy-images/target/src/setup.sql /opt/setup.sql

EXPOSE 80

COPY legacy-images/target/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]

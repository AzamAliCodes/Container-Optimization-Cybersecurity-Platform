# Phase 1 — SHARED BASE LAYER (FR-16, FR-02).
# ---------------------------------------------------------------------------
# Every optimised image (attacker bundles AND the target) derives from this one
# stage so concurrent sessions share these layers via OverlayFS copy-on-write.
# That is what makes the ≤50 MB marginal-disk-per-session KPI (§5 / FR-16) possible:
# the second..Nth session on a host adds only its bundle-specific layers + writable layer.
#
# Build hygiene vs legacy (FR-01): apt lists + cache are removed in the SAME RUN
# that installs packages, so nothing build-only bakes into the final layer.
#
# Digest pinning (FR-02): the PRD requires bases pinned by digest, not `latest`.
# The canonical pin lives in images/digests.env and is consumed by images/build.sh,
# which passes this Dockerfile's FROM as a build ARG (`BASE_DEBIAN`). Keep the ARG
# default == the value in digests.env for direct `docker build` use.
# ---------------------------------------------------------------------------
ARG BASE_DEBIAN=debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

# Multi-arch support (amd64 + arm64): build.sh passes --platform=$BUILDPLATFORM
# so this fetcher stage runs NATIVELY on the build host (Apple Silicon /
# Graviton included — no emulation), and BuildKit exposes TARGETARCH = the arch
# of the image being produced. The binary asset + checksum are selected per
# TARGETARCH below. Anything other than amd64/arm64 fails fast instead of
# silently baking a wrong-arch ELF into the image.
FROM --platform=$BUILDPLATFORM ${BASE_DEBIAN} AS dl

# Build-time-only fetcher for pinned, checksum-verified static binaries.
# This stage NEVER appears in the final image (FR-01 multi-stage hygiene).
ARG TARGETARCH
ARG TTYD_VERSION=1.7.7
ARG TTYD_SHA256_AMD64=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
ARG TTYD_SHA256_ARM64=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165
ARG TINI_VERSION=0.19.0
ARG TINI_SHA256_AMD64=93dcc18adc78c65a028a84799ecf8ad40c936fdfc5f2a57b1acda5a8117fa82c
ARG TINI_SHA256_ARM64=07952557df20bfd2a95f9bef198b445e006171969499a1d361bd9e6f8e5e0e81
RUN set -eu; \
    case "${TARGETARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}" in \
      amd64|x86_64)  TA=amd64; TTYD_ASSET=ttyd.x86_64;   TINI_ASSET=tini-amd64; \
                     TTYD_SUM="$TTYD_SHA256_AMD64"; TINI_SUM="$TINI_SHA256_AMD64";; \
      arm64|aarch64) TA=arm64; TTYD_ASSET=ttyd.aarch64;  TINI_ASSET=tini-arm64; \
                     TTYD_SUM="$TTYD_SHA256_ARM64"; TINI_SUM="$TINI_SHA256_ARM64";; \
      *) echo "FATAL: unsupported TARGETARCH '$TARGETARCH' (want amd64 or arm64)" >&2; exit 1;; \
    esac; \
    echo "[dl] fetching ttyd/${TTYD_ASSET} + tini/${TINI_ASSET} for arch=$TA"; \
    i=0; until apt-get update; do i=$((i+1)); [ $i -ge 3 ] && exit 1; sleep 5; done; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    rm -rf /var/lib/apt/lists/*; \
    fetch() { j=0; until curl -fsSL --retry 2 -o "$2" "$1"; do j=$((j+1)); [ $j -ge 3 ] && return 1; sleep 5; done; }; \
    fetch "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${TTYD_ASSET}" /ttyd; \
    fetch "https://github.com/krallin/tini/releases/download/v${TINI_VERSION}/${TINI_ASSET}" /tini; \
    echo "${TTYD_SUM}  /ttyd" | sha256sum -c -; \
    echo "${TINI_SUM}  /tini" | sha256sum -c -; \
    chmod +x /ttyd /tini

FROM ${BASE_DEBIAN}

ENV DEBIAN_FRONTEND=noninteractive

# Minimal shared runtime tier: apt lists removed in the SAME RUN that installs
# packages (FR-01 build hygiene). ttyd replaces the legacy "compiled from source"
# pattern with a pinned, checksum-verified STATIC release binary copied out of
# the `dl` stage — no compiler, no libwebsockets/libevent stack, no source tree,
# and no downloader tooling in the final image layers.
#   ttyd : learner web terminal, the ONLY auto-started service (FR-18)
#   tini : PID 1 (signal forwarding + zombie reaping, keeps idle proc count low)
#   nc   : netcat for the HEALTHCHECK probes (FR-07)
COPY --from=dl /ttyd /usr/local/bin/ttyd
COPY --from=dl /tini /usr/local/bin/tini

RUN set -eu; \
    i=0; until apt-get update; do i=$((i+1)); [ $i -ge 3 ] && exit 1; sleep 5; done; \
    apt-get install -y --no-install-recommends ca-certificates iproute2 netcat-openbsd; \
    rm -rf /var/lib/apt/lists/*; \
    apt-get clean

# Shared non-root account (NFR-03). Bundles/target add their own users if needed.
RUN useradd --create-home --shell /bin/bash lab

# FR-18 per-lab SSH opt-in prerequisites: openssh-server is present so a lab
# that declares `ssh_enabled: true` can start sshd via LAB_SSH_ENABLED=1 — but
# the daemon NEVER auto-starts (entrypoint gate) and its cost is ~2 MiB of
# inert files, negligible against the ≤3-idle-process KPI (sshd only counts
# once a lab opts in; default posture has no sshd process at all).
RUN set -eu; \
    i=0; until apt-get update; do i=$((i+1)); [ $i -ge 3 ] && exit 1; sleep 5; done; \
    apt-get install -y --no-install-recommends openssh-server; \
    rm -rf /var/lib/apt/lists/*; \
    apt-get clean

WORKDIR /home/lab

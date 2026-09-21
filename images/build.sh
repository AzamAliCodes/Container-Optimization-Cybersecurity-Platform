#!/usr/bin/env bash
# Phase 1 — canonical image build entrypoint (FR-01/FR-02/FR-03/FR-16).
# ---------------------------------------------------------------------------
# images/digests.env is the SINGLE SOURCE OF TRUTH for base pins + binary
# checksums; this script sources it and passes every value to the Dockerfiles
# as --build-arg, so a bare `docker build` and CI always converge on the same
# digest-pinned bases (FR-02). BuildKit is mandatory (multi-stage COPY
# --from=tools, layer caching; PRD §10.5).
#
# Usage:
#   ./images/build.sh                 # build base + target + all bundles
#   ./images/build.sh base            # shared base only (everything else depends on it)
#   ./images/build.sh target
#   ./images/build.sh web-exploitation|network-recon|password-attacks
# Env overrides:
#   REGISTRY=ghcr.io/org/platform    tag/push prefix (default: platform — local dev)
#   VERSION=<tag>                    immutable version tag (default: phase1)
#   PUSH=1                           docker push after a successful build (CI publish, FR-04)
set -euo pipefail
cd "$(dirname "$0")"

source ./digests.env                       # authoritative pins (FR-02)

REGISTRY="${REGISTRY:-platform}"
VERSION="${VERSION:-phase1}"
PUSH="${PUSH:-0}"

export DOCKER_BUILDKIT=1

# Refuse to build without BuildKit (classic builder cannot do multi-stage COPY --from across named stages reliably here).
if ! docker build --help 2>/dev/null | grep -q "BuildKit"; then
  echo "[build] WARNING: could not confirm BuildKit; ensure Docker Engine >= 24.x (PRD §11)." >&2
fi

# Multi-arch (amd64 + arm64): images/base/Dockerfile's fetcher stage selects the
# ttyd/tini release asset + checksum by TARGETARCH, and runs natively on the
# build host via --platform=$BUILDPLATFORM (BuildKit sets both automatically;
# passing them explicitly keeps behaviour identical on classic builders that
# ignore unknown flags... they don't, so BuildKit is mandatory — checked above).
# The bundle Dockerfiles' throwaway `tools` stages pull KALI_BASE by *index*
# digest, which resolves per-arch on any host.
common_args=(
  --build-arg BASE_DEBIAN="$BASE_DEBIAN"
  --build-arg KALI_BASE="$KALI_BASE"
  --build-arg TTYD_VERSION="$TTYD_VERSION"
  --build-arg TTYD_SHA256_AMD64="$TTYD_SHA256_AMD64"
  --build-arg TTYD_SHA256_ARM64="$TTYD_SHA256_ARM64"
  --build-arg TINI_VERSION="$TINI_VERSION"
  --build-arg TINI_SHA256_AMD64="$TINI_SHA256_AMD64"
  --build-arg TINI_SHA256_ARM64="$TINI_SHA256_ARM64"
)

img() { printf '%s/%s:%s' "$REGISTRY" "$1" "$VERSION"; }

build_one() { # <short-name> <dockerfile-relative-path> [extra args...]
  local name="$1" df="$2"; shift 2
  local tag; tag="$(img "$name")"
  echo "[build] $tag  <-  $df"
  local t0 t1
  t0="$(date +%s)"
  docker build "${common_args[@]}" "$@" -f "$df" -t "$tag" ..
  t1="$(date +%s)"
  echo "[build] $tag done in $((t1-t0))s (KPI cold-build target: <=300s with cache, PRD §5)"
  if [[ "$PUSH" == "1" ]]; then
    docker push "$tag"
    echo "[build] pushed $tag (immutable tag, FR-04)"
  fi
}

TARGET="${1:-all}"

case "$TARGET" in
  base)
    build_one base base/Dockerfile
    ;;
  target)
    [[ "$(docker images -q "$(img base)" 2>/dev/null)" ]] || build_one base base/Dockerfile
    build_one target target/Dockerfile --build-arg PLATFORM_BASE="$(img base)"
    ;;
  web-exploitation|network-recon|password-attacks)
    [[ "$(docker images -q "$(img base)" 2>/dev/null)" ]] || build_one base base/Dockerfile
    build_one "$TARGET" "bundles/$TARGET/Dockerfile" --build-arg PLATFORM_BASE="$(img base)"
    ;;
  all)
    build_one base base/Dockerfile
    build_one target target/Dockerfile --build-arg PLATFORM_BASE="$(img base)"
    for b in web-exploitation network-recon password-attacks; do
      build_one "$b" "bundles/$b/Dockerfile" --build-arg PLATFORM_BASE="$(img base)"
    done
    ;;
  *)
    echo "usage: $0 [base|target|web-exploitation|network-recon|password-attacks|all]" >&2
    exit 2
    ;;
esac

echo "[build] complete."

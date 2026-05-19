#!/usr/bin/env bash
# =============================================================================
# scripts/kind-load-image.sh — build (optional) + load image into Kind nodes
# =============================================================================
# Two modes:
#   1. Build mode: --build <dockerfile-dir> <tag> — builds and loads.
#   2. Pull-then-load: just <tag> — loads an existing local image.
#
# Without this step pods reference the image but Kind workers can't see it,
# resulting in `ErrImagePull` despite the image existing on the host.
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  cat <<EOF
Usage:
  $0 <tag>                          Load an existing local image into Kind.
  $0 --build <dir> <tag>            Build from <dir> with -t <tag>, then load.

Examples:
  $0 ngolacloud/portal:0.1.0
  $0 --build ./ngolacloud-portal ngolacloud/portal:dev

Flags:
  --help                            Show this help.
EOF
}

[ $# -lt 1 ] && { usage; exit 2; }

BUILD=0
BUILD_DIR=""
TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --build)  BUILD=1; BUILD_DIR="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *)         TAG="$1"; shift ;;
  esac
done

[ -z "$TAG" ] && { log_error "tag required"; usage; exit 2; }
ensure_bin kind
ensure_bin docker

if [ "$BUILD" -eq 1 ]; then
  [ -d "$BUILD_DIR" ] || { log_error "build dir not found: $BUILD_DIR"; exit 2; }
  log_info "docker build -t $TAG $BUILD_DIR"
  docker build -t "$TAG" "$BUILD_DIR"
fi

# Sanity: the image must exist locally before we try to load.
if ! docker image inspect "$TAG" >/dev/null 2>&1; then
  log_error "image $TAG not found locally — pull or --build first"
  exit 2
fi

log_info "kind load docker-image $TAG → $KIND_CLUSTER"
kind load docker-image "$TAG" --name "$KIND_CLUSTER"
log_ok "loaded $TAG into cluster $KIND_CLUSTER"

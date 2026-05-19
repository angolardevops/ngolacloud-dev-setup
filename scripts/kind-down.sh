#!/usr/bin/env bash
# =============================================================================
# scripts/kind-down.sh — destroy the ngolacloud-dev Kind cluster
# =============================================================================
# After kind-delete-cluster, also garbage-collect Docker (exited containers,
# dangling images, unused networks) so re-runs don't leak resources. Does
# NOT touch volumes (see --prune-volumes flag).
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  cat <<EOF
Usage: $0 [--prune-volumes] [--keep-other-clusters]
  --prune-volumes        Also delete unattached Docker volumes (DATA LOSS).
  --keep-other-clusters  Don't touch other kind clusters (default: only ngolacloud-dev is deleted).
  --help                 Show this help.
EOF
}

PRUNE_VOLS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prune-volumes) PRUNE_VOLS=1; shift ;;
    --help|-h)       usage; exit 0 ;;
    --keep-other-clusters) shift ;;  # accepted for symmetry
    *) log_error "unknown flag: $1"; usage; exit 2 ;;
  esac
done

ensure_bin kind
ensure_bin docker

if ! kind get clusters 2>/dev/null | grep -qw "$KIND_CLUSTER"; then
  log_warn "cluster $KIND_CLUSTER does not exist — nothing to delete"
else
  log_info "deleting cluster $KIND_CLUSTER"
  kind delete cluster --name "$KIND_CLUSTER"
  log_ok "cluster deleted"
fi

log_info "docker container prune"
docker container prune -f >/dev/null

log_info "docker image prune (dangling only)"
docker image prune -f >/dev/null

log_info "docker network prune"
docker network prune -f >/dev/null

log_info "docker builder prune"
docker builder prune -f >/dev/null

if [ "$PRUNE_VOLS" -eq 1 ]; then
  log_warn "docker volume prune — DELETING UNATTACHED VOLUMES"
  docker volume prune -f >/dev/null
fi

log_ok "kind-down complete"
df -h / | tail -1

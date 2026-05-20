#!/usr/bin/env bash
# =============================================================================
# scripts/flux-install.sh — Flux v2 install + sample GitRepository
# =============================================================================
# Bootstraps Flux on the Kind cluster WITHOUT requiring a GitHub repo (the
# default `flux bootstrap github` command demands a token + creates a real
# repo). Two install modes:
#
#   --bare        Just install the Flux controllers — no reconciliation
#                 targets. You apply GitRepository + Kustomization manifests
#                 yourself later.
#
#   --sample      Install + create a sample GitRepository pointing at this
#                 very repo (./k8s/flux/sample/) so you see Flux working
#                 end-to-end without leaving the laptop.
#
# Idempotent. Re-run safely.
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

FLUX_VERSION="${FLUX_VERSION:-2.4.0}"
MODE=""

usage() {
  cat <<EOF
Usage: $0 [--bare | --sample] [--uninstall]
  --bare       Install Flux controllers only (default)
  --sample     Install + create sample GitRepository + Kustomization
  --uninstall  Remove Flux entirely
  --help       Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bare)      MODE="bare"; shift ;;
    --sample)    MODE="sample"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    --help|-h)   usage; exit 0 ;;
    *) log_error "unknown flag: $1"; usage; exit 2 ;;
  esac
done
MODE="${MODE:-bare}"

ensure_bin kubectl

# Pull the flux CLI on demand — not in the kind_tools role because most
# users won't enable GitOps.
install_flux_cli() {
  if ! command -v flux >/dev/null; then
    log_info "downloading flux CLI v$FLUX_VERSION"
    local tarball="/tmp/flux-${FLUX_VERSION}.tar.gz"
    curl -fsSL -o "$tarball" \
      "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_amd64.tar.gz"
    sudo tar -xzf "$tarball" -C /usr/local/bin/ flux
    rm -f "$tarball"
  fi
}

case "$MODE" in
  bare|sample)
    install_flux_cli
    log_info "flux check --pre"
    flux check --pre

    log_info "flux install (controllers only, no bootstrap)"
    flux install \
      --components=source-controller,kustomize-controller,helm-controller,notification-controller \
      --network-policy=false   # Cilium policies cover this in dev
    wait_for "Flux pods Running" 90 \
      "kubectl -n flux-system get pods --no-headers 2>/dev/null | grep -c Running" \
      "4"
    log_ok "Flux controllers ready"

    if [ "$MODE" = "sample" ]; then
      log_info "applying sample GitRepository + Kustomization"
      kubectl apply -f "$REPO_ROOT/k8s/flux/sample-gitrepository.yaml"
      kubectl apply -f "$REPO_ROOT/k8s/flux/sample-kustomization.yaml"
      log_ok "sample sources applied — flux get sources git -A"
    fi
    ;;

  uninstall)
    log_warn "removing Flux"
    flux uninstall --silent || true
    kubectl delete ns flux-system --ignore-not-found
    log_ok "Flux removed"
    ;;
esac

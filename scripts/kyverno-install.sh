#!/usr/bin/env bash
# =============================================================================
# scripts/kyverno-install.sh — Helm install Kyverno + apply baseline policies
# =============================================================================
# Idempotent. Safe to run against an existing cluster with policies already
# applied (helm upgrade + kubectl apply).
#
# By default installs in Audit mode (policies report violations to events
# but admit the pod). Flip to Enforce manually once the cluster is clean::
#
#     kubectl get cpol -o name | xargs -I{} kubectl patch {} \
#       --type='json' -p='[{"op":"replace","path":"/spec/validationFailureAction","value":"Enforce"}]'
#
# Usage:
#   scripts/kyverno-install.sh                    # install + apply policies
#   scripts/kyverno-install.sh --enforce          # flip all to Enforce
#   scripts/kyverno-install.sh --uninstall        # remove Kyverno + policies
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

KYVERNO_VERSION="${KYVERNO_VERSION:-3.3.7}"
POLICIES_DIR="$REPO_ROOT/k8s/policies/kyverno"

usage() {
  cat <<EOF
Usage: $0 [--enforce | --uninstall]
  --enforce     Patch all policies from Audit → Enforce
  --uninstall   Remove Kyverno + policies
  --help        Show this help
EOF
}

MODE="install"
while [ $# -gt 0 ]; do
  case "$1" in
    --enforce)   MODE="enforce"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    --help|-h)   usage; exit 0 ;;
    *) log_error "unknown flag: $1"; usage; exit 2 ;;
  esac
done

ensure_bin helm
ensure_bin kubectl

case "$MODE" in
  install)
    log_info "helm install kyverno v$KYVERNO_VERSION"
    helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
    helm repo update kyverno >/dev/null
    helm upgrade --install kyverno kyverno/kyverno \
      --namespace kyverno --create-namespace \
      --version "$KYVERNO_VERSION" \
      --set admissionController.replicas=1 \
      --set backgroundController.replicas=1 \
      --set cleanupController.replicas=1 \
      --set reportsController.replicas=1 \
      --wait --timeout 5m

    log_info "kubectl apply policies/"
    kubectl apply -f "$POLICIES_DIR/"

    log_info "waiting for policies to become Ready"
    wait_for "ClusterPolicies Ready" 60 \
      "kubectl get cpol --no-headers 2>/dev/null | awk '\$5==\"True\"{n++} END{print n+0}'" \
      "$(ls "$POLICIES_DIR"/*.yaml | wc -l)"

    log_ok "Kyverno installed in Audit mode — $(ls "$POLICIES_DIR"/*.yaml | wc -l) policies active"
    log_info "View violations: kubectl get policyreports -A"
    log_info "Promote to Enforce: $0 --enforce"
    ;;

  enforce)
    log_warn "flipping all ClusterPolicies to Enforce mode"
    for cpol in $(kubectl get cpol -o name); do
      kubectl patch "$cpol" --type='json' \
        -p='[{"op":"replace","path":"/spec/validationFailureAction","value":"Enforce"}]'
    done
    log_ok "all policies now in Enforce mode"
    ;;

  uninstall)
    log_warn "removing Kyverno + policies"
    kubectl delete -f "$POLICIES_DIR/" --ignore-not-found
    helm uninstall kyverno -n kyverno --wait
    kubectl delete ns kyverno --ignore-not-found
    log_ok "Kyverno uninstalled"
    ;;
esac

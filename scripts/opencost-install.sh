#!/usr/bin/env bash
# =============================================================================
# scripts/opencost-install.sh — opencost on the dev cluster
# =============================================================================
# Pre-condition: observability stack already installed (kube-prom-stack
# in the `observability` namespace). opencost queries that Prometheus.
#
# Usage:
#   scripts/opencost-install.sh             # install
#   scripts/opencost-install.sh --report    # print allocation summary
#   scripts/opencost-install.sh --ui        # port-forward UI to localhost:9090
#   scripts/opencost-install.sh --uninstall # remove
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  cat <<EOF
Usage: $0 [--report | --ui | --uninstall]
  (no flag)    helm install opencost
  --report     hit the API for an allocation summary (last 24h)
  --ui         port-forward the UI to http://localhost:9090
  --uninstall  remove opencost
EOF
}

ensure_bin kubectl
ensure_bin helm

case "${1:-install}" in
  install|"")
    # Prereq: Prometheus reachable
    if ! kubectl -n observability get svc kube-prom-kube-prome-prometheus >/dev/null 2>&1; then
      log_error "Prometheus not found in observability ns — run 'make kind-up WITH_OBS=1' first"
      exit 2
    fi

    log_info "helm install opencost"
    helm repo add opencost https://opencost.github.io/opencost-helm-chart >/dev/null 2>&1 || true
    helm repo update opencost >/dev/null
    helm upgrade --install opencost opencost/opencost \
      --namespace opencost --create-namespace \
      --values "$REPO_ROOT/k8s/security/opencost-values.yaml" \
      --wait --timeout 5m
    wait_for "opencost Running" 60 \
      "kubectl -n opencost get pods --no-headers 2>/dev/null | grep -c Running" "1"
    log_ok "opencost installed"
    log_info "UI:    $0 --ui        (then http://localhost:9090)"
    log_info "API:   $0 --report"
    ;;

  --report)
    log_info "fetching allocation summary (last 24h)"
    # Port-forward in background, hit API, kill the forward
    kubectl -n opencost port-forward svc/opencost 9003:9003 >/dev/null 2>&1 &
    PF_PID=$!
    trap 'kill $PF_PID 2>/dev/null || true' EXIT
    sleep 2

    if ! command -v jq >/dev/null; then
      log_warn "jq missing — raw JSON dump follows"
      curl -s "http://localhost:9003/allocation?window=24h&aggregate=namespace"
    else
      curl -s "http://localhost:9003/allocation?window=24h&aggregate=namespace" \
        | jq -r '
          "Namespace\t\tCPU/h\tMemory/h\tStorage/h\tTotal/day",
          "─────────\t\t─────\t────────\t─────────\t─────────",
          (.data[0] | to_entries[] | select(.key != "__idle__") |
            "\(.key)\t\t\(.value.cpuCost | tonumber * 24 | floor)\t\(.value.ramCost | tonumber * 24 | floor)\t\(.value.pvCost | tonumber * 24 | floor)\t\(.value.totalCost | tonumber * 24 | floor) AOA")
        '
    fi
    ;;

  --ui)
    log_info "opening http://localhost:9090 — Ctrl+C to stop"
    kubectl -n opencost port-forward svc/opencost 9090:9090
    ;;

  --uninstall)
    log_warn "removing opencost"
    helm uninstall opencost -n opencost 2>/dev/null || true
    kubectl delete ns opencost --ignore-not-found
    log_ok "opencost removed"
    ;;

  --help|-h) usage ;;
  *) log_error "unknown flag: $1"; usage; exit 2 ;;
esac

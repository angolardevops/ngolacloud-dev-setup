#!/usr/bin/env bash
# =============================================================================
# scripts/falco-install.sh — Falco install + sample malicious event
# =============================================================================
# Falco is the runtime-detection arm of the security stack: Trivy catches
# vulnerable images, Kyverno catches non-compliant configs at admission,
# and Falco catches things going wrong *while pods are running* (shell
# spawn, file writes, network anomalies).
#
# Usage:
#   scripts/falco-install.sh                # helm install + wait
#   scripts/falco-install.sh --test         # spawn a netcat listener to
#                                             trigger the custom rule
#   scripts/falco-install.sh --tail         # stream alerts (stdout sink)
#   scripts/falco-install.sh --uninstall    # cleanup
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

FALCO_VERSION="${FALCO_VERSION:-4.16.0}"

usage() {
  cat <<EOF
Usage: $0 [--test | --tail | --uninstall]
  (no flag)    Install Falco + falcosidekick
  --test       Spawn a netcat listener pod to trigger the custom rule
  --tail       Tail Falco alerts from the daemonset stdout
  --uninstall  Remove Falco
EOF
}

ensure_bin kubectl
ensure_bin helm

case "${1:-install}" in
  install|"")
    log_info "helm install falco v$FALCO_VERSION"
    helm repo add falcosecurity https://falcosecurity.github.io/charts >/dev/null 2>&1 || true
    helm repo update falcosecurity >/dev/null
    helm upgrade --install falco falcosecurity/falco \
      --namespace falco --create-namespace \
      --version "$FALCO_VERSION" \
      --values "$REPO_ROOT/k8s/security/falco-values.yaml" \
      --wait --timeout 5m
    wait_for "Falco pods Running" 90 \
      "kubectl -n falco get pods -l app.kubernetes.io/name=falco --no-headers 2>/dev/null | grep -c Running" \
      "4"
    log_ok "Falco installed (one DaemonSet pod per node)"
    log_info "Tail alerts: $0 --tail"
    log_info "Trigger test: $0 --test"
    ;;

  --test)
    log_info "spawning netcat listener pod to trigger 'Suspicious netcat listener' rule"
    kubectl run falco-test-nc \
      --image=alpine \
      --restart=Never \
      --rm -i --tty=false \
      --overrides='{"spec":{"containers":[{"name":"falco-test-nc","image":"alpine","command":["sh","-c","apk add --no-cache netcat-openbsd && nc -lvp 4444"]}]}}' \
      &>/dev/null &
    NCPID=$!
    sleep 8
    log_info "checking Falco alerts (last 20s)…"
    kubectl -n falco logs -l app.kubernetes.io/name=falco --since=20s --tail=50 \
      | grep -iE "netcat|suspicious|warning|critical" || log_warn "no matching alerts yet — give it a few more seconds"
    log_info "cleaning up test pod"
    kubectl delete pod falco-test-nc --ignore-not-found --wait=false >/dev/null 2>&1
    kill $NCPID 2>/dev/null || true
    ;;

  --tail)
    log_info "tailing Falco alerts (Ctrl+C to stop)"
    kubectl -n falco logs -f -l app.kubernetes.io/name=falco --tail=10
    ;;

  --uninstall)
    log_warn "removing Falco"
    helm uninstall falco -n falco 2>/dev/null || true
    kubectl delete ns falco --ignore-not-found
    log_ok "Falco removed"
    ;;

  --help|-h)
    usage ;;

  *)
    log_error "unknown flag: $1"; usage; exit 2 ;;
esac

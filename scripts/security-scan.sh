#!/usr/bin/env bash
# =============================================================================
# scripts/security-scan.sh — install + run the security stack
# =============================================================================
# One entry point for the four security checkers:
#
#   trivy        Trivy Operator — continuous CVE + config audit scans
#   bench        kube-bench Job — CIS Kubernetes Benchmark on demand
#   report       Aggregate all VulnerabilityReports + ConfigAuditReports
#                + kube-bench output into a single summary
#   uninstall    Remove the security namespace + Trivy Operator
#
# Usage:
#   scripts/security-scan.sh trivy           # install Trivy Operator
#   scripts/security-scan.sh bench           # run kube-bench once
#   scripts/security-scan.sh report          # human summary of findings
#   scripts/security-scan.sh uninstall       # cleanup
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

TRIVY_NS="trivy-system"
BENCH_NS="security"

usage() {
  cat <<EOF
Usage: $0 <trivy | bench | report | uninstall>
EOF
}

ensure_bin kubectl
ensure_bin helm

# ── trivy: install operator ───────────────────────────────────────────────
install_trivy() {
  log_info "helm install trivy-operator → $TRIVY_NS"
  helm repo add aqua https://aquasecurity.github.io/helm-charts/ >/dev/null 2>&1 || true
  helm repo update aqua >/dev/null
  helm upgrade --install trivy-operator aqua/trivy-operator \
    --namespace "$TRIVY_NS" --create-namespace \
    --values "$REPO_ROOT/k8s/security/trivy-operator-values.yaml" \
    --wait --timeout 5m
  log_ok "Trivy Operator installed"
  log_info "scan kicks off automatically; results in CRDs:"
  log_info "  kubectl get vulnerabilityreports -A"
  log_info "  kubectl get configauditreports -A"
  log_info "  kubectl get rbacassessmentreports -A"
}

# ── bench: kube-bench one-shot ────────────────────────────────────────────
run_bench() {
  log_info "running kube-bench Job"
  # Delete any prior Job first — Jobs are immutable
  kubectl delete -f "$REPO_ROOT/k8s/security/kube-bench.yaml" --ignore-not-found
  kubectl apply -f "$REPO_ROOT/k8s/security/kube-bench.yaml"
  kubectl -n "$BENCH_NS" wait --for=condition=complete job/kube-bench --timeout=180s
  log_ok "kube-bench finished — output:"
  echo
  kubectl -n "$BENCH_NS" logs job/kube-bench --tail=-1
}

# ── report: aggregate everything to stdout ────────────────────────────────
report() {
  printf "${CYAN}━━━ Security report — $(date) ━━━${NC}\n"

  # 1. Kyverno violations
  printf "\n${CYAN}── Kyverno policy reports ──${NC}\n"
  if kubectl get cpol >/dev/null 2>&1; then
    kubectl get policyreports -A 2>/dev/null \
      | awk 'NR==1 || $4+$5+$6 > 0' | head -20
  else
    log_warn "Kyverno not installed — run 'make kyverno-install'"
  fi

  # 2. Trivy findings (HIGH + CRITICAL only)
  printf "\n${CYAN}── Trivy vulnerability findings (HIGH/CRITICAL) ──${NC}\n"
  if kubectl get crd vulnerabilityreports.aquasecurity.github.io >/dev/null 2>&1; then
    kubectl get vulnerabilityreports -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"  CRIT="}{.report.summary.criticalCount}{" HIGH="}{.report.summary.highCount}{"\n"}{end}' \
      | awk 'BEGIN{c=0;h=0} { for(i=1;i<=NF;i++){if($i~/CRIT=/){gsub("CRIT=","",$i); c+=$i} if($i~/HIGH=/){gsub("HIGH=","",$i); h+=$i}} print } END {printf "\nTotal: CRITICAL=%d HIGH=%d\n", c, h}'
  else
    log_warn "Trivy Operator not installed — run '$0 trivy'"
  fi

  # 3. Config audit findings
  printf "\n${CYAN}── Trivy config audit findings ──${NC}\n"
  if kubectl get crd configauditreports.aquasecurity.github.io >/dev/null 2>&1; then
    kubectl get configauditreports -A \
      -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,HIGH:.report.summary.highCount,MED:.report.summary.mediumCount,LOW:.report.summary.lowCount \
      | head -15
  fi

  # 4. kube-bench (run on demand)
  printf "\n${CYAN}── kube-bench (last run) ──${NC}\n"
  if kubectl -n "$BENCH_NS" get job kube-bench >/dev/null 2>&1; then
    kubectl -n "$BENCH_NS" logs job/kube-bench --tail=20 2>/dev/null \
      | grep -E "PASS|FAIL|WARN|^== Summary" | head -20
  else
    log_warn "kube-bench never ran — run '$0 bench'"
  fi

  printf "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# ── uninstall ─────────────────────────────────────────────────────────────
uninstall() {
  log_warn "removing trivy-operator + security namespace"
  helm uninstall trivy-operator -n "$TRIVY_NS" 2>/dev/null || true
  kubectl delete ns "$TRIVY_NS" --ignore-not-found
  kubectl delete ns "$BENCH_NS" --ignore-not-found
  log_ok "security stack removed"
}

case "${1:-}" in
  trivy)     install_trivy ;;
  bench)     run_bench ;;
  report)    report ;;
  uninstall) uninstall ;;
  ""|--help|-h) usage ;;
  *) log_error "unknown action: $1"; usage; exit 2 ;;
esac

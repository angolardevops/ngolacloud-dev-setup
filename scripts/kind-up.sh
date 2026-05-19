#!/usr/bin/env bash
# =============================================================================
# scripts/kind-up.sh — create the ngolacloud-dev Kind cluster + Cilium
# =============================================================================
# Phases:
#   1. Pre-flight: tools present, no cluster collision, Docker reachable
#   2. Create cluster from kind/cluster-dev.yaml
#   3. Install Cilium (replaces kindnet + kube-proxy)
#   4. Wait until every node Ready and Cilium pods Running
#   5. Install metrics-server (so `kubectl top` works)
#
# Exits with code 0 on success; 1 on cluster create failure; 2 on Cilium
# failure; 3 on missing tooling.
# =============================================================================
set -euo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  cat <<EOF
Usage: $0 [--recreate] [--no-cilium]
  --recreate    Delete existing cluster first (data loss!)
  --no-cilium   Skip Cilium install (use only kindnet fallback — debug only)
  --help        Show this help
EOF
}

RECREATE=0
INSTALL_CILIUM=1
while [ $# -gt 0 ]; do
  case "$1" in
    --recreate)  RECREATE=1; shift ;;
    --no-cilium) INSTALL_CILIUM=0; shift ;;
    --help|-h)   usage; exit 0 ;;
    *) log_error "unknown flag: $1"; usage; exit 2 ;;
  esac
done

trap 'log_error "kind-up failed at line $LINENO"' ERR

# ── 1) Pre-flight ─────────────────────────────────────────────────────────
log_info "phase 1/5 — pre-flight"
for b in kind kubectl helm docker; do ensure_bin "$b"; done
docker info >/dev/null 2>&1 || { log_error "Docker daemon unreachable"; exit 3; }

if kind get clusters 2>/dev/null | grep -qw "$KIND_CLUSTER"; then
  if [ "$RECREATE" -eq 1 ]; then
    log_warn "deleting existing cluster $KIND_CLUSTER"
    kind delete cluster --name "$KIND_CLUSTER"
  else
    log_warn "cluster $KIND_CLUSTER already exists — pass --recreate to wipe"
    exit 0
  fi
fi

# ── 2) Create cluster ─────────────────────────────────────────────────────
log_info "phase 2/5 — kind create cluster --config $KIND_CONFIG"
kind create cluster --name "$KIND_CLUSTER" --config "$KIND_CONFIG" --wait 3m
log_ok "cluster created"

kubectl config use-context "kind-$KIND_CLUSTER" >/dev/null

# ── 3) Cilium ─────────────────────────────────────────────────────────────
if [ "$INSTALL_CILIUM" -eq 1 ]; then
  log_info "phase 3/5 — helm install cilium v$CILIUM_VERSION"
  helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
  helm repo update cilium >/dev/null

  helm upgrade --install cilium cilium/cilium \
    --version "$CILIUM_VERSION" \
    --namespace kube-system \
    --values "$CILIUM_VALUES" \
    --wait --timeout 5m
  log_ok "Cilium installed"
else
  log_warn "phase 3/5 — Cilium SKIPPED (cluster will not have CNI; pods stuck Pending)"
fi

# ── 4) Wait for Ready ─────────────────────────────────────────────────────
log_info "phase 4/5 — wait for 4 nodes Ready"
wait_for "nodes Ready" 180 \
  "kubectl get nodes --no-headers 2>/dev/null | awk '\$2==\"Ready\"{n++} END{print n+0}'" \
  "4"

if [ "$INSTALL_CILIUM" -eq 1 ]; then
  wait_for "Cilium pods Running" 180 \
    "kubectl -n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null | grep -c Running" \
    "4"
fi

# ── 5) metrics-server (so `kubectl top` and admin Capacity widget work) ───
log_info "phase 5/5 — install metrics-server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml >/dev/null

# Kind doesn't have valid kubelet TLS to the metrics-server scraper — patch.
kubectl -n kube-system patch deploy metrics-server \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
  >/dev/null 2>&1 || true

# Restart deploy to pick up the patch
kubectl -n kube-system rollout restart deploy/metrics-server >/dev/null
log_ok "metrics-server installed"

# ── Summary ───────────────────────────────────────────────────────────────
echo
log_ok "ngolacloud-dev cluster ready"
kubectl get nodes -o wide

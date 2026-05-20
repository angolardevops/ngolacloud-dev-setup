#!/usr/bin/env bash
# =============================================================================
# scripts/chaos-install.sh — chaos-mesh install + experiment harness
# =============================================================================
# chaos-mesh is the runtime resilience tester: it injects faults (pod
# kill, network loss, CPU stress, disk stall) at scheduled intervals to
# prove the cluster recovers without manual intervention.
#
# Three experiments are bundled in k8s/chaos/:
#   01-pod-kill.yaml          random pod kill every 5 min
#   02-network-partition.yaml 50% packet loss for 60s
#   03-cpu-stress.yaml        peg 1 vCPU at 80% for 60s
#
# Each is namespace-scoped (only `chaos-target` ns) and label-scoped
# (only pods with `chaos.ngolacloud.ao/eligible=true`). Workloads MUST
# opt in — chaos won't touch arbitrary pods.
#
# Usage:
#   scripts/chaos-install.sh                # install controller
#   scripts/chaos-install.sh --apply        # also apply the 3 experiments
#   scripts/chaos-install.sh --target       # create chaos-target ns +
#                                             sample nginx deploy with opt-in label
#   scripts/chaos-install.sh --status       # show running experiments
#   scripts/chaos-install.sh --uninstall    # remove everything
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

CHAOS_VERSION="${CHAOS_VERSION:-2.7.0}"

usage() {
  cat <<EOF
Usage: $0 [--apply | --target | --status | --uninstall]
EOF
}

ensure_bin kubectl
ensure_bin helm

install_chaos_mesh() {
  log_info "helm install chaos-mesh v$CHAOS_VERSION"
  helm repo add chaos-mesh https://charts.chaos-mesh.org >/dev/null 2>&1 || true
  helm repo update chaos-mesh >/dev/null
  helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
    --namespace chaos-mesh --create-namespace \
    --version "$CHAOS_VERSION" \
    --set chaosDaemon.runtime=containerd \
    --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
    --set dashboard.create=true \
    --set dashboard.securityMode=true \
    --wait --timeout 5m
  log_ok "chaos-mesh installed"
  log_info "dashboard: kubectl -n chaos-mesh port-forward svc/chaos-dashboard 2333:2333"
}

apply_experiments() {
  log_info "applying k8s/chaos/ experiments"
  kubectl apply -f "$REPO_ROOT/k8s/chaos/"
  log_ok "experiments scheduled — see status with: $0 --status"
  log_warn "experiments target ns=chaos-target with label chaos.ngolacloud.ao/eligible=true"
  log_info "Create a test workload: $0 --target"
}

create_target() {
  kubectl create ns chaos-target --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chaos-canary
  namespace: chaos-target
  labels:
    chaos.ngolacloud.ao/eligible: "true"
spec:
  replicas: 3
  selector: {matchLabels: {app: chaos-canary}}
  template:
    metadata:
      labels:
        app: chaos-canary
        chaos.ngolacloud.ao/eligible: "true"
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          resources:
            requests: {cpu: "10m", memory: "16Mi"}
            limits:   {cpu: "100m", memory: "64Mi"}
EOF
  log_ok "chaos-target/chaos-canary deployment created (3 replicas, labelled eligible)"
}

status() {
  printf "${CYAN}── PodChaos ──${NC}\n"
  kubectl -n chaos-mesh get podchaos
  printf "\n${CYAN}── NetworkChaos ──${NC}\n"
  kubectl -n chaos-mesh get networkchaos
  printf "\n${CYAN}── StressChaos ──${NC}\n"
  kubectl -n chaos-mesh get stresschaos
  printf "\n${CYAN}── Recent events ──${NC}\n"
  kubectl -n chaos-target get events --sort-by=.lastTimestamp | tail -10
}

uninstall() {
  log_warn "removing chaos-mesh + experiments + chaos-target"
  kubectl delete -f "$REPO_ROOT/k8s/chaos/" --ignore-not-found
  helm uninstall chaos-mesh -n chaos-mesh 2>/dev/null || true
  kubectl delete ns chaos-mesh chaos-target --ignore-not-found
  log_ok "chaos stack removed"
}

case "${1:-install}" in
  install|"")    install_chaos_mesh ;;
  --apply)       install_chaos_mesh; apply_experiments ;;
  --target)      create_target ;;
  --status)      status ;;
  --uninstall)   uninstall ;;
  --help|-h)     usage ;;
  *) log_error "unknown flag: $1"; usage; exit 2 ;;
esac

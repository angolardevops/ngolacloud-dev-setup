#!/usr/bin/env bash
# =============================================================================
# scripts/benchmark.sh — baseline performance probe for the lab
# =============================================================================
# Measures the wall-clock time for the operations the operator runs every
# day. Two output modes:
#   • default: human-readable table (with colour)
#   • --json:  machine-readable, suitable for diffing across runs
#
# Targets you should expect on the reference workstation (i9-13900H,
# 64 GB DDR5, NVMe SSD):
#   • docker pull alpine     : <  3 s
#   • kind create cluster    : < 90 s
#   • cilium ready           : < 90 s
#   • kubectl get nodes      : <  500 ms
#   • deploy nginx + ready   : < 30 s
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

declare -A T   # timings
declare -A S   # status (ok/fail)

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

time_it() {
  local name="$1"; shift
  local t0 t1
  t0=$(now_ms)
  if "$@" >/dev/null 2>&1; then
    t1=$(now_ms)
    T[$name]=$((t1 - t0))
    S[$name]=ok
  else
    t1=$(now_ms)
    T[$name]=$((t1 - t0))
    S[$name]=fail
  fi
}

# Phase 1 — basic Docker reachability
time_it "docker_info"   docker info

# Phase 2 — pull a tiny image (network + Docker)
docker rmi alpine:3 >/dev/null 2>&1 || true
time_it "docker_pull_alpine"  docker pull alpine:3

# Phase 3 — kubectl latency (cluster must already be up — otherwise skipped)
if kind get clusters 2>/dev/null | grep -qw "$KIND_CLUSTER"; then
  time_it "kubectl_get_nodes"  kubectl --context kind-$KIND_CLUSTER get nodes
  time_it "kubectl_get_pods"   kubectl --context kind-$KIND_CLUSTER get pods -A
else
  S[kubectl_get_nodes]=skipped
  S[kubectl_get_pods]=skipped
fi

# Phase 4 — deploy a test workload (only if cluster running)
if kind get clusters 2>/dev/null | grep -qw "$KIND_CLUSTER"; then
  kubectl --context kind-$KIND_CLUSTER delete ns ngc-bench --ignore-not-found >/dev/null 2>&1
  kubectl --context kind-$KIND_CLUSTER create ns ngc-bench >/dev/null
  time_it "deploy_nginx" bash -c "
    kubectl --context kind-$KIND_CLUSTER -n ngc-bench create deploy bench-nginx --image=nginx:alpine --replicas=1
    kubectl --context kind-$KIND_CLUSTER -n ngc-bench wait --for=condition=Available deploy/bench-nginx --timeout=60s
  "
  kubectl --context kind-$KIND_CLUSTER delete ns ngc-bench --wait=false >/dev/null 2>&1
else
  S[deploy_nginx]=skipped
fi

# ── Output ────────────────────────────────────────────────────────────────
if [ "$JSON" -eq 1 ]; then
  printf '{\n'
  printf '  "host": {"vcpus": %d, "ram_gb": %d, "kernel": "%s"},\n' \
    "$(nproc)" \
    "$(awk '/^MemTotal:/ {print int($2/1024/1024)}' /proc/meminfo)" \
    "$(uname -r)"
  printf '  "timings_ms": {\n'
  local_keys=("docker_info" "docker_pull_alpine" "kubectl_get_nodes" "kubectl_get_pods" "deploy_nginx")
  for i in "${!local_keys[@]}"; do
    k="${local_keys[$i]}"
    [ "${S[$k]:-skipped}" = "skipped" ] && continue
    sep=","
    [ "$i" -eq $(( ${#local_keys[@]} - 1 )) ] && sep=""
    printf '    "%s": {"ms": %d, "status": "%s"}%s\n' "$k" "${T[$k]:-0}" "${S[$k]}" "$sep"
  done
  printf '  }\n}\n'
else
  printf "${CYAN}ngolacloud-dev benchmark${NC}\n"
  printf "  host: %d vCPU · %d GB RAM · kernel %s\n\n" \
    "$(nproc)" \
    "$(awk '/^MemTotal:/ {print int($2/1024/1024)}' /proc/meminfo)" \
    "$(uname -r)"
  printf "  %-24s %10s   %s\n" "OPERATION" "MS" "STATUS"
  printf "  %-24s %10s   %s\n" "─────────" "──" "──────"
  for k in docker_info docker_pull_alpine kubectl_get_nodes kubectl_get_pods deploy_nginx; do
    status="${S[$k]:-skipped}"
    ms="${T[$k]:-—}"
    case "$status" in
      ok)      colour=$GREEN ;;
      fail)    colour=$RED   ;;
      skipped) colour=$YEL   ;;
    esac
    printf "  %-24s %10s   ${colour}%s${NC}\n" "$k" "$ms" "$status"
  done
fi

#!/usr/bin/env bash
# =============================================================================
# loadtest-hpa.sh — drive CPU load at the portal and watch the HPA scale.
#
# Proves the Horizontal Pod Autoscaler reacts to real traffic in the kind
# dev cluster (Blocker #7 — load/scale validation). Requires metrics-server
# (so HPA targets resolve) — kind-up.sh installs it; the Rust `infra dev`
# path does not yet (see follow-up).
#
# No external load tool needed: N parallel `curl` workers hammer an
# auth-gated endpoint (Django still runs middleware + auth on a 403, which
# costs CPU). Default target is the public ingress over TLS.
#
# Usage:
#   loadtest-hpa.sh [URL] [WORKERS] [DURATION_S]
# Defaults: https://ngolacloud.local/api/v1/  120  180
# =============================================================================
set -euo pipefail

URL="${1:-https://ngolacloud.local/api/v1/}"
WORKERS="${2:-120}"
DURATION="${3:-180}"
CTX="${KCTX:-kind-ngolacloud-dev}"
NS="${KNS:-ngolacloud}"

echo "load → ${URL}  workers=${WORKERS}  duration=${DURATION}s  ctx=${CTX}/${NS}"
echo "baseline HPA:"
kubectl --context "${CTX}" -n "${NS}" get hpa

deadline=$(( $(date +%s) + DURATION ))

# One worker = a tight curl loop until the shared deadline.
worker() {
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    curl -sk -o /dev/null --max-time 5 "${URL}" || true
  done
}
export -f worker
export URL deadline

# Fan out WORKERS background loops.
pids=()
for _ in $(seq 1 "${WORKERS}"); do
  worker &
  pids+=($!)
done
echo "spawned ${#pids[@]} workers (pid range ${pids[0]}..${pids[-1]})"

# Poll HPA + top every 15s while the load runs.
peak_replicas=0
while [ "$(date +%s)" -lt "${deadline}" ]; do
  sleep 15
  echo "----- $(date +%T) -----"
  kubectl --context "${CTX}" -n "${NS}" top pods 2>/dev/null | grep -E 'portal|NAME' || true
  line=$(kubectl --context "${CTX}" -n "${NS}" get hpa portal --no-headers 2>/dev/null || true)
  echo "HPA: ${line}"
  reps=$(echo "${line}" | awk '{print $(NF-1)}')
  [[ "${reps}" =~ ^[0-9]+$ ]] && [ "${reps}" -gt "${peak_replicas}" ] && peak_replicas="${reps}"
done

# Reap workers.
for p in "${pids[@]}"; do kill "${p}" 2>/dev/null || true; done
wait 2>/dev/null || true

echo "===================================================="
echo "peak portal replicas observed under load: ${peak_replicas}"
kubectl --context "${CTX}" -n "${NS}" get hpa
echo "(scale-down follows the HPA stabilization window, ~5 min default)"

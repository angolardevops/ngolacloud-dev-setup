#!/usr/bin/env bash
# =============================================================================
# scripts/dr-drill.sh — etcd snapshot/restore disaster recovery drill
# =============================================================================
# Walks through the canonical "we lost the cluster" recovery:
#
#   snapshot   → take an etcd snapshot to /tmp/ngc-dr/etcd-<ts>.db
#   sandbox    → create a sentinel ConfigMap (dr-drill/sentinel) AFTER
#                the snapshot — restoring should DROP it
#   chaos      → kubectl delete the sentinel (simulates the loss)
#   restore    → copy snapshot to control-plane, etcdctl snapshot restore,
#                replace /var/lib/etcd, restart kube-apiserver
#   verify     → check the sentinel ConfigMap is BACK (the snapshot won)
#
# Designed for the ngolacloud-dev Kind cluster — adapt the etcdctl
# endpoint to your prod cluster's stacked etcd by changing ETCD_POD.
#
# Usage:
#   scripts/dr-drill.sh snapshot
#   scripts/dr-drill.sh full      # snapshot + sandbox + chaos + restore + verify
#   scripts/dr-drill.sh list      # list snapshots in /tmp/ngc-dr/
#   scripts/dr-drill.sh restore <snapshot-file>
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

DR_DIR="${DR_DIR:-/tmp/ngc-dr}"
mkdir -p "$DR_DIR"

# In Kind the control-plane is a single Docker container; etcd runs as a
# static pod inside it. We exec into the container, not into the etcd pod
# (etcdctl is bundled with the etcd image, not the host).
CTRL_PLANE="${CTRL_PLANE:-${KIND_CLUSTER}-control-plane}"
ETCD_CMD="docker exec $CTRL_PLANE etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://127.0.0.1:2379"

usage() {
  cat <<EOF
Usage: $0 <action> [args]
  snapshot              Take an etcd snapshot to $DR_DIR/etcd-<ts>.db
  list                  List snapshots in $DR_DIR/
  restore <file>        Restore from snapshot file (control-plane goes down briefly)
  full                  snapshot + sandbox + chaos + restore + verify (~60s)
  --help                Show this help
EOF
}

ensure_bin docker
ensure_bin kubectl

snapshot() {
  local ts file
  ts=$(date +%Y%m%d-%H%M%S)
  file="$DR_DIR/etcd-${ts}.db"
  log_info "taking etcd snapshot → $file"
  $ETCD_CMD snapshot save "/tmp/etcd-${ts}.db" >/dev/null
  docker cp "$CTRL_PLANE:/tmp/etcd-${ts}.db" "$file"
  docker exec "$CTRL_PLANE" rm -f "/tmp/etcd-${ts}.db"
  log_ok "snapshot saved: $file ($(du -h "$file" | awk '{print $1}'))"
  echo "$file"
}

list_snapshots() {
  log_info "snapshots in $DR_DIR/"
  ls -lh "$DR_DIR"/etcd-*.db 2>/dev/null || log_warn "no snapshots found"
}

restore() {
  local file="$1"
  [ -f "$file" ] || { log_error "snapshot file not found: $file"; exit 2; }

  log_warn "restoring from $file — control-plane will be briefly down"

  # 1. Copy snapshot into the control-plane container
  local basename ts
  basename=$(basename "$file")
  ts=${basename#etcd-}; ts=${ts%.db}
  docker cp "$file" "$CTRL_PLANE:/tmp/$basename"

  # 2. Stop kube-apiserver + etcd by moving manifests aside
  log_info "stopping kube-apiserver + etcd static pods"
  docker exec "$CTRL_PLANE" mkdir -p /tmp/manifests-bak
  docker exec "$CTRL_PLANE" mv /etc/kubernetes/manifests/etcd.yaml \
                              /tmp/manifests-bak/etcd.yaml
  docker exec "$CTRL_PLANE" mv /etc/kubernetes/manifests/kube-apiserver.yaml \
                              /tmp/manifests-bak/kube-apiserver.yaml
  # Wait for kubelet to notice the manifest removal (poll up to 30s)
  sleep 8

  # 3. Move existing etcd data aside, restore from snapshot
  log_info "snapshot restore → /var/lib/etcd"
  docker exec "$CTRL_PLANE" mv /var/lib/etcd /var/lib/etcd.bak.$ts
  docker exec "$CTRL_PLANE" etcdutl snapshot restore "/tmp/$basename" \
    --data-dir /var/lib/etcd \
    --name "$CTRL_PLANE" \
    --initial-cluster "$CTRL_PLANE=https://127.0.0.1:2380" \
    --initial-advertise-peer-urls https://127.0.0.1:2380 \
    --skip-hash-check >/dev/null
  # etcd inside Kind expects root:root, not the qemu user
  docker exec "$CTRL_PLANE" chown -R root:root /var/lib/etcd

  # 4. Restore the static pod manifests — kubelet picks them up
  log_info "restoring static pod manifests"
  docker exec "$CTRL_PLANE" mv /tmp/manifests-bak/etcd.yaml \
                              /etc/kubernetes/manifests/etcd.yaml
  docker exec "$CTRL_PLANE" mv /tmp/manifests-bak/kube-apiserver.yaml \
                              /etc/kubernetes/manifests/kube-apiserver.yaml

  # 5. Wait for the API server to come back
  wait_for "API server reachable after restore" 90 \
    "kubectl get --raw /healthz 2>/dev/null || echo X" "ok"

  log_ok "restored from $file"
}

full_drill() {
  banner() { printf "\n${CYAN}── %s${NC}\n" "$*"; }

  banner "1/5 — pre-snapshot baseline"
  kubectl get cm -n default -o name 2>/dev/null | wc -l \
    | xargs -I{} log_info "ConfigMaps in default namespace: {}"

  banner "2/5 — snapshot"
  local file
  file=$(snapshot | tail -1)

  banner "3/5 — sandbox (sentinel created AFTER snapshot)"
  kubectl create configmap dr-sentinel -n default \
    --from-literal=created_at="post-snapshot-$(date +%s)" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log_ok "created cm/dr-sentinel — should NOT survive restore"

  banner "4/5 — chaos (simulating cluster loss)"
  log_info "no actual chaos needed — restore will rewind us past the sentinel"

  banner "5/5 — restore + verify"
  restore "$file"
  sleep 5

  if kubectl get cm dr-sentinel -n default >/dev/null 2>&1; then
    log_error "DR drill FAILED — dr-sentinel still exists after restore"
    kubectl delete cm dr-sentinel -n default --ignore-not-found >/dev/null
    exit 1
  else
    log_ok "DR drill PASS — dr-sentinel is gone, snapshot won"
  fi
}

action="${1:-}"
case "$action" in
  snapshot)            snapshot ;;
  list)                list_snapshots ;;
  restore)             restore "${2:-}" ;;
  full)                full_drill ;;
  --help|-h|help|"")   usage ;;
  *) log_error "unknown action: $action"; usage; exit 2 ;;
esac

#!/usr/bin/env bash
# =============================================================================
# scripts/vault-dev-reseed.sh — restore dev Vault + ESO state after a restart
# =============================================================================
# WHY THIS EXISTS
# ---------------
# The dev cluster's Vault (helm release `vault` in ns `vault-system`) runs in
# `vault server -dev` mode: everything lives in memory. That is deliberate —
# dev mode is auto-unsealed, so a laptop/Z440 reboot never blocks on a manual
# `vault operator unseal`. The trade-off is that EVERY Vault restart wipes:
#   * the kubernetes auth method config + the `ngc-bpf-agent` policy/role, and
#   * every KV entry under `secret/ngc-bpf-agent/*`.
# When that happens the ClusterSecretStore flips to InvalidProviderConfig
# (auth/kubernetes/login → 403) and all per-tenant ExternalSecrets go to
# SecretSyncedError.
#
# This script is the one-command recovery path. It is fully idempotent, so you
# can run it after any reboot (or from a boot-time Job — see the systemd/Job
# note at the bottom) to get the fleet back to "12/12 SecretSynced".
#
# It does NOT make Vault persistent — that is the prod design (Raft storage +
# transit auto-unseal, see ngolacloud-infra/k8s/security/vault-values.yaml +
# ansible/playbooks/25-vault-transit.yml). Dev intentionally trades persistence
# for zero unseal friction; this re-seed is the dev counterpart.
#
# USAGE
#   scripts/vault-dev-reseed.sh            # full restore (auth + all tenants)
#   scripts/vault-dev-reseed.sh --check    # report state, change nothing
#
# OVERRIDABLE ENV
#   VAULT_NS (vault-system)  VAULT_POD (vault-0)  VAULT_DEV_TOKEN (ngc-dev-root)
#   PORTAL_NS (ngolacloud)   ES_NS (ngolacloud-system)
#   MIGRATE_SCRIPT (…/ngolacloud-portal/scripts/bpf/migrate_to_eso.py)
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

VAULT_NS="${VAULT_NS:-vault-system}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_DEV_TOKEN="${VAULT_DEV_TOKEN:-ngc-dev-root}"   # dev-mode root token (DEV ONLY)
PORTAL_NS="${PORTAL_NS:-ngolacloud}"
ES_NS="${ES_NS:-ngolacloud-system}"
ESO_NS="${ESO_NS:-external-secrets}"
MIGRATE_SCRIPT="${MIGRATE_SCRIPT:-$REPO_ROOT/../ngolacloud-portal/scripts/bpf/migrate_to_eso.py}"

ensure_bin kubectl

# ── discover the per-tenant ExternalSecrets (source of truth for slugs) ──────
# Names look like `ngc-bpf-agent-<slug>-token`; strip prefix + suffix.
discover_slugs() {
  kubectl get externalsecret -n "$ES_NS" -o name 2>/dev/null \
    | sed -E 's#^externalsecret(\.external-secrets\.io)?/##' \
    | sed -E 's#^ngc-bpf-agent-(.*)-token$#\1#' \
    | sort -u
}

check() {
  log_info "ClusterSecretStore:"
  kubectl get clustersecretstore vault-ngolacloud 2>/dev/null || log_warn "store missing"
  log_info "ExternalSecrets in $ES_NS:"
  kubectl get externalsecret -n "$ES_NS" 2>/dev/null || true
  local ready total
  ready=$(kubectl get externalsecret -n "$ES_NS" --no-headers 2>/dev/null | awk '{print $NF}' | grep -c '^True$' || true)
  total=$(kubectl get externalsecret -n "$ES_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  log_info "synced=${ready:-0}/${total:-0}"
}

if [ "${1:-}" = "--check" ]; then check; exit 0; fi

# ── 1) auth-delegator CRB ────────────────────────────────────────────────────
# Required because the Vault kube-auth config below pins NO token_reviewer_jwt,
# so Vault validates each login with the CALLER's token (the ESO SA).
log_info "ensuring system:auth-delegator for the external-secrets SA"
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: external-secrets-auth-delegator
  labels:
    app.kubernetes.io/part-of: ngolacloud
    app.kubernetes.io/component: security
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: external-secrets
    namespace: external-secrets
YAML
log_ok "auth-delegator CRB applied"

# ── 2) Vault kube-auth method + ngc-bpf-agent policy/role ────────────────────
log_info "configuring Vault kubernetes auth + ngc-bpf-agent policy/role"
kubectl exec -i -n "$VAULT_NS" "$VAULT_POD" -- sh <<EOF >/dev/null
set -e
export VAULT_TOKEN=$VAULT_DEV_TOKEN
vault secrets list 2>/dev/null | grep -q "^secret/" || vault secrets enable -path=secret -version=2 kv
vault auth list 2>/dev/null | grep -q "^kubernetes/" || vault auth enable -path=kubernetes kubernetes
# No token_reviewer_jwt on purpose — a pinned, short-lived reviewer JWT is what
# breaks login with a 403 after a restart. Caller-token review instead.
vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"
cat <<POLICY | vault policy write ngc-bpf-agent -
path "secret/data/ngc-bpf-agent/*" { capabilities = ["read"] }
path "secret/metadata/ngc-bpf-agent/*" { capabilities = ["read", "list"] }
POLICY
vault write auth/kubernetes/role/ngc-bpf-agent \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=ngc-bpf-agent ttl=1h
EOF
log_ok "Vault auth/policy/role configured"

# ── 3) mint a real token per tenant + write to Vault KV ──────────────────────
if [ ! -f "$MIGRATE_SCRIPT" ]; then
  log_error "migrate_to_eso.py not found at $MIGRATE_SCRIPT — set MIGRATE_SCRIPT=…"
  exit 4
fi
PORTAL=$(kubectl get pods -n "$PORTAL_NS" -l app.kubernetes.io/name=portal -o name 2>/dev/null | head -1)
[ -z "$PORTAL" ] && { log_error "no portal pod in ns $PORTAL_NS"; exit 5; }
log_info "portal pod: $PORTAL"

slugs=$(discover_slugs)
[ -z "$slugs" ] && { log_warn "no per-tenant ExternalSecrets found in $ES_NS — nothing to seed"; slugs=""; }

for slug in $slugs; do
  out=$(kubectl exec -i -n "$PORTAL_NS" "$PORTAL" -- env BPF_TENANT="$slug" python manage.py shell < "$MIGRATE_SCRIPT" 2>/dev/null || true)
  kvcmd=$(printf '%s\n' "$out" | grep '^vault kv put' || true)
  if [ -z "$kvcmd" ]; then log_warn "$slug: mint failed (tenant missing?)"; continue; fi
  # Pipe the kv-put via stdin so the raw token never lands in argv / logs.
  if printf 'export VAULT_TOKEN=%s\n%s\n' "$VAULT_DEV_TOKEN" "$kvcmd" \
       | kubectl exec -i -n "$VAULT_NS" "$VAULT_POD" -- sh >/dev/null 2>&1; then
    log_ok "$slug seeded"
  else
    log_warn "$slug: vault kv put failed"
  fi
done

# ── 4) force ESO to re-validate the store + re-sync ──────────────────────────
log_info "restarting ESO controller to re-validate the store"
kubectl rollout restart deploy/external-secrets -n "$ESO_NS" >/dev/null 2>&1 || true
kubectl rollout status  deploy/external-secrets -n "$ESO_NS" --timeout=90s >/dev/null 2>&1 || true
kubectl annotate externalsecret -n "$ES_NS" --all force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 || true

# ── 5) wait + report ─────────────────────────────────────────────────────────
log_info "waiting for ExternalSecrets to sync…"
for _ in $(seq 1 20); do
  ready=$(kubectl get externalsecret -n "$ES_NS" --no-headers 2>/dev/null | awk '{print $NF}' | grep -c '^True$' || true)
  total=$(kubectl get externalsecret -n "$ES_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${ready:-0}" = "${total:-0}" ] && [ "${total:-0}" -gt 0 ] && break
  sleep 3
done
check
[ "${ready:-0}" = "${total:-0}" ] && [ "${total:-0}" -gt 0 ] \
  && log_ok "dev Vault re-seed complete — ${ready}/${total} synced" \
  || { log_error "incomplete — ${ready:-0}/${total:-0} synced; check 'kubectl describe externalsecret -n $ES_NS'"; exit 6; }

# =============================================================================
# AUTOMATING ON BOOT (optional)
# -----------------------------
# To run this automatically after a host/kind restart, add a user systemd unit
# that waits for the kube-apiserver and then runs this script, e.g.:
#
#   ~/.config/systemd/user/ngc-vault-reseed.service
#     [Unit]
#     Description=Re-seed dev Vault + ESO after cluster restart
#     After=network-online.target
#     [Service]
#     Type=oneshot
#     ExecStartPre=/usr/bin/env bash -c 'until kubectl get ns >/dev/null 2>&1; do sleep 5; done'
#     ExecStart=%h/…/dev-setup/scripts/vault-dev-reseed.sh
#     [Install]
#     WantedBy=default.target
#
#   systemctl --user enable --now ngc-vault-reseed.service
# =============================================================================

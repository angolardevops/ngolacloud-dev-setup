#!/usr/bin/env bash
# =============================================================================
# scripts/eso-install.sh — External Secrets Operator + (optional) Vault dev
# =============================================================================
# Two flows:
#   default        Install ESO controllers. You point them at an EXISTING
#                  Vault yourself.
#   --with-vault   Also install Vault in dev mode in-cluster (UNLOCKED,
#                  ROOT TOKEN visible — DEV ONLY), seed a sample secret,
#                  configure the Kubernetes auth backend + role, apply
#                  ClusterSecretStore + sample ExternalSecret.
#
# Usage:
#   scripts/eso-install.sh                # ESO only
#   scripts/eso-install.sh --with-vault   # ESO + Vault dev + sample wiring
#   scripts/eso-install.sh --demo         # show the synced K8s Secret value
#   scripts/eso-install.sh --uninstall    # remove ESO + Vault dev
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

ESO_VERSION="${ESO_VERSION:-0.10.4}"

usage() {
  cat <<EOF
Usage: $0 [--with-vault | --demo | --uninstall]
EOF
}

ensure_bin kubectl
ensure_bin helm

install_eso() {
  log_info "helm install external-secrets v$ESO_VERSION"
  helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
  helm repo update external-secrets >/dev/null
  helm upgrade --install external-secrets external-secrets/external-secrets \
    --namespace external-secrets --create-namespace \
    --version "$ESO_VERSION" \
    --set installCRDs=true \
    --wait --timeout 5m
  log_ok "ESO controllers running"
}

install_vault_dev() {
  log_info "helm install vault (dev mode — UNLOCKED, root token printed)"
  helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
  helm repo update hashicorp >/dev/null
  # Dev mode keeps everything in memory — perfect for laptop, NEVER in prod.
  helm upgrade --install vault hashicorp/vault \
    --namespace vault-dev --create-namespace \
    --set "server.dev.enabled=true" \
    --set "server.dev.devRootToken=ngolacloud-dev-root" \
    --set "server.dataStorage.enabled=false" \
    --set "ui.enabled=true" \
    --wait --timeout 3m

  wait_for "vault-0 Running" 60 \
    "kubectl -n vault-dev get pod vault-0 --no-headers 2>/dev/null | awk '{print \$3}'" "Running"
  sleep 5  # let vault finish unsealing
}

configure_vault() {
  log_info "configuring Vault: enable kubernetes auth + write sample secret"
  kubectl -n vault-dev exec -it vault-0 -- sh -c '
    set -e
    export VAULT_TOKEN=ngolacloud-dev-root
    # 1) Enable kubernetes auth backend (idempotent)
    vault auth enable -path=kubernetes kubernetes 2>/dev/null || true
    # 2) Configure it to talk to the cluster API
    vault write auth/kubernetes/config \
      kubernetes_host="https://kubernetes.default.svc:443"
    # 3) Policy granting read on secret/data/portal/*
    cat <<POLICY | vault policy write external-secrets-policy -
path "secret/data/portal/*" { capabilities = ["read"] }
POLICY
    # 4) Role binding the external-secrets SA to the policy
    vault write auth/kubernetes/role/external-secrets \
      bound_service_account_names=external-secrets \
      bound_service_account_namespaces=external-secrets \
      policies=external-secrets-policy \
      ttl=1h
    # 5) Seed sample secret
    vault kv put secret/portal/db username=admin password=ngolacloud-demo
  ' >/dev/null
  log_ok "Vault configured (root token: ngolacloud-dev-root)"
}

apply_eso_resources() {
  log_info "applying ClusterSecretStore + sample ExternalSecret"
  kubectl apply -f "$REPO_ROOT/k8s/secrets/vault-secretstore.yaml"
  kubectl apply -f "$REPO_ROOT/k8s/secrets/sample-externalsecret.yaml"
  log_ok "applied — wait ~30s for first sync"
}

demo() {
  log_info "waiting up to 90s for ESO to sync portal-db-credentials"
  for i in $(seq 1 30); do
    if kubectl -n default get secret portal-db-credentials >/dev/null 2>&1; then
      log_ok "secret synced after ~$((i*3))s"
      log_info "decoded values:"
      kubectl -n default get secret portal-db-credentials \
        -o jsonpath='{.data}' \
        | jq -r 'to_entries[] | "  \(.key) = \(.value | @base64d)"'
      return 0
    fi
    sleep 3
  done
  log_error "timeout — check 'kubectl describe externalsecret portal-db-credentials -n default'"
  return 1
}

uninstall() {
  log_warn "removing ESO + Vault dev + sample resources"
  kubectl delete -f "$REPO_ROOT/k8s/secrets/sample-externalsecret.yaml" --ignore-not-found
  kubectl delete -f "$REPO_ROOT/k8s/secrets/vault-secretstore.yaml" --ignore-not-found
  helm uninstall external-secrets -n external-secrets 2>/dev/null || true
  helm uninstall vault -n vault-dev 2>/dev/null || true
  kubectl delete ns external-secrets vault-dev --ignore-not-found
  log_ok "removed"
}

case "${1:-install}" in
  install|"")
    install_eso
    ;;
  --with-vault)
    install_eso
    install_vault_dev
    configure_vault
    apply_eso_resources
    log_info "show the synced secret: $0 --demo"
    ;;
  --demo)         demo ;;
  --uninstall)    uninstall ;;
  --help|-h)      usage ;;
  *) log_error "unknown flag: $1"; usage; exit 2 ;;
esac

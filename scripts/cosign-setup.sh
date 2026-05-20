#!/usr/bin/env bash
# =============================================================================
# scripts/cosign-setup.sh — install cosign + sign/verify image helpers
# =============================================================================
# Cosign (Sigstore) is the foundation of the supply-chain trust pipeline:
# every image we ship is signed; Kyverno's verifyImages policy enforces
# that signature at admission time.
#
# Two flows:
#   keyless    (recommended)  signs with an ephemeral cert tied to your
#                             OIDC identity (GitHub Actions OIDC token in
#                             CI, browser-based for ad-hoc dev signing).
#                             Verifiable forever via the Rekor transparency
#                             log without storing any private key.
#
#   key-based                 cosign generate-key-pair → cosign.key (priv)
#                             + cosign.pub (public). Use for air-gapped
#                             clusters where Rekor isn't reachable.
#
# Usage:
#   scripts/cosign-setup.sh install                        # install cosign CLI
#   scripts/cosign-setup.sh keygen                         # generate key-pair
#   scripts/cosign-setup.sh sign <image-ref>               # keyless sign
#   scripts/cosign-setup.sh sign-key <image-ref>           # key-based sign
#   scripts/cosign-setup.sh verify <image-ref>             # verify any signature
#   scripts/cosign-setup.sh apply-policy                   # kubectl apply verifyImages
#   scripts/cosign-setup.sh remove-policy                  # kubectl delete verifyImages
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

COSIGN_VERSION="${COSIGN_VERSION:-2.4.1}"
POLICY_FILE="$REPO_ROOT/k8s/supply-chain/verify-images-policy.yaml"
KEY_DIR="${HOME}/.config/cosign"

usage() {
  cat <<EOF
Usage: $0 <action> [args]

  install              Install cosign CLI v$COSIGN_VERSION to /usr/local/bin
  keygen               Generate a key-pair in $KEY_DIR/
  sign <image>         Sign keyless (browser OIDC prompt or CI token)
  sign-key <image>     Sign with $KEY_DIR/cosign.key
  verify <image>       Verify the signature (auto-detects mode)
  apply-policy         kubectl apply -f k8s/supply-chain/verify-images-policy.yaml
  remove-policy        Delete the policy
  --help               Show this help
EOF
}

install_cosign() {
  if command -v cosign >/dev/null 2>&1; then
    log_ok "cosign already installed: $(cosign version --json 2>/dev/null | head -1)"
    return
  fi
  log_info "downloading cosign v$COSIGN_VERSION"
  sudo curl -fsSL -o /usr/local/bin/cosign \
    "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64"
  sudo chmod +x /usr/local/bin/cosign
  log_ok "cosign installed: $(cosign version 2>&1 | head -1)"
}

keygen() {
  mkdir -p "$KEY_DIR"
  if [ -f "$KEY_DIR/cosign.key" ]; then
    log_warn "$KEY_DIR/cosign.key already exists — refusing to overwrite"
    return 1
  fi
  log_info "generating Cosign key-pair in $KEY_DIR/"
  log_info "(you'll be prompted for a passphrase — leave empty for unattended use)"
  ( cd "$KEY_DIR" && cosign generate-key-pair )
  log_ok "key-pair saved: $KEY_DIR/cosign.{key,pub}"
  log_info "public key (paste into verify-images-policy.yaml if using key-based):"
  cat "$KEY_DIR/cosign.pub"
}

sign_keyless() {
  local image="${1:-}"
  [ -z "$image" ] && { log_error "image ref required"; exit 2; }
  ensure_bin cosign
  log_info "keyless sign: $image (browser/OIDC prompt may appear)"
  COSIGN_EXPERIMENTAL=1 cosign sign --yes "$image"
  log_ok "signed; verify with: $0 verify $image"
}

sign_key() {
  local image="${1:-}"
  [ -z "$image" ] && { log_error "image ref required"; exit 2; }
  [ -f "$KEY_DIR/cosign.key" ] || { log_error "$KEY_DIR/cosign.key missing — run '$0 keygen'"; exit 2; }
  ensure_bin cosign
  log_info "key-based sign: $image"
  cosign sign --key "$KEY_DIR/cosign.key" --yes "$image"
  log_ok "signed; verify with: $0 verify $image"
}

verify() {
  local image="${1:-}"
  [ -z "$image" ] && { log_error "image ref required"; exit 2; }
  ensure_bin cosign

  # Try keyless first (matches angolardevops/* identity), then key-based.
  if COSIGN_EXPERIMENTAL=1 cosign verify "$image" \
        --certificate-identity-regexp 'https://github.com/angolardevops/.*' \
        --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
        >/dev/null 2>&1; then
    log_ok "keyless verification PASSED"
  elif [ -f "$KEY_DIR/cosign.pub" ] \
        && cosign verify --key "$KEY_DIR/cosign.pub" "$image" >/dev/null 2>&1; then
    log_ok "key-based verification PASSED (key: $KEY_DIR/cosign.pub)"
  else
    log_error "verification FAILED — image has no recognised signature"
    exit 1
  fi
}

apply_policy() {
  ensure_bin kubectl
  if ! kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
    log_error "Kyverno not installed — run 'make kyverno-install' first"
    exit 2
  fi
  log_info "applying verify-images ClusterPolicy (Audit mode)"
  kubectl apply -f "$POLICY_FILE"
  log_ok "policy active — see violations with: kubectl get policyreports -A"
  log_info "flip to Enforce: kubectl patch cpol verify-image-signatures \\"
  log_info "  --type='json' -p='[{\"op\":\"replace\",\"path\":\"/spec/validationFailureAction\",\"value\":\"Enforce\"}]'"
}

remove_policy() {
  kubectl delete -f "$POLICY_FILE" --ignore-not-found
  log_ok "policy removed"
}

action="${1:-}"
shift || true
case "$action" in
  install)       install_cosign ;;
  keygen)        keygen ;;
  sign)          sign_keyless "$@" ;;
  sign-key)      sign_key "$@" ;;
  verify)        verify "$@" ;;
  apply-policy)  apply_policy ;;
  remove-policy) remove_policy ;;
  ""|--help|-h)  usage ;;
  *) log_error "unknown action: $action"; usage; exit 2 ;;
esac

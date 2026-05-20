#!/usr/bin/env bash
# =============================================================================
# scripts/onboard.sh — one-shot bootstrap for a fresh workstation
# =============================================================================
# Runs the full happy-path so a new dev goes from `git clone` to "Grafana
# dashboard open" with one command. Each phase prompts before destructive
# steps; use `--yes` to skip all prompts (CI / automation).
#
# Phases:
#   1. validate-host.sh   (read-only sanity check)
#   2. confirm sudo password (one-time cache)
#   3. ansible-playbook setup.yml (slice + docker + tools + rust)
#   4. reboot ONLY if GRUB changed (THP)  [skipped with --no-reboot]
#   5. kind-up.sh --with-observability     (cluster + Cilium + prom + grafana)
#   6. benchmark.sh                        (baseline timing)
#   7. open browser to Grafana
#
# Idempotent: re-running detects what's already done and skips ahead.
# =============================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

YES=0
SKIP_REBOOT=0
SKIP_OBS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)     YES=1; shift ;;
    --no-reboot)  SKIP_REBOOT=1; shift ;;
    --no-obs)     SKIP_OBS=1; shift ;;
    --help|-h)
      cat <<EOF
Usage: $0 [--yes] [--no-reboot] [--no-obs]
  --yes        Don't prompt — assume yes (CI mode)
  --no-reboot  Don't reboot even if GRUB changed
  --no-obs     Don't install observability stack
EOF
      exit 0 ;;
    *) log_error "unknown flag: $1"; exit 2 ;;
  esac
done

confirm() {
  if [ "$YES" -eq 1 ]; then return 0; fi
  local prompt="$1"
  read -r -p "$(printf "${CYAN}? %s [Y/n] ${NC}" "$prompt")" reply
  case "${reply:-y}" in
    [yY]*) return 0 ;;
    *)     return 1 ;;
  esac
}

banner() {
  printf "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
  printf "${CYAN}  %s${NC}\n" "$*"
  printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

trap 'log_error "onboard failed at line $LINENO (phase: ${PHASE:-unknown})"' ERR

# ── Phase 1: preflight ────────────────────────────────────────────────────
PHASE="1/7 preflight"
banner "Phase 1/7 — preflight"
if ! "$SCRIPT_DIR/validate-host.sh"; then
  rc=$?
  if [ "$rc" -eq 2 ]; then
    log_error "preflight FAIL — fix the items above and re-run"
    exit 2
  fi
  log_warn "preflight WARN — see above"
  confirm "Continue anyway?" || exit 1
fi

# ── Phase 2: sudo warm-up ─────────────────────────────────────────────────
PHASE="2/7 sudo"
banner "Phase 2/7 — sudo credentials"
log_info "Caching sudo credentials (you may be prompted once)"
sudo -v
# Keep sudo alive while we run long phases.
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
SUDO_KEEPALIVE=$!
trap 'kill $SUDO_KEEPALIVE 2>/dev/null || true' EXIT

# ── Phase 3: ansible setup ────────────────────────────────────────────────
PHASE="3/7 setup"
banner "Phase 3/7 — ansible setup (slice + docker + tools + rust)"
if confirm "Run 'make setup' now? (~5-10 min on first run)"; then
  cd "$REPO_ROOT"
  make setup
else
  log_warn "skipping ansible setup — health-check + kind-up may fail"
fi

# ── Phase 4: reboot if GRUB changed ───────────────────────────────────────
PHASE="4/7 reboot"
banner "Phase 4/7 — reboot check"
if [ -f /var/run/reboot-required ] && [ "$SKIP_REBOOT" -ne 1 ]; then
  log_warn "/var/run/reboot-required exists — GRUB cmdline was changed (THP=madvise)"
  if confirm "Reboot now? Re-run 'scripts/onboard.sh --yes --no-reboot' after boot"; then
    sudo reboot
    exit 0
  else
    log_warn "Reboot deferred. THP and any other GRUB-dependent change won't apply until reboot."
  fi
else
  log_ok "no reboot needed"
fi

# ── Phase 5: kind-up ──────────────────────────────────────────────────────
PHASE="5/7 kind-up"
banner "Phase 5/7 — Kind cluster + Cilium${SKIP_OBS:+ (no observability)}"

# Gate: kind-up needs helm + kubectl + kind. If setup was skipped or
# kind_tools role didn't install them, fail fast with an actionable
# message rather than dying inside kind-up.sh's ensure_bin check.
missing_bins=()
for b in helm kubectl kind; do
  command -v "$b" >/dev/null 2>&1 || missing_bins+=("$b")
done
if [ ${#missing_bins[@]} -gt 0 ]; then
  log_error "kind-up prerequisites missing: ${missing_bins[*]}"
  log_info  "If you declined Phase 3, recover with one of:"
  log_info  "  • make setup TAGS=kind       (install just helm/kustomize/k9s/stern via Ansible)"
  log_info  "  • make setup                  (full host setup, ~10 min)"
  log_info  "Then re-run: scripts/onboard.sh --yes --no-reboot"
  exit 3
fi

if confirm "Run kind-up now?"; then
  obs_flag=""
  [ "$SKIP_OBS" -ne 1 ] && obs_flag="--with-observability"
  "$SCRIPT_DIR/kind-up.sh" $obs_flag
else
  log_warn "skipping kind-up — onboarding stops here"
  exit 0
fi

# ── Phase 6: benchmark ────────────────────────────────────────────────────
PHASE="6/7 benchmark"
banner "Phase 6/7 — baseline benchmark"
"$SCRIPT_DIR/benchmark.sh"

# ── Phase 7: open browser ─────────────────────────────────────────────────
PHASE="7/7 grafana"
banner "Phase 7/7 — open Grafana"
if [ "$SKIP_OBS" -eq 1 ]; then
  log_info "observability skipped — phase 7 is a no-op"
else
  log_ok "Grafana available at http://localhost:3000  (admin / ngolacloud-dev)"
  if command -v xdg-open >/dev/null && [ "$YES" -ne 1 ]; then
    confirm "Open Grafana in your browser?" && xdg-open http://localhost:3000 >/dev/null 2>&1 &
  fi
fi

banner "ngolacloud-dev lab ready ✓"
log_ok "Next steps: cd into a ngolacloud-* repo, copy .envrc.template → .envrc, direnv allow"

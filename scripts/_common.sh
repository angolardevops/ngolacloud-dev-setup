# shellcheck shell=bash
# Shared helpers for ngolacloud-dev-setup scripts. Sourced by every entry-
# point script. No top-level `set -e` here — callers own that.

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; DIM='\033[0;90m'; NC='\033[0m'

log_info()  { printf "${CYAN}[%s] ➜${NC} %s\n"   "$(date +%H:%M:%S)" "$*"; }
log_ok()    { printf "${GREEN}[%s] ✓${NC} %s\n"  "$(date +%H:%M:%S)" "$*"; }
log_warn()  { printf "${YEL}[%s] ⚠${NC} %s\n"    "$(date +%H:%M:%S)" "$*" >&2; }
log_error() { printf "${RED}[%s] ✗${NC} %s\n"    "$(date +%H:%M:%S)" "$*" >&2; }
log_dim()   { printf "${DIM}    %s${NC}\n"        "$*"; }

# Resolve repo root: ../ relative to scripts/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_DIR REPO_ROOT

# Defaults — can be overridden via env or CLI flags.
KIND_CLUSTER="${KIND_CLUSTER:-ngolacloud-dev}"
KIND_CONFIG="${KIND_CONFIG:-$REPO_ROOT/kind/cluster-dev.yaml}"
CILIUM_VALUES="${CILIUM_VALUES:-$REPO_ROOT/kind/cilium-values.yaml}"
CILIUM_VERSION="${CILIUM_VERSION:-1.16.0}"

# Wait until `kubectl` returns matching output, or fail after `timeout` seconds.
# Usage: wait_for "description" <timeout_s> 'kubectl ... -o name | wc -l' '4'
wait_for() {
  local desc="$1" timeout_s="$2" cmd="$3" want="$4"
  local deadline=$(( $(date +%s) + timeout_s ))
  log_info "$desc (timeout ${timeout_s}s)"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$(eval "$cmd")" = "$want" ]; then
      log_ok "$desc — OK"
      return 0
    fi
    sleep 2
  done
  log_error "$desc — timeout"
  return 1
}

ensure_bin() {
  local b="$1"
  command -v "$b" >/dev/null 2>&1 || { log_error "missing $b — run 'make setup' first"; exit 3; }
}

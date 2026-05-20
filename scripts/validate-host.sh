#!/usr/bin/env bash
# =============================================================================
# scripts/validate-host.sh — pre-flight check, runnable WITHOUT sudo
# =============================================================================
# Verifies all the assumptions baked into the Ansible roles before the user
# kicks off `make setup`. Designed to be safe to run on any Linux box —
# no writes, no sudo, no apt. Exit codes:
#
#   0  every check passed → safe to `make setup`
#   1  one or more soft warnings (proceed at your own risk)
#   2  hard fail (setup will abort or break the host)
#
# Intentionally a thin wrapper around `cat /proc/*`, `awk`, and a couple of
# `command -v` lookups — no bash-isms older than 4.0.
# =============================================================================
set -euo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

WARN=0
FAIL=0

check_ok()   { printf "  %-30s ${GREEN}✓ OK${NC}     %s\n"   "$1" "$2"; }
check_warn() { printf "  %-30s ${YEL}! WARN${NC}   %s\n"     "$1" "$2"; WARN=1; }
check_fail() { printf "  %-30s ${RED}✗ FAIL${NC}   %s\n"     "$1" "$2"; FAIL=1; }

printf "${CYAN}ngolacloud-dev-setup — preflight${NC}\n"
printf "─────────────────────────────────────────────────────────\n"

# ── 1) OS identification ──────────────────────────────────────────────────
# Zorin uses its own VERSION_ID (e.g. "18") but is built on a specific
# Ubuntu base announced via UBUNTU_CODENAME (e.g. "noble"=24.04). Always
# resolve to the underlying Ubuntu codename for the check.
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-unknown}}"
  case "$ID" in
    ubuntu|zorin)
      case "$codename" in
        noble|oracular|plucky|questing)  # 24.04 / 24.10 / 25.04 / 25.10
          check_ok "OS" "$PRETTY_NAME (base: $codename)"
          ;;
        *)
          check_fail "OS" "$PRETTY_NAME — base codename '$codename' — need noble (24.04)+"
          ;;
      esac
      ;;
    *)
      check_fail "OS" "$PRETTY_NAME — only Ubuntu/Zorin supported"
      ;;
  esac
else
  check_fail "OS" "/etc/os-release missing"
fi

# ── 2) Kernel + cgroup v2 ─────────────────────────────────────────────────
kernel=$(uname -r)
kmajor=${kernel%%.*}
if [ "$kmajor" -ge 6 ]; then
  check_ok "Kernel" "$kernel"
else
  check_warn "Kernel" "$kernel — 6.x recommended for Cilium eBPF features"
fi

if [ -e /sys/fs/cgroup/cgroup.controllers ]; then
  check_ok "cgroup v2" "unified hierarchy"
else
  check_fail "cgroup v2" "missing — add systemd.unified_cgroup_hierarchy=1 to GRUB and reboot"
fi

# ── 3) CPU + RAM budget ───────────────────────────────────────────────────
cpus=$(nproc)
if [ "$cpus" -ge 8 ]; then
  check_ok "CPU cores" "$cpus logical (≥ 8 recommended)"
elif [ "$cpus" -ge 4 ]; then
  check_warn "CPU cores" "$cpus logical — Kind + Rust builds will compete"
else
  check_fail "CPU cores" "$cpus logical — too few for the 32 GB Kind budget"
fi

mem_gb=$(awk '/^MemTotal:/ {print int($2/1024/1024)}' /proc/meminfo)
if [ "$mem_gb" -ge 32 ]; then
  check_ok "RAM" "${mem_gb} GB (≥ 32 GB needed for 32 GB slice + system)"
elif [ "$mem_gb" -ge 16 ]; then
  check_warn "RAM" "${mem_gb} GB — must shrink slice_memory_max_gb in inventory.ini"
else
  check_fail "RAM" "${mem_gb} GB — insufficient for a viable Kind cluster"
fi

# ── 4) Disk space on / ────────────────────────────────────────────────────
disk_avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [ "$disk_avail_gb" -ge 100 ]; then
  check_ok "Free disk /" "${disk_avail_gb} GB"
elif [ "$disk_avail_gb" -ge 50 ]; then
  check_warn "Free disk /" "${disk_avail_gb} GB — tight (recommend ≥ 100 GB)"
else
  check_fail "Free disk /" "${disk_avail_gb} GB — playbook will abort"
fi

# ── 5) Filesystem type ────────────────────────────────────────────────────
fstype=$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)
case "$fstype" in
  ext4|btrfs|xfs) check_ok "Root FS" "$fstype" ;;
  zfs)            check_warn "Root FS" "$fstype — Docker overlay2 needs extra config on ZFS" ;;
  *)              check_warn "Root FS" "$fstype — untested" ;;
esac

# ── 6) Snap Docker (incompatible with our slice) ──────────────────────────
if [ -d /snap/docker ]; then
  check_fail "Snap Docker" "DETECTED — run 'sudo snap remove --purge docker' before setup"
else
  check_ok "Snap Docker" "absent"
fi

# ── 7) Sudo without password (required for non-interactive `make setup`) ──
# `sudo -n true` is a no-op probe; it doesn't re-source bashrc the way
# `sudo -nv` does in some Zorin/GNOME setups.
if sudo -n true 2>/dev/null; then
  check_ok "sudo NOPASSWD" "available"
else
  check_warn "sudo NOPASSWD" "will prompt for password — pass --ask-become-pass to ansible if needed"
fi

# ── 8) Internet reachability (for apt + GitHub releases) ──────────────────
# /dev/tcp/ requires bash compiled with --enable-net-redirections (true on
# Ubuntu but not guaranteed everywhere). curl is universally available
# once we have apt-installed packages.
if command -v curl >/dev/null 2>&1; then
  if curl -fsS --max-time 4 -o /dev/null https://download.docker.com/linux/ubuntu/; then
    check_ok "Internet" "download.docker.com reachable"
  else
    check_fail "Internet" "cannot reach download.docker.com — apt install will fail"
  fi
else
  check_warn "Internet" "curl missing — install curl to enable this probe"
fi

# ── 9) ansible installed (required for the playbook) ──────────────────────
if command -v ansible-playbook >/dev/null 2>&1; then
  ansible_v=$(ansible --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  check_ok "ansible" "v${ansible_v}"
else
  check_fail "ansible" "missing — apt install ansible"
fi

# ── 10) BIOS virtualisation (only needed for TAGS=kvm) ────────────────────
if grep -E -m1 '(vmx|svm)' /proc/cpuinfo >/dev/null; then
  check_ok "CPU virt (vmx/svm)" "exposed — nested KVM OK"
else
  check_warn "CPU virt (vmx/svm)" "missing — TAGS=kvm will fail; Tier 1-4 still fine"
fi

# ── Summary ───────────────────────────────────────────────────────────────
printf "─────────────────────────────────────────────────────────\n"
if [ "$FAIL" -eq 1 ]; then
  printf "${RED}FAIL${NC} — fix the items above before running 'make setup'\n"
  exit 2
elif [ "$WARN" -eq 1 ]; then
  printf "${YEL}WARN${NC} — proceed with caution\n"
  exit 1
else
  printf "${GREEN}READY${NC} — run 'make setup' next\n"
  exit 0
fi

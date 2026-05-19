#!/usr/bin/env bash
# =============================================================================
# scripts/health-check.sh — workstation lab health summary
# =============================================================================
# Prints a coloured table of the lab state. Exit codes:
#   0  all green
#   1  one or more components degraded/missing
# =============================================================================
set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; NC='\033[0m'

FAIL=0

row() {
  local name="$1" status="$2" detail="$3"
  local glyph color
  case "$status" in
    ok)    glyph="✓ OK   "; color="$GREEN" ;;
    warn)  glyph="! WARN "; color="$YEL"   ;;
    fail)  glyph="✗ FAIL "; color="$RED"; FAIL=1 ;;
    *)     glyph="? ???  "; color="$NC"    ;;
  esac
  printf "  %-22s ${color}%s${NC}  %s\n" "$name" "$glyph" "$detail"
}

printf "${CYAN}ngolacloud-dev lab health${NC}\n"
printf "─────────────────────────────────────────────────────────\n"

# ── Docker ────────────────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ver=$(docker --version | awk '{print $3}' | tr -d ',')
    drv=$(docker info --format '{{.CgroupDriver}}' 2>/dev/null)
    sto=$(docker info --format '{{.Driver}}' 2>/dev/null)
    if [ "$drv" = "systemd" ] && [ "$sto" = "overlay2" ]; then
      row "Docker Engine" ok "v$ver ($sto, $drv)"
    else
      row "Docker Engine" warn "v$ver (storage=$sto, cgroup=$drv)"
    fi
  else
    row "Docker Engine" fail "binary present but daemon not responding"
  fi
else
  row "Docker Engine" fail "docker not installed"
fi

# ── Slice ─────────────────────────────────────────────────────────────────
if systemctl show ngolacloud-dev.slice -p MemoryMax --value 2>/dev/null | grep -q '^[0-9]'; then
  max_bytes=$(systemctl show ngolacloud-dev.slice -p MemoryMax --value)
  max_gb=$((max_bytes / 1024 / 1024 / 1024))
  used_bytes=$(systemctl show ngolacloud-dev.slice -p MemoryCurrent --value 2>/dev/null || echo 0)
  used_gb=$(awk "BEGIN {printf \"%.1f\", $used_bytes/1024/1024/1024}")
  row "Resource Slice" ok "${max_gb}G limit, ${used_gb}G used"
else
  row "Resource Slice" fail "ngolacloud-dev.slice not configured"
fi

# ── Kind cluster ──────────────────────────────────────────────────────────
if command -v kind >/dev/null 2>&1; then
  clusters=$(kind get clusters 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  if echo "$clusters" | grep -qw "ngolacloud-dev"; then
    nodes_ready=$(kubectl --context kind-ngolacloud-dev get nodes --no-headers 2>/dev/null \
                  | awk '$2=="Ready"{n++} END{print n+0}')
    nodes_total=$(kubectl --context kind-ngolacloud-dev get nodes --no-headers 2>/dev/null | wc -l)
    if [ "$nodes_total" -gt 0 ] && [ "$nodes_ready" -eq "$nodes_total" ]; then
      row "Kind Cluster" ok "ngolacloud-dev ($nodes_ready/$nodes_total nodes ready)"
    else
      row "Kind Cluster" warn "ngolacloud-dev ($nodes_ready/$nodes_total nodes ready)"
    fi
  else
    row "Kind Cluster" warn "ngolacloud-dev cluster not found (others: ${clusters:-none})"
  fi
else
  row "Kind Cluster" fail "kind not installed"
fi

# ── RAM ───────────────────────────────────────────────────────────────────
mem_total=$(awk '/^MemTotal:/ {print int($2/1024/1024)}' /proc/meminfo)
mem_avail=$(awk '/^MemAvailable:/ {print int($2/1024/1024)}' /proc/meminfo)
mem_used=$((mem_total - mem_avail))
if [ "$mem_avail" -gt 8 ]; then
  row "System RAM" ok "${mem_used}G used / ${mem_avail}G free of ${mem_total}G"
else
  row "System RAM" warn "${mem_used}G used / ${mem_avail}G free of ${mem_total}G — low"
fi

# ── CPU load ──────────────────────────────────────────────────────────────
cores=$(nproc)
load1=$(awk '{print $1}' /proc/loadavg)
load_int=${load1%.*}
if [ "${load_int:-0}" -lt "$cores" ]; then
  row "System CPU" ok "load avg $load1 ($cores cores)"
else
  row "System CPU" warn "load avg $load1 ($cores cores) — saturated"
fi

# ── Disk ──────────────────────────────────────────────────────────────────
disk_used=$(df -BG / | awk 'NR==2{print int($3)}')
disk_avail=$(df -BG / | awk 'NR==2{print int($4)}')
disk_pct=$(df / | awk 'NR==2{print $5}' | tr -d %)
if [ "$disk_pct" -lt 85 ]; then
  row "Disk /" ok "${disk_used}G used / ${disk_avail}G free (${disk_pct}%)"
elif [ "$disk_pct" -lt 95 ]; then
  row "Disk /" warn "${disk_used}G used / ${disk_avail}G free (${disk_pct}%) — tight"
else
  row "Disk /" fail "${disk_used}G used / ${disk_avail}G free (${disk_pct}%) — critical"
fi

# ── Swap ──────────────────────────────────────────────────────────────────
swap_total=$(awk '/^SwapTotal:/ {print int($2/1024/1024)}' /proc/meminfo)
swap_used=$(awk '/^SwapTotal:/ {t=$2} /^SwapFree:/ {f=$2; print int((t-f)/1024/1024)}' /proc/meminfo)
swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo "?")
if [ "$swap_total" -gt 0 ]; then
  row "Swap" ok "${swap_used}G used of ${swap_total}G (swappiness $swappiness)"
else
  row "Swap" warn "no swap configured (swappiness $swappiness)"
fi

# ── THP ───────────────────────────────────────────────────────────────────
thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null \
       | grep -oE '\[(always|madvise|never)\]' | tr -d '[]')
if [ "$thp" = "madvise" ]; then
  row "Transparent Hugepages" ok "$thp"
else
  row "Transparent Hugepages" warn "$thp (expected: madvise)"
fi

# ── Reboot flag ───────────────────────────────────────────────────────────
if [ -f /var/run/reboot-required ]; then
  row "Reboot required" warn "yes — /var/run/reboot-required present"
fi

printf "─────────────────────────────────────────────────────────\n"
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}Lab ready for ngolacloud development ✓${NC}\n"
  exit 0
else
  printf "${RED}One or more components failing — see above.${NC}\n"
  exit 1
fi

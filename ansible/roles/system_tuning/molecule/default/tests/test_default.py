"""
Testinfra assertions for the system_tuning role.

Runs against the privileged Ubuntu container molecule spins up. NOT a
substitute for real-hardware testing — kernel-level effects (GRUB,
udev, real swap on a real block device) are skipped here because the
container shares the host kernel and has no GRUB of its own.

What IS covered:
  • sysctl override file exists and has the right values applied at runtime
  • modules-load.d entries written
  • udev rule file exists (effect not testable in container)
  • swap file CREATED (mkswap header present) — even though container
    swap won't `swapon` (no /proc/sys/vm permission to flip swappiness
    in a docker-default cap set)
  • assert tasks at the end of the role didn't fail (proven by the
    fact that the playbook converged at all)
"""

import os
import pytest


# ── 1) sysctl override file ─────────────────────────────────────────────
def test_sysctl_file_present(host):
    f = host.file("/etc/sysctl.d/99-ngolacloud-dev.conf")
    assert f.exists
    assert f.user == "root"
    assert f.group == "root"
    assert f.mode == 0o644


@pytest.mark.parametrize("key,want", [
    ("vm.swappiness",                    "10"),
    ("fs.inotify.max_user_watches",      "524288"),
    ("net.ipv4.ip_forward",              "1"),
    ("vm.max_map_count",                 "524288"),
    ("net.bridge.bridge-nf-call-iptables", "1"),
])
def test_sysctl_value_applied(host, key, want):
    # sysctl --system was run as a handler; values should be in effect.
    got = host.run(f"sysctl -n {key}").stdout.strip()
    assert got == want, f"{key}={got}, want {want}"


# ── 2) module load file ─────────────────────────────────────────────────
def test_modules_load_file(host):
    f = host.file("/etc/modules-load.d/ngolacloud-dev.conf")
    assert f.exists
    assert "br_netfilter" in f.content_string
    assert "overlay" in f.content_string


# ── 3) udev I/O scheduler rule ──────────────────────────────────────────
def test_udev_io_rule(host):
    f = host.file("/etc/udev/rules.d/60-ioschedulers.rules")
    assert f.exists
    assert "nvme" in f.content_string
    assert "mq-deadline" in f.content_string
    assert "bfq" in f.content_string


# ── 4) GRUB cmdline (file present, can't reboot to validate effect) ─────
def test_grub_cmdline_madvise(host):
    f = host.file("/etc/default/grub")
    assert f.exists
    assert "transparent_hugepage=madvise" in f.content_string
    assert "cgroup_enable=memory" in f.content_string


# ── 5) Swap file exists with mkswap header ──────────────────────────────
def test_swap_file_created(host):
    f = host.file("/swapfile")
    assert f.exists
    assert f.user == "root"
    assert f.mode == 0o600
    # blkid -p will recognise it as swap if mkswap ran
    result = host.run("blkid -p /swapfile")
    assert result.rc == 0
    assert "swap" in result.stdout.lower()


# ── 6) /etc/fstab persists the swap entry ───────────────────────────────
def test_fstab_swap_entry(host):
    fstab = host.file("/etc/fstab").content_string
    assert "/swapfile" in fstab
    assert "swap" in fstab


# ── 7) THP runtime is madvise (the role echoes it at apply time) ────────
def test_thp_runtime_madvise(host):
    f = host.file("/sys/kernel/mm/transparent_hugepage/enabled")
    if f.exists:
        # Container may have inherited from host; only assert if writable
        if os.access("/sys/kernel/mm/transparent_hugepage/enabled", os.W_OK):
            assert "[madvise]" in f.content_string

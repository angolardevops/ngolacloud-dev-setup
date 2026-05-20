"""
Testinfra assertions for the resource_slicing role.

Verifies the systemd slice unit + the docker drop-in are written with
the correct values from inventory vars.
"""

import pytest


# ── 1) Slice unit file ─────────────────────────────────────────────────
def test_slice_file_exists(host):
    f = host.file("/etc/systemd/system/ngolacloud-dev.slice")
    assert f.exists
    assert f.user == "root"
    assert f.group == "root"
    assert f.mode == 0o644


@pytest.mark.parametrize("snippet", [
    "MemoryMax=32G",
    "MemoryHigh=28G",
    "CPUWeight=75",
    "IOWeight=100",
    "TasksMax=8192",
    "Description=ngolacloud development resource slice",
])
def test_slice_file_content(host, snippet):
    f = host.file("/etc/systemd/system/ngolacloud-dev.slice")
    assert snippet in f.content_string, f"missing in slice unit: {snippet}"


# ── 2) Docker drop-in ──────────────────────────────────────────────────
def test_docker_dropin_exists(host):
    f = host.file("/etc/systemd/system/docker.service.d/slice.conf")
    assert f.exists
    assert f.mode == 0o644


def test_docker_dropin_content(host):
    f = host.file("/etc/systemd/system/docker.service.d/slice.conf")
    assert "[Service]" in f.content_string
    assert "Slice=ngolacloud-dev.slice" in f.content_string


# ── 3) Slice is started + has the configured MemoryMax ─────────────────
def test_slice_started(host):
    # systemctl show may fail if the slice didn't load. Either way the
    # MemoryMax property is what we care about.
    result = host.run(
        "systemctl show ngolacloud-dev.slice -p MemoryMax --value"
    )
    assert result.rc == 0
    # 32 GiB in bytes = 32 * 1024^3
    want = 32 * 1024 * 1024 * 1024
    assert int(result.stdout.strip()) == want

"""
Testinfra assertions for the docker_engine role.

What we CAN test in the molecule container:
  • apt repo + GPG key configured
  • daemon.json content matches inventory values
  • docker.service drop-in pinned to ngolacloud-dev.slice
  • docker-ce / docker-ce-cli / containerd.io packages installed
  • The role's hard pre-flight (snap docker absent) didn't trip

What we CAN'T fully assert (covered by .github/workflows/smoke.yml):
  • dockerd actually started and reports cgroupdriver=systemd
  • docker info storage driver = overlay2 at runtime
"""

import json
import pytest


# ── 1) APT repo + key ───────────────────────────────────────────────────
def test_docker_apt_key_present(host):
    f = host.file("/etc/apt/keyrings/docker.asc")
    assert f.exists
    assert "BEGIN PGP PUBLIC KEY BLOCK" in f.content_string


def test_docker_apt_source_present(host):
    f = host.file("/etc/apt/sources.list.d/docker.list")
    assert f.exists
    assert "download.docker.com/linux/ubuntu" in f.content_string
    assert "noble stable" in f.content_string


# ── 2) Packages installed ───────────────────────────────────────────────
@pytest.mark.parametrize("pkg", [
    "docker-ce",
    "docker-ce-cli",
    "containerd.io",
    "docker-buildx-plugin",
    "docker-compose-plugin",
])
def test_packages_installed(host, pkg):
    assert host.package(pkg).is_installed


# ── 3) daemon.json content ──────────────────────────────────────────────
def test_daemon_json_present(host):
    f = host.file("/etc/docker/daemon.json")
    assert f.exists
    assert f.mode == 0o644


def test_daemon_json_content(host):
    f = host.file("/etc/docker/daemon.json")
    cfg = json.loads(f.content_string)
    assert cfg["exec-opts"] == ["native.cgroupdriver=systemd"]
    assert cfg["storage-driver"] == "overlay2"
    assert cfg["log-driver"] == "json-file"
    assert cfg["log-opts"]["max-size"] == "100m"
    assert cfg["log-opts"]["max-file"] == "3"
    assert cfg["features"]["buildkit"] is True
    assert cfg["live-restore"] is True
    assert cfg["userland-proxy"] is False
    assert cfg["ipv6"] is False
    # Address pool — confirm the laptop-friendly 172.30/16 range
    assert cfg["default-address-pools"][0]["base"] == "172.30.0.0/16"


# ── 4) Slice drop-in ────────────────────────────────────────────────────
def test_docker_slice_dropin(host):
    f = host.file("/etc/systemd/system/docker.service.d/slice.conf")
    assert f.exists
    assert "Slice=ngolacloud-dev.slice" in f.content_string


# ── 5) Snap docker NOT present (the preflight) ──────────────────────────
def test_no_snap_docker(host):
    f = host.file("/snap/docker")
    assert not f.exists

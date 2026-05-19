# ADR-0004 — Nested KVM staging on the workstation

Date: 2026-05-19
Status: accepted

## Context

The Kind dev cluster gives high feedback velocity but is structurally
different from production: Docker containers as "nodes", no real
libvirt, no kubeadm. Promoting a change directly from Kind to Z440 /
Hetzner skips an entire validation step — most prod-only breakages
land at the worst possible time.

We need an intermediate stage that exercises the SAME codepath as
production (`ngolacloud infra apply` against KVM/libvirt) without
booking time on a shared hardware lab.

## Decision

Provision a **nested KVM cluster on the workstation** with 1 control
plane + 2 workers (~16 GB RAM), configured via
`kvm/staging-cluster.toml`. The cluster runs the same kubeadm
bootstrap, containerd, Cilium and platform deploy as production.

Add an `ngolacloud-dev-setup` role `kvm_host` (tagged `never` so it
only runs when explicitly asked via `make setup TAGS=kvm`) that
installs libvirt + qemu-kvm + cloud-init utils + bridge-utils.

## Rationale

- **Same codepath as prod** — kubeadm, libvirt, containerd, cloud-init
  cycle. If `ngolacloud infra apply` works here, the only prod-specific
  risks left are: real network (VLAN, MTU 9000), real storage (ZFS/Ceph),
  HA failover, NUMA.
- **No shared hardware required** — Z440 / Hetzner are scarce; staging
  on the laptop is always available.
- **Light-weight on the host** — 16 GB sits inside the 24 GB "parallel"
  budget; doesn't fight the Kind cluster.
- **Repeatable** — destroy + recreate the staging cluster in <5 min.

## Trade-offs

- **Nested virtualisation overhead** — kubeadm bootstrap is ~2× slower
  than on bare metal (acceptable for validation, not for benchmarking)
- **Single CP** — no HA validation. For 3-CP failover, use the Z440
  staging cluster (real metal, multi-host).
- **Default libvirt network (192.168.122.0/24)** — bridge-mode NIC
  setups, VLAN tags and 10 GbE behaviour aren't tested.
- **Storage** — qcow2 on `/var/lib/libvirt/images` (ext4). PVC tests
  here aren't representative of Longhorn / Ceph behaviour.

## When to use which validation tier

| Change kind | Kind | Nested KVM | Z440 / Hetzner |
|---|---|---|---|
| Helm chart change, app code | ✓ | (optional) | (production) |
| kubeadm config / containerd / Cilium | ✓ | **✓ required** | (production) |
| Storage class / PVC change | (optional) | (helpful) | **✓ required** |
| Network policy / VLAN | (optional) | (partial) | **✓ required** |
| HA failover / kube-vip | ✗ | ✗ | **✓ required** |
| NUMA / hugepage tuning | ✗ | (partial) | **✓ required** |

## Consequences

- `make setup TAGS=kvm` is the opt-in install — keeps the default
  Tier 1 install footprint small for contributors who don't need it
- `kvm/staging-cluster.toml` and `kvm/cloud-init-user-data.yml.template`
  must stay in sync with what the production `.ngolacloud.toml` looks
  like — otherwise the staging tier validates the wrong thing
- The user must be in the `libvirt` and `kvm` groups (the role
  adds them but you need a new login session for it to take effect)

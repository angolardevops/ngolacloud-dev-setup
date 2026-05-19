# ADR-0003 — systemd slice caps Kind+Docker at 32 GB

Date: 2026-05-19
Status: accepted

## Context

The workstation has 64 GB RAM. Without a budget, a Kind cluster
running NgolaCloud workloads + `cargo build --release` of the Rust
CLI can each spike to 30+ GB simultaneously; either OOM-kills the
GNOME shell or pushes the laptop into thrash.

## Decision

A systemd `ngolacloud-dev.slice` with `MemoryMax=32G`, `MemoryHigh=28G`,
`CPUWeight=75`, `TasksMax=8192`. Docker is wired to this slice via a
`/etc/systemd/system/docker.service.d/slice.conf` drop-in. Every
container Docker spawns — including Kind node containers — inherits
the cap.

## Rationale

- **Hard memory cap**: the kernel OOMs inside the slice before touching
  anything outside (no risk of killing the desktop)
- **Soft pressure 4 GB before the cap**: workloads have a window to
  release memory cleanly before being killed
- **CPU weight, not pinning**: pinning fragments the host scheduler;
  weight lets the kernel rebalance when nothing competes
- **Inherits naturally**: any process Docker starts is in the slice —
  including arbitrary `kind` invocations, side-channel `docker run …`,
  helm pulls, etc.

## Budget

```
1 control plane × ~4 GB =  4 GB
3 workers       × ~7 GB = 21 GB
Cilium + addons         =  3 GB
Workload tests          =  4 GB
─────────────────────────────
Total slice             = 32 GB  (MemoryMax)
```

Remaining 32 GB:
- ~8 GB for OS + GNOME + browser + IDE
- ~24 GB for parallel work (`cargo build`, ad-hoc Docker outside the
  Kind workflow, KVM VMs for nested staging)

## Consequences

- If the slice is too tight in practice we raise it in `inventory.ini`
  (`slice_memory_max_gb`) and re-run `make setup TAGS=slice`. The
  drop-in path keeps Docker daemon-restarts minimal.
- Anything spawned OUTSIDE Docker (e.g. `kubectl exec` against a remote
  cluster) is NOT in the slice and so isn't capped — this is correct
  but worth remembering when debugging "why is my laptop melting".
- The slice survives reboots (it's a unit file, not a runtime-only
  cgroup); on every fresh boot it's lazy-loaded when Docker starts.

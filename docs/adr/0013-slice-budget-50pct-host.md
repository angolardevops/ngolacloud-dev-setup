# ADR-0013 — Slice budget defaults to 50% of host (RAM + CPU)

- **Status:** Accepted
- **Date:** 2026-05-20
- **Driver:** Phase D of the dev-setup → CLI roadmap. Initiated by
  feedback that Docker (inside `ngolacloud-dev.slice`) was eating more
  than half the host on smaller machines, leaving no room for editor +
  browser + native cargo/pnpm builds outside the slice.

## Context

The pre-v1.3.0 `resource_slicing` role pinned the slice budget to
absolute numbers in `inventory.ini`:

```ini
slice_memory_max_gb      = 32
slice_memory_high_gb     = 28
slice_cpu_weight         = 75
slice_tasks_max          = 8192
```

This was calibrated for the reference i9-13900H + 64 GB workstation
(half the host, leaving 32 GB for everything else). On any other host:

| Host                | Pre-v1.3.0 budget | Effective share |
|---------------------|-------------------|-----------------|
| 16 GB laptop        | 32 GB (impossible)| OOM at boot     |
| 32 GB laptop        | 32 GB             | 100% — host dies |
| 64 GB (reference)   | 32 GB             | 50% — correct   |
| 128 GB workstation  | 32 GB             | 25% — wasteful  |

Also, the role had **no `CPUQuota`** — only `CPUWeight=75`. CPUWeight
is a *relative* hint that only kicks in under contention; under no
contention, the slice gets 100% of the CPU. A heavy `cargo build` could
starve the host's editor + browser even though the operator thought
they had a 75% cap.

## Decision

Defaults move from `inventory.ini` (per-host pin) into
`roles/resource_slicing/defaults/main.yml` (Jinja-derived from facts):

```yaml
slice_memory_max_gb:  "{{ (ansible_memtotal_mb / 1024 * 0.50) | int }}"
slice_memory_high_gb: "{{ (ansible_memtotal_mb / 1024 * 0.45) | int }}"
slice_cpu_quota_pct:  "{{ ansible_processor_vcpus * 50 }}"
slice_cpu_weight:     100
slice_tasks_max:      8192
```

The slice config gains `CPUQuota={{ slice_cpu_quota_pct }}%` — a
**hard** CPU cap. systemd's `CPUQuota=N%` is normalised to "N% of one
CPU", so `vcpus × 50` expresses "50% of total CPU time". For example,
on a 20-vCPU box the value is `1000%` = 10 cores worth.

`inventory.ini` keeps the old pins as **commented opt-in overrides**.
Operators who want a lab-only 70%-of-host policy uncomment one line.

## Consequences

### Positive

- **Linear scaling across hardware.** A 16 GB laptop gets `MemMax=8G`,
  a 128 GB workstation gets `MemMax=64G` — no per-host config.
- **Hard CPU cap.** `cargo build` inside the slice can't drown the
  host's editor + browser anymore. Operator gets responsive UI even
  during heavy builds.
- **The "50% policy" is now a single number in the codebase.** Tweaking
  the budget (e.g. to 45% on lower-RAM machines) is one constant
  change, not a host-by-host pin reshuffle.

### Negative

- Operators with custom budgets in `inventory.ini` will see the values
  ignored after re-running `make setup` (the old keys are now opt-in
  overrides; the defaults take over). Mitigation: CHANGELOG v1.3.0
  flags this explicitly + shows how to restore the legacy pin.
- One factor we don't model: CPU **heterogeneity** (P-cores vs
  E-cores on Intel hybrid silicon, A-cores vs M-cores on ARM). The
  systemd CPUQuota treats all vCPUs as equivalent. Acceptable for the
  dev lab — true HPC workloads would want a cpuset-based slice instead.

### Neutral

- The `CPUWeight=100` keeps the slice on equal footing with other
  slices under contention (e.g. when a `dnf upgrade` runs alongside).
  Downscaling it further would only matter if a competing slice exists,
  which isn't the case on a single-user dev workstation.

## Implementation

- `ansible/roles/resource_slicing/defaults/main.yml` — new file, 1
  source of truth for the percentages.
- `ansible/roles/resource_slicing/tasks/main.yml` — adds `CPUQuota=`
  line to the slice unit file template.
- `ansible/inventory.ini` — pre-v1.3.0 keys retained, **commented**.
- `scripts/health-check.sh` — shows `(N% of host)` next to the memory
  cap; new "Slice CPU Quota" row with both per-CPU and per-host %.

## Verification

```console
# 64 GB / 14-vcpu host (ansible's count of vcpus on i9-13900H):
$ ansible-playbook -i inventory.ini /tmp/render.yml | grep msg
"msg": "MemMax=31G  MemHigh=28G  CPUQuota=700%"

# 32 GB / 8-vcpu host:
$ ansible-playbook -i inventory.ini ... | grep msg
"msg": "MemMax=15G  MemHigh=14G  CPUQuota=400%"
```

`make health` post-apply renders:

```
Resource Slice          ✓ OK     31G limit (50% of host), 0.0G used
Slice CPU Quota         ✓ OK     700% of one CPU (50% of host)
```

# File structure — annotated tree

Every file and directory in the repo, with its purpose, owner tier,
and "when you'd touch it". Sorted by directory.

---

## Root

| Path | Purpose | Owner tier | Touch when |
|---|---|---|---|
| `README.md` | 5-step quickstart + Makefile map | T1 | Restructuring the entry doc |
| `CHANGELOG.md` | SemVer log per tier release | T8 | Cutting a new release |
| `LICENSE` | Apache 2.0 | T6 | Never |
| `Makefile` | 60+ targets — single entry point | T1 | Adding a Tier or capability |
| `.envrc` | direnv per-project env (KUBECONFIG, sccache, ...) | T3 | Adding env vars |
| `.envrc.template` | Same, distributable as a template | T3 | Mirroring `.envrc` |
| `.gitignore` | runtime + editor noise | T1 | Adding new build artefacts |
| `.pre-commit-config.yaml` | Local lint gate | T7 | Adding a hook |
| `.sops.yaml.template` | sops encryption rules template | T7 | Project teams customise |

---

## `.github/`

| Path | Workflow | Trigger | What it does |
|---|---|---|---|
| `.github/workflows/lint.yml` | lint | PR + push main | ansible-lint + shellcheck + yamllint |
| `.github/workflows/trivy.yml` | trivy | PR + push + weekly Mon | fs/config scan + SARIF + SBOM artifact |
| `.github/workflows/kube-bench.yml` | kube-bench | weekly + kind/ changes | Spins Kind on runner, fails if FAIL count > 5 |
| `.github/workflows/smoke.yml` | smoke | weekly + ansible/kind/scripts/Makefile | E2E: validate → kind-up → Cilium → nginx canary |
| `.github/workflows/release.yml` | release | tag `v*` push | Extracts CHANGELOG entry, generates SBOM, creates GitHub Release |
| `.github/renovate.json5` | Renovate config | (Renovate App) | Weekly Sun PRs for version pin bumps |

---

## `.devcontainer/`

| Path | Purpose |
|---|---|
| `.devcontainer/devcontainer.json` | VS Code / Codespaces config — Ubuntu 24.04 base + 7 extensions |
| `.devcontainer/post-create.sh` | Installs ansible-lint, yamllint, shellcheck, pre-commit |

⚠ The devcontainer can **lint** but cannot run `make setup` (needs host systemd).

---

## `ansible/`

### `ansible/ansible.cfg`

Ansible runtime config: `inventory.ini`, fact cache, retry off, `interpreter_python=/usr/bin/python3`.

### `ansible/inventory.ini`

Inventory + **all pinned versions** (`docker_version_pin`, `kind_version`, `kubectl_version`, ...). **Single source of truth for tool versions.** When Renovate proposes a bump, the PR edits this file.

### `ansible/setup.yml`

Master playbook. Pre-tasks: assert OS = Ubuntu/Zorin 24+, assert cgroup v2, assert ≥ 50 GB free. Roles applied in order: system_tuning → resource_slicing → docker_engine → kind_tools → rust_toolchain → dev_tools. Opt-in roles (kvm_host, wireguard) tagged `never`.

### `ansible/roles/<role>/`

Each role has:
- `tasks/main.yml` — the actual work, ~150 LOC each
- `handlers/main.yml` — restart/reload triggers
- `defaults/main.yml` — variable defaults (empty when all come from inventory.ini)
- `templates/` — Jinja templates (only `wireguard/templates/wg.conf.j2` so far)

#### `system_tuning/`

Writes `/etc/sysctl.d/99-ngolacloud-dev.conf` (swappiness, inotify, bridge-nf, dirty pages, file descriptors, max_map_count), `/etc/modules-load.d/ngolacloud-dev.conf` (br_netfilter, overlay), `/etc/udev/rules.d/60-ioschedulers.rules` (per device type), updates `/etc/default/grub` (transparent_hugepage=madvise, cgroup_enable=memory, swapaccount=1), creates `/swapfile` (16 GB) + `/etc/fstab` entry.

#### `resource_slicing/`

Writes `/etc/systemd/system/ngolacloud-dev.slice` (MemoryMax=32G, MemoryHigh=28G, CPUWeight=75, TasksMax=8192) + `/etc/systemd/system/docker.service.d/slice.conf`.

#### `docker_engine/`

Detects + refuses Snap Docker. Adds the official Docker apt repo + GPG key. Installs `docker-ce={pinned_version}` + containerd.io + buildx + compose plugin. Writes `/etc/docker/daemon.json` (overlay2, systemd cgroup, ipv6 off, log rotation, address-pool 172.30.0.0/16, BuildKit, live-restore). Adds the invoking user to the `docker` group.

#### `kind_tools/`

Downloads + sha256-verifies each of: kind, kubectl, helm, kustomize, k9s, stern from upstream releases. Installs to `/usr/local/bin/`. Idempotent: skips download if `--version` already matches the pin. Also installs krew user-scoped (`~/.krew/bin/`).

#### `rust_toolchain/`

Installs rustup user-scoped (no PATH modification), pins stable toolchain, adds components (rustfmt, clippy, rust-analyzer, rust-src). Installs sccache from GitHub release + mold from apt. Writes `~/.cargo/config.toml` wiring sccache as rustc-wrapper + mold as linker.

#### `dev_tools/`

apt-installs direnv, fzf, ripgrep, bat (symlinked from batcat), jq, btop. Downloads eza, yq, sops, vault, age. Adds the direnv hook to `/etc/bash.bashrc`.

#### `kvm_host/` (opt-in)

Refuses to install if BIOS virt flags (vmx/svm) absent. apt installs qemu-kvm, libvirt-daemon-system, virt-install, bridge-utils, cpu-checker, cloud-image-utils. Adds user to libvirt + kvm groups. Ensures default libvirt network is autostart + active.

#### `wireguard/` (opt-in)

apt installs wireguard + wireguard-tools. Generates a private key (idempotent — never regenerates). Renders `/etc/wireguard/<iface>.conf` via `templates/wg.conf.j2` using inventory vars. Enables `wg-quick@<iface>` systemd unit.

#### Per-role `molecule/`

`system_tuning`, `resource_slicing`, `docker_engine` have molecule scenarios:
- `molecule/default/molecule.yml` — docker driver, Ubuntu 24.04 privileged container
- `molecule/default/converge.yml` — applies the role under test
- `molecule/default/tests/test_default.py` — testinfra assertions
- `molecule/default/README.md` (system_tuning only) — pattern for replicating

---

## `kind/`

| Path | Purpose |
|---|---|
| `kind/cluster-dev.yaml` | Kind cluster config: 1 CP + 3 workers, `disableDefaultCNI: true`, `kubeProxyMode: none`, podCIDR 10.244.0.0/16, extraPortMappings 80/443/3000 |
| `kind/cilium-values.yaml` | Cilium Helm values: tunnel VXLAN, hubble enabled, kubeProxyReplacement, `bpf.hostLegacyRouting=true` (Kind compat) |
| `kind/observability-values.yaml` | kube-prom-stack values: 1 replica, 24h retention, NodePort 30030, 6 Grafana dashboards pre-installed (cluster, pods, node-exporter, Cilium, Loki Quick, Falco events) |

---

## `kvm/` (Tier 5)

| Path | Purpose |
|---|---|
| `kvm/staging-cluster.toml` | Sample `.ngolacloud.toml` for the nested cluster (1 CP + 2 workers = 16 GB) |
| `kvm/cloud-init-user-data.yml.template` | Cloud-init user-data: kubeadm prereqs (swapoff, br_netfilter, containerd SystemdCgroup=true) |

---

## `k8s/` (Tier 8-11)

### `k8s/policies/kyverno/` (Tier 8)

| Path | Policy | Severity |
|---|---|---|
| `00-disallow-privileged.yaml` | PSS Baseline — no privileged containers | HIGH |
| `01-disallow-run-as-root.yaml` | PSS Restricted — runAsNonRoot | MEDIUM |
| `02-require-resource-limits.yaml` | Capacity hygiene — CPU+memory limits required | HIGH (laptop-tightened) |
| `03-require-image-tag-not-latest.yaml` | Reproducibility — no `:latest` | MEDIUM |

### `k8s/supply-chain/` (Tier 10-11)

| Path | Purpose |
|---|---|
| `verify-images-policy.yaml` | Kyverno verifyImages — Cosign keyless signature required (SLSA L2) |
| `verify-images-slsa-policy.yaml` | Stricter — also requires `slsaprovenance` attestation (SLSA L3) |

### `k8s/security/` (Tier 9)

| Path | Purpose |
|---|---|
| `trivy-operator-values.yaml` | Trivy Operator Helm values — HIGH+ severity, 5 GB cache |
| `kube-bench.yaml` | One-shot Job manifest for CIS Benchmark |
| `falco-values.yaml` | Falco Helm values — modern_ebpf + custom rule (netcat listener) + Loki sink |
| `opencost-values.yaml` | opencost Helm values — pricing model in AOA |

### `k8s/secrets/` (Tier 11)

| Path | Purpose |
|---|---|
| `vault-secretstore.yaml` | ClusterSecretStore pointing at the Vault dev service |
| `sample-externalsecret.yaml` | Demonstrates Vault → K8s Secret sync |

### `k8s/chaos/` (Tier 11)

| Path | Experiment | Effect |
|---|---|---|
| `01-pod-kill.yaml` | PodChaos | Kill 1 random pod every 5 min |
| `02-network-partition.yaml` | NetworkChaos | 50% packet loss for 60s |
| `03-cpu-stress.yaml` | StressChaos | Peg 1 vCPU at 80% for 60s |

### `k8s/flux/` (Tier 8)

| Path | Purpose |
|---|---|
| `sample-gitrepository.yaml` | Sample GitRepository pointing at this repo |
| `sample-kustomization.yaml` | Sample Kustomization reconciling `k8s/policies/kyverno/` |

### `k8s/portal-chart/` (Tier 14)

Reference Helm chart that any NgolaCloud app inherits.

| Path | Purpose |
|---|---|
| `Chart.yaml` | Metadata |
| `values.yaml` | Defaults — PSS-compliant securityContext, resource limits, ServiceMonitor, ExternalSecret block |
| `templates/_helpers.tpl` | Standard label set + naming helpers |
| `templates/deployment.yaml` | Deployment with checksum/config annotation |
| `templates/service.yaml` | ClusterIP Service |
| `templates/ingress.yaml` | Ingress (gated by `.Values.ingress.enabled`) |
| `templates/hpa.yaml` | HPA (gated by `.Values.autoscaling.enabled`) |
| `templates/servicemonitor.yaml` | Auto-discovered by kube-prom-stack |
| `templates/externalsecret.yaml` | ESO ExternalSecret (gated by `.Values.externalSecrets.enabled`) |
| `README.md` | When to use as-is vs fork into app repo |

---

## `scripts/`

| Path | Purpose | Help flag |
|---|---|---|
| `scripts/_common.sh` | Shared helpers: coloured logging, ensure_bin, wait_for, repo paths | (sourced) |
| `scripts/validate-host.sh` | 10-check preflight, no sudo | yes |
| `scripts/onboard.sh` | 7-phase one-shot bootstrap | yes |
| `scripts/health-check.sh` | 8-row status table | (no flags) |
| `scripts/benchmark.sh` | Timings: docker pull, kind, kubectl, deploy | `--json` |
| `scripts/kind-up.sh` | Kind cluster + Cilium + metrics-server | `--recreate`, `--no-cilium`, `--with-observability` |
| `scripts/kind-down.sh` | Delete cluster + prune | `--prune-volumes` |
| `scripts/kind-load-image.sh` | Build + load image into Kind | `--build <dir>` |
| `scripts/kyverno-install.sh` | Helm + 4 policies | `--enforce`, `--uninstall` |
| `scripts/dr-drill.sh` | etcd snapshot/restore drill | `snapshot`, `list`, `restore`, `full` |
| `scripts/flux-install.sh` | Flux v2 install | `--bare`, `--sample`, `--uninstall` |
| `scripts/security-scan.sh` | Trivy + kube-bench + aggregator | `trivy`, `bench`, `report`, `uninstall` |
| `scripts/falco-install.sh` | Falco install + test | `--test`, `--tail`, `--uninstall` |
| `scripts/opencost-install.sh` | opencost install + report + UI | `--report`, `--ui`, `--uninstall` |
| `scripts/cosign-setup.sh` | Cosign + verifyImages | `install`, `keygen`, `sign`, `verify`, `attest`, `verify-attest`, `apply-policy`, `apply-policy-slsa`, `remove-policy` |
| `scripts/eso-install.sh` | ESO + optional Vault dev | `--with-vault`, `--demo`, `--uninstall` |
| `scripts/chaos-install.sh` | chaos-mesh + 3 experiments | `--apply`, `--target`, `--status`, `--uninstall` |

---

## `docs/`

| Path | Audience | When to read |
|---|---|---|
| `docs/onboarding.md` | New dev | Day 1 |
| `docs/commands-reference.md` | Anyone | "What does `make X` do?" |
| `docs/file-structure.md` | Anyone (this file) | "Where does X live?" |
| `docs/ecosystem.md` | Architect | "How do all NgolaCloud repos fit?" |
| `docs/integration-with-ngolacloud-portal.md` | App dev | Wiring the Django portal |
| `docs/integration-with-ngolacloud-cli.md` | CLI dev | Building/running the Rust CLI |
| `docs/divergence-from-prod.md` | SRE | "What does Kind not validate?" |
| `docs/troubleshooting.md` | Anyone | Top 10 failures |
| `docs/adr/0001-kind-over-minikube-and-k3d.md` | Architect | Why kind |
| `docs/adr/0002-cilium-replaces-kindnet.md` | Architect | Why Cilium |
| `docs/adr/0003-32gb-systemd-slice-budget.md` | Architect | Why 32G slice |
| `docs/adr/0004-nested-kvm-staging.md` | Architect | Why nested KVM |
| `docs/adr/0005-mold-as-default-rust-linker.md` | Rust dev | Why mold |
| `docs/adr/0006-sops-age-for-repo-secrets.md` | Anyone | Why sops + age |
| `docs/adr/0007-flux-for-cluster-state.md` | Platform | Why Flux over ArgoCD |
| `docs/adr/0008-security-baseline-defence-in-depth.md` | SecOps | The 4-layer security stack |
| `docs/adr/0009-supply-chain-trust.md` | SecOps | Cosign + Trivy + verifyImages |
| `docs/adr/0010-resilience-secret-sync-slsa-l3.md` | SecOps | chaos-mesh + ESO + SLSA L3 |
| `docs/adr/0011-lab-app-boundary.md` | Architect | Reference chart + Molecule pattern |

---

## File count by tier (rough)

| Tier | Files added | Cumulative |
|---|---|---|
| 0-4 | 38 | 38 |
| 5 | 5 | 43 |
| 6 | 7 | 50 |
| 7 | 5 | 55 |
| 8 | 11 | 66 |
| 9 | 9 | 75 |
| 10 | 4 | 79 |
| 11 | 11 | 90 |
| 12 | 4 | 94 |
| 13 (docs) | 3 | 97 |
| 14 | 14 | 111 |
| 15 (this) | 4 | 115 |

Touch-frequency map:
- **Most touched** when adapting to a new env: `inventory.ini`, `kind/cluster-dev.yaml`, the relevant Ansible role
- **Most touched** when scaling features: `Makefile`, `k8s/<concern>/`, a new ADR
- **Rarely touched**: `LICENSE`, `ansible/ansible.cfg`, `scripts/_common.sh`

# Commands reference

Exhaustive index of every `make` target + every shell script. Searchable.
Each entry: what it does, when to use, prereqs, exit codes.

---

## Top-level orchestration

### `make onboard` / `make onboard-yes`

One-shot bootstrap: preflight → setup → reboot (if needed) → kind-up → benchmark → open Grafana.

- Prompts on each destructive phase; `--yes` flag skips all prompts (CI mode).
- Phase 5 (kind-up) gates on `helm`/`kubectl`/`kind` presence; aborts with exit 3 if missing.
- Use `--no-reboot` to skip the GRUB reboot prompt.
- Use `--no-obs` to skip the observability stack.

### `make validate`

Preflight without sudo, without writes. Exit 0 = ready, 1 = warn, 2 = abort.

Checks: OS, kernel, cgroup v2, CPU cores, RAM, disk, FS type, Snap Docker absence, sudo NOPASSWD, internet, ansible, CPU virt flags.

### `make health`

8-row colour table of lab state. Exit 1 if any check fails.

### `make help`

Print every documented Make target with one-liners.

### `make version`

Print versions of ansible, docker, kind, kubectl.

---

## Ansible setup (Tier 1)

### `make setup`

Apply the full playbook (~10 min first run). Idempotent.

Variables:
- `TAGS=foo,bar` — apply only tasks with those tags
- `VERBOSE=-vv` (or `-vvv`) — extra ansible output

Tag inventory:
| Tag | Scope |
|---|---|
| `system, tuning, sysctl, grub, swap, io, verify` | Tier 1 host (system_tuning role) |
| `slice, systemd` | Tier 1 slice (resource_slicing role) |
| `docker, daemon` | Tier 1 Docker (docker_engine role) |
| `kind, k8s` | Tier 2 K8s tooling |
| `rust` | Tier 3 Rust toolchain |
| `tools, dev, secrets` | Tier 3 dev tools (incl. sops/age/vault CLI) |
| `kvm` | Tier 5 libvirt — opt-in (tagged `never`) |
| `wireguard` | Tier 6 — opt-in |

### `make setup-check` / `make setup-diff`

Dry-run (`--check --diff`) — shows what would change without touching anything.

---

## Cluster lifecycle (Tier 2 + 7)

### `make kind-up` / `make kind-up-recreate`

Create the `ngolacloud-dev` Kind cluster (1 CP + 3 workers) + install Cilium + metrics-server. Use `make kind-up WITH_OBS=1` to also install kube-prometheus-stack + Loki.

`--recreate` (= `make kind-up-recreate`) destroys the existing cluster first.

Phases:
1. Pre-flight (tools, no collision)
2. `kind create cluster --config kind/cluster-dev.yaml`
3. Helm install Cilium
4. Wait for 4 nodes Ready + Cilium pods Running
5. metrics-server install

### `make kind-down` / `make kind-down-deep`

Delete the cluster + docker prune. `-deep` also deletes unattached Docker volumes (DATA LOSS).

### `make kind-reset`

Equivalent to `kind-down && kind-up`. Use when the cluster is in a weird state.

### `make kind-load TAG=<image>`

Build (optional `--build <dir>`) + load image into Kind nodes. Without this, pods reference the image but workers can't see it (`ErrImagePull` despite local presence).

---

## Lint + tests

### `make lint`

Runs all three locally (mirrors `.github/workflows/lint.yml`):
- `ansible-lint --offline` over playbook + roles
- `shellcheck -x` over scripts/*.sh
- `yamllint` over ansible/ + kind/ + kvm/

### `make lint-ansible` / `make lint-shell` / `make lint-yaml`

Individual linters. Each requires its tool installed (warns and exits if missing).

### `make molecule-test`

Run molecule lifecycle for the `system_tuning` role (Docker driver). Install via pipx (Ubuntu 24.04 enforces PEP 668): `sudo apt install -y pipx && pipx ensurepath && pipx install 'molecule[docker]'`.

### `make bench`

Run `scripts/benchmark.sh` — measures docker pull, kind up, kubectl latency, nginx deploy. Append `--json` flag manually via `scripts/benchmark.sh --json`.

---

## Disk + cleanup

### `make prune`

Safe Docker prune: containers + dangling images + networks + builder cache. Keeps volumes.

### `make prune-aggressive`

Also prunes Docker volumes (DATA LOSS — confirm before).

### `make uninstall`

Two-stage:
1. `uninstall-cluster` — removes all Tier 7-11 stacks (chaos/eso/falco/trivy/kyverno/cosign-policy/opencost/flux) idempotently.
2. `uninstall-host` — removes slice + sysctl override + udev rule + docker drop-in. Keeps GRUB + swap (manual reversal documented).

### `make reboot-if-needed`

Reboots only if `/var/run/reboot-required` exists (after GRUB change). 5-second countdown.

---

## Tier 5 — nested KVM staging

### `make staging-up`

Spins up the 3-VM staging cluster via `ngolacloud infra apply -f kvm/staging-cluster.toml`. Requires the `kvm_host` role applied (`make setup TAGS=kvm`).

### `make staging-down`

Tears down the staging cluster via the CLI.

### `make wireguard-up`

Install + start the WireGuard tunnel. Configure via `inventory.ini` (`wg_remote_endpoint`, `wg_remote_pubkey`, ...). Opt-in (tag `never` in setup.yml).

---

## Tier 8 — GitOps, policies, DR

### `make kyverno-install` / `make kyverno-enforce` / `make kyverno-uninstall`

Install Kyverno + 4 baseline policies in Audit mode. `kyverno-enforce` patches all ClusterPolicies to Enforce. Verify with `kubectl get policyreports -A`.

### `make dr-snapshot` / `make dr-restore` / `make dr-drill`

- `dr-snapshot` — take an etcd snapshot to `/tmp/ngc-dr/etcd-<ts>.db`
- `dr-restore FILE=...` — restore from a specific snapshot
- `dr-drill` — full lifecycle: snapshot → sandbox ConfigMap → restore → verify

### `make flux-install` / `make flux-install-sample` / `make flux-uninstall`

- `flux-install` — Flux v2 controllers only (no reconciler)
- `flux-install-sample` — install + apply sample GitRepository + Kustomization pointing at this repo

---

## Tier 9 — security stack

### `make trivy-install` / `make kube-bench` / `make security-report` / `make security-uninstall`

- `trivy-install` — Helm install trivy-operator (continuous CVE + config scans)
- `kube-bench` — run one-shot CIS Benchmark Job; prints output
- `security-report` — aggregate Kyverno + Trivy + kube-bench findings into one summary
- `security-uninstall` — remove trivy + security namespace

### `make falco-install` / `make falco-test` / `make falco-tail` / `make falco-uninstall`

- `falco-install` — Helm install Falco with modern_ebpf driver
- `falco-test` — spawn a netcat-listener pod to trigger the custom rule
- `falco-tail` — tail Falco alerts (Ctrl+C to stop)

### `make opencost-install` / `make opencost-report` / `make opencost-ui` / `make opencost-uninstall`

- `opencost-install` — Helm install opencost (requires kube-prom-stack)
- `opencost-report` — print per-namespace cost summary (last 24h) in AOA
- `opencost-ui` — port-forward UI to http://localhost:9090

### `make security-stack`

Meta-target: installs `kyverno-install` + `trivy-install` + `falco-install` + `opencost-install` in sequence.

---

## Tier 10 — supply chain

### `make cosign-install` / `make cosign-keygen`

- `cosign-install` — install cosign CLI v2.4.1
- `cosign-keygen` — generate key-pair in `~/.config/cosign/`

### `make cosign-sign IMAGE=<ref>` / `make cosign-verify IMAGE=<ref>`

Keyless sign (OIDC prompt) / verify (auto-detects keyless or key-based).

### `make cosign-attest IMAGE=... PREDICATE=slsa.json` / `make cosign-verify-attest IMAGE=...`

Attach / verify a SLSA provenance attestation (Tier 11 SLSA L3).

### `make cosign-policy-apply` / `make cosign-policy-slsa` / `make cosign-policy-remove`

Apply the Kyverno `verifyImages` ClusterPolicy (signature-only L2 or signature+attestation L3).

### `make supply-chain-stack`

Meta-target: `cosign-install` + `cosign-policy-apply`.

---

## Tier 11 — resilience

### `make eso-install` / `make eso-with-vault` / `make eso-demo` / `make eso-uninstall`

- `eso-install` — Helm install External Secrets Operator
- `eso-with-vault` — also installs Vault dev mode + sample wiring (UNLOCKED — DEV ONLY)
- `eso-demo` — wait for ESO to sync the sample ExternalSecret and print decoded values

### `make chaos-install` / `make chaos-apply` / `make chaos-target` / `make chaos-status` / `make chaos-uninstall`

- `chaos-install` — Helm install chaos-mesh
- `chaos-apply` — also apply 3 baseline experiments (pod-kill, network-loss, cpu-stress)
- `chaos-target` — create sample `chaos-target/chaos-canary` nginx with opt-in label

### `make resilience-stack`

Meta-target: `eso-with-vault` + `chaos-apply`.

---

## Scripts (`scripts/`)

Every script has a `--help` flag. Sourced via `scripts/_common.sh` for shared helpers (coloured logging, ensure_bin, wait_for).

### `validate-host.sh`

10 preflight checks. Exit 0/1/2 (ready/warn/fail). No sudo, no writes.

### `onboard.sh [--yes] [--no-reboot] [--no-obs]`

7-phase orchestrator (preflight → sudo → setup → reboot → kind-up → bench → open Grafana). Sudo keepalive runs in background.

### `kind-up.sh [--recreate] [--no-cilium] [--with-observability]`

5-phase Kind+Cilium+metrics-server bootstrap. Optionally also kube-prom + Loki.

### `kind-down.sh [--prune-volumes]`

Delete cluster + docker prune. `--prune-volumes` is destructive.

### `kind-load-image.sh <tag>` / `kind-load-image.sh --build <dir> <tag>`

Load (or build + load) an image into the Kind nodes.

### `health-check.sh`

Print the 8-row health table. Used by `make health`.

### `benchmark.sh [--json]`

Time docker pull, kind, kubectl, deploy. Default human-readable; `--json` for diffing across runs.

### `kyverno-install.sh [--enforce | --uninstall]`

Helm install Kyverno + apply 4 policies. `--enforce` patches all to Enforce. `--uninstall` removes everything.

### `dr-drill.sh <snapshot | list | restore <file> | full>`

DR drill subcommands. Operates on the kind control-plane container.

### `flux-install.sh [--bare | --sample | --uninstall]`

Bare = controllers only. Sample = also applies sample reconciler manifests.

### `security-scan.sh <trivy | bench | report | uninstall>`

Multi-purpose security stack entry point.

### `falco-install.sh [--test | --tail | --uninstall]`

Install Falco. `--test` triggers the custom "netcat listener" rule.

### `opencost-install.sh [--report | --ui | --uninstall]`

Install opencost. `--report` queries the API for a JSON breakdown.

### `cosign-setup.sh <install | keygen | sign | sign-key | verify | attest | verify-attest | apply-policy | apply-policy-slsa | remove-policy>`

Cosign + Kyverno verifyImages all-in-one.

### `eso-install.sh [--with-vault | --demo | --uninstall]`

External Secrets Operator + optional Vault dev mode + demo of sync.

### `chaos-install.sh [--apply | --target | --status | --uninstall]`

chaos-mesh + 3 experiments + sample target deployment.

---

## Exit code conventions

Across scripts:
- `0` — success
- `1` — soft failure (warn, retry-able)
- `2` — usage error / preflight hard fail
- `3` — missing dependency

The Ansible playbook fails on any task error (no `ignore_errors`).

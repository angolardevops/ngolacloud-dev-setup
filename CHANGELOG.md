# Changelog

All notable changes to `ngolacloud-dev-setup` are documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [SemVer 2.0](https://semver.org/spec/v2.0.0.html).

The minor version is bumped on:
- New role added
- New top-level Makefile target
- New `kind/` or `kvm/` config file added or restructured

The patch version is bumped on:
- Bug fixes in existing roles / scripts
- Documentation updates that don't change behaviour
- Version pin updates (kind, kubectl, helm, Cilium, Kyverno, ...)

The major version is bumped on:
- Breaking changes to the `make setup` contract
- Removed roles / scripts
- Switch of default CNI / observability stack / GitOps controller

## [Unreleased]

## [1.2.4] — 2026-05-20  — Patch: Zorin preflight + dry-run cleanliness

### Fixed
- **Preflight `refuse non-Ubuntu/Zorin`** rejected the very system the
  playbook is built for. `ansible_distribution` on Zorin OS 18 is
  `"Zorin OS"` (with the trailing `OS`), not `"Zorin"`, and the
  vendor's own `VERSION_ID` is `18`, not `24`. Assertion now gates on
  the Ubuntu base codename (`ansible_distribution_release`) — same
  field `scripts/validate-host.sh` already uses — accepting
  `Ubuntu` or `Zorin OS` whose release is in
  `[noble, oracular, plucky, questing]`.
- **Disk preflight in `--check` mode** showed *"Currently  GB"*
  (empty stdout). The `df` shell task is now `check_mode: false`
  (it's pure-read) so the assertion always has a value to compare.

### Changed
- `make setup-check` and `make setup-diff` now pass `--skip-tags verify`.
  Role-level `Verify` tasks read post-apply state — meaningless in
  dry-run because nothing was actually applied. They still run in real
  `make setup`.

## [1.2.3] — 2026-05-20  — Patch: setup playbook + collection pins

### Fixed
- **Makefile `INVENTORY` path** — was `ansible/inventory.ini` but every
  ansible-* target does `cd ansible/` first, resolving the final path
  to `ansible/ansible/inventory.ini` (a non-existent file). The play
  silently fell back to `implicit localhost`, then warned
  *"Could not match supplied host pattern, ignoring: ngolacloud_dev"*
  and exited 0 with **zero tasks executed** — exactly what was hiding
  the `resource_slice not configured` and `no swap configured` gaps
  in `make health` after a clean `make setup`. The inventory is now
  relative to `ANSIBLE_DIR`.

### Added
- **`ansible/requirements.yml`** with pinned collections:
    * `community.general >=10.0.0,<11.0.0` (last line to support
      ansible-core 2.16 shipped by apt on Ubuntu 24.04 / Zorin 18)
    * `ansible.posix >=1.5.0,<2.0.0`
  Without pins, `ansible-galaxy collection install community.general`
  pulls 11.x which warns *"Collection community.general does not
  support Ansible version 2.16.3"* and refuses to load on apt-Ansible.

### Changed
- `make bootstrap-dev` step [4/5] now runs
  `ansible-galaxy collection install -r ansible/requirements.yml --force`
  instead of the unpinned form.

## [1.2.2] — 2026-05-20  — Patch: pre-commit + mise broken-venv guard

### Fixed
- `.pre-commit-config.yaml` now pins `language_version: python3.12`
  on **every** hook. `default_language_version` at the top is only
  honoured for hooks that don't pin their own — and ansible-lint
  requested generic `python3`, which `pre-commit` resolves to the
  highest interpreter in `PATH`. On a workstation with **mise**
  managing Python, that means `~/.local/bin/python3.14` (the latest
  shim), whose venvs are broken (`ModuleNotFoundError: No module
  named 'encodings'`) — they import the system `encodings` module
  but the shim doesn't ship one. `/usr/bin/python3.12` (apt) has a
  complete stdlib and produces working venvs, so we force it
  per-hook with a 12-line explanatory comment block.

### Notes
- If you hit the broken venv before the fix, clear the
  `~/.cache/pre-commit/` dir (`rm -rf ~/.cache/pre-commit/`) and
  re-run `pre-commit install --install-hooks`. The zombie
  `py_env-python3.14` will not be regenerated.

## [1.2.1] — 2026-05-20  — Patch: bootstrap-dev + valid pre-commit pins

### Fixed
- `.pre-commit-config.yaml` pinned ansible-lint v25.10.0 (didn't
  exist — speculative pin). Refreshed every hook against
  `git ls-remote --tags`:
    * `pre-commit-hooks` v5.0.0 → **v6.0.0**
    * `shellcheck-py` v0.10.0.1 → **v0.11.0.1**
    * `yamllint` v1.37.0 → **v1.38.0**
    * `ansible-lint` v25.10.0 → **v26.4.0**
    * `markdownlint-cli` v0.43.0 → **v0.48.0**

### Added
- **`make bootstrap-dev`** — one-shot idempotent client setup. Five
  phases (apt, pipx ensurepath, pipx install Python CLIs, ansible-
  galaxy collections, pre-commit + direnv hooks). Detects what's
  already installed and skips.
- `make pre-commit-update` — `pre-commit autoupdate` wrapper.
- `make direnv-allow` — alias for `direnv allow .` after `.envrc` edits.
- `$(DIM)` colour helper in Makefile for muted text.

### Changed
- README quickstart now shows the 2-step path: `make bootstrap-dev`
  (one-time per laptop) → `make onboard` (full lab).

## [1.2.0] — 2026-05-19  — Tier 15 (onboarding docs + interactive HTML + skills)

### Added
- **Master onboarding guide** (`docs/onboarding.md`) — 10-section
  guide from prerequisites to first PR. Covers integration with
  `ngolacloud-integration` (portal + CLI).
- **Commands reference** (`docs/commands-reference.md`) — exhaustive
  ref for every make target + every shell script (60+ targets, 18
  scripts). Searchable, with examples + exit codes.
- **File-structure tree** (`docs/file-structure.md`) — annotated.
  Every file/dir with purpose + owner tier + touch-when.
- **Interactive HTML** (`doc/ngolacloud-dev.html`) — 42 KB single
  file. Sticky TOC with scroll-spy, copy-to-clipboard, two Mermaid
  diagrams (call graph + ecosystem), NgolaCloud branding. Offline-
  friendly after first paint.
- **5 LLM-invokable skills** under `.claude/skills/`:
    * `pr-workflow/` — branching, PR template, reviewer checklist
    * `semantic-commits/` — Conventional Commits + SemVer + tag flow
    * `pre-commit-bestpractices/` — hook setup, repo-type matrix
    * `solid-cqrs-clean/` — SOLID + CQRS + Clean Arch with worked
      "suspend tenant" example
    * `sre-platform-12factor/` — 12 Factor + SRE + Platform Engineering

### Changed
- README now references the 8 docs + 11 ADRs surface.

## [1.1.0] — 2026-05-19  — Tier 14 (lab→app boundary + role test coverage)

### Added
- **`k8s/portal-chart/`** — reference Helm chart for any NgolaCloud app
  deploying to the dev cluster. 7 templates (Deployment, Service,
  Ingress, HPA, ServiceMonitor, ExternalSecret, _helpers.tpl).
  Default values satisfy:
    * Kyverno PSS Baseline (no privileged, drop ALL caps)
    * Kyverno PSS Restricted (runAsNonRoot, runAsUser=1000)
    * `require-resource-limits` (CPU + memory)
    * kube-prom-stack auto-discovery (ServiceMonitor)
    * ESO sync from Vault (optional, off by default)
  README explains when to fork into the app repo.
- **Molecule scenarios for two more roles**:
    * `ansible/roles/resource_slicing/molecule/` — 9 testinfra
      assertions (slice file content, docker drop-in, MemoryMax via
      systemctl show)
    * `ansible/roles/docker_engine/molecule/` — 12 testinfra assertions
      (apt repo + GPG key, daemon.json structure, slice drop-in,
      Snap Docker pre-flight rejection, 5 required packages)
- ADR-0011: Lab/app boundary + Molecule role coverage pattern.

### Coverage
- Molecule: 3 of 8 roles now have regression coverage
  (system_tuning, resource_slicing, docker_engine).
- Remaining 5 (kind_tools, rust_toolchain, dev_tools, kvm_host,
  wireguard) queued for follow-up PRs — pattern documented.

## [1.0.0] — 2026-05-19  — Tier 12 (consolidation: tests, CI E2E, release automation)

This is the **stabilization release** marking the lab as feature-complete.
No new capabilities vs v0.10.0 — instead, the surrounding scaffolding
to keep the lab working long after the initial author moves on:

### Added
- **Molecule scenario for `system_tuning`**
  (`ansible/roles/system_tuning/molecule/default/`) — reference
  implementation for role-level testing. docker driver, privileged
  Ubuntu 24.04 container, testinfra verifier with 7 test functions
  asserting sysctl/modules/udev/GRUB/swap/fstab/THP end-state.
  `make molecule-test` runs the full lifecycle. README documents how
  to clone the pattern to the other 7 roles.
- **E2E smoke workflow** (`.github/workflows/smoke.yml`) — weekly +
  on path changes. Full happy path on a fresh ubuntu-24.04 runner:
  validate → setup-check → kind-up → Cilium install → nginx canary
  deploy + Service exposure via kube-proxy replacement → health-check.
  Diagnostics dump on failure.
- **Release automation** (`.github/workflows/release.yml`) — tag push
  `v*` → extract CHANGELOG entry → generate fresh SBOM via Trivy →
  source tarball → publish GitHub Release with notes + assets.
  `workflow_dispatch` supports manual re-runs.
- **`make uninstall` revamp** — now composed of two stages:
    * `uninstall-cluster` — removes all Tier 7-11 in-cluster stacks
      (chaos / eso / falco / trivy / kyverno / cosign-policy / opencost
      / flux) idempotently, never fails if a stack wasn't installed
    * `uninstall-host` — removes slice + sysctl override + udev
      rule + docker drop-in (unchanged from v0.10.0). Keeps GRUB +
      swap (documented manual reversal)
- `make molecule-test`, `uninstall-cluster`, `uninstall-host`
  Makefile targets (3 new).

### Known limitations
- Molecule coverage is **1 role of 8** — operator pattern, the rest
  are TODO (each role takes ~30-45 min to wrap)
- Smoke workflow doesn't run `make setup` for real on the runner
  (would need privileged systemd + reboot for GRUB to apply) — only
  `setup-check` + kind-up are exercised
- The release workflow expects CHANGELOG entries in the format
  `## [X.Y.Z] — date — title` (Keep-a-Changelog dialect)

### Migration from v0.10.0
- No breaking changes
- The split `uninstall-cluster` / `uninstall-host` keeps backward
  compatibility — old `make uninstall` still works (now calls both)

## [0.10.0] — 2026-05-19  — Tier 11 (resilience + secret sync + SLSA L3)

### Added
- **External Secrets Operator** (`scripts/eso-install.sh`) — v0.10.4.
  ClusterSecretStore + sample ExternalSecret demonstrating
  Vault → K8s Secret sync. `--with-vault` bootstraps in-cluster
  Vault dev (root token visible — DEV ONLY), enables kubernetes auth
  backend, seeds sample secret. `--demo` shows the synced K8s Secret.
- **chaos-mesh** (`scripts/chaos-install.sh`) — v2.7.0 with three
  baseline experiments (PodChaos, NetworkChaos, StressChaos).
  All scoped to `chaos-target` namespace + opt-in label
  (`chaos.ngolacloud.ao/eligible=true`) — system pods never touched.
- **SLSA L3** via `cosign attest`:
    - `cosign attest <image> <predicate>` attaches provenance
    - `cosign verify-attest` validates
    - `k8s/supply-chain/verify-images-slsa-policy.yaml` Kyverno policy
      requires signature + provenance attestation
- **kube-bench CI drift gate** (`.github/workflows/kube-bench.yml`) —
  weekly + on `kind/` changes. Spins fresh Kind on the runner,
  fails if CIS FAIL count regresses past baseline (MAX_FAILS=5).
- ADR-0010: chaos-mesh + ESO + SLSA L3 rationale + trade-offs.
- 15 new make targets.

### Changed
- `scripts/cosign-setup.sh` gains `attest` / `verify-attest` /
  `apply-policy-slsa` subcommands.

## [0.9.0] — 2026-05-19  — Tier 10 (supply-chain trust)

### Added
- **Cosign** (`scripts/cosign-setup.sh`) — install + keygen + sign
  (keyless default, key-based fallback) + verify (auto-detects mode).
  Targets v2.4.1.
- **Kyverno verifyImages ClusterPolicy**
  (`k8s/supply-chain/verify-images-policy.yaml`) — rejects pods whose
  images lack a Sigstore-verifiable signature from
  `https://github.com/angolardevops/.*`. Audit mode by default; flip
  to Enforce via kubectl patch. Excludes system namespaces.
- **Trivy CI gate** (`.github/workflows/trivy.yml`) — three independent
  scans on every PR + push + weekly: filesystem (secrets + deps),
  config (k8s/Dockerfile/Helm misconfig), SBOM (SPDX 90-day artifact).
  HIGH+ severity blocks merge. SARIF uploaded to GitHub code scanning.
- **Falcosidekick → Loki** — Falco alerts ship to Loki tenant=falco
  alongside stdout. Falco events dashboard (Grafana 11914) auto-installed.
- 7 new `make` targets: `cosign-{install,keygen,sign,verify}`,
  `cosign-policy-{apply,remove}`, `supply-chain-stack`.
- ADR-0009: Supply chain trust — Cosign + Trivy CI + Kyverno
  verifyImages.

### Changed
- `kind/observability-values.yaml` adds Falco events Grafana dashboard
  (gnetId 11914).

## [0.8.0] — 2026-05-19  — Tier 9 (security & cost defence-in-depth)

### Added
- **Trivy Operator** (`scripts/security-scan.sh trivy`) — continuous CVE
  + config audit scans. Reports as CRDs (`VulnerabilityReport`,
  `ConfigAuditReport`, `RbacAssessmentReport`). Severity threshold
  HIGH+ to keep reports lean.
- **kube-bench Job** (`make kube-bench`) — on-demand CIS Kubernetes
  Benchmark scan. TTL 1h so the job auto-cleans.
- **Security report aggregator** (`make security-report`) — aggregates
  Kyverno + Trivy + kube-bench findings into one human summary.
- **Falco** (`scripts/falco-install.sh`) — runtime threat detection via
  modern_ebpf driver (kernel ≥ 5.8 required, Zorin 18 supports).
  Custom rule: "Suspicious netcat listener" flags `nc -lvp …` spawned
  in workload pods. `falco-test` triggers it on demand.
- **opencost** (`scripts/opencost-install.sh`) — cost modelling in AOA
  using a custom pricing config matching the NgolaCloud demo plans
  (250 000 AOA enterprise, 14 800 business, 0 startup). UI port-
  forwarded to `localhost:9090` via `make opencost-ui`.
- `make security-stack` — installs ALL Tier 9 tools at once
  (Kyverno + Trivy + Falco + opencost).
- ADR-0008: Security baseline — defence in depth (4 layers).

## [0.7.0] — 2026-05-19  — Tier 8 (GitOps + policies + DR)

### Added
- **Kyverno** baseline policies (4 ClusterPolicies in Audit mode):
  `disallow-privileged-containers`, `disallow-run-as-root`,
  `require-resource-limits`, `disallow-latest-tag`. Install via
  `scripts/kyverno-install.sh`; flip to Enforce with `--enforce`.
- **DR drill** (`scripts/dr-drill.sh`) — etcd snapshot + restore + verify
  loop validated against the Kind control plane. Use `dr-drill.sh full`
  for a complete drill, `snapshot` / `restore` for individual steps.
- **Flux v2** install (`scripts/flux-install.sh`) — opt-in GitOps with
  source/kustomize/helm/notification controllers. Sample
  `GitRepository` + `Kustomization` in `k8s/flux/`.
- `.github/renovate.json5` — Mend Renovate config with custom regex
  managers for `inventory.ini` version pins.
- `.devcontainer/devcontainer.json` — VS Code / Codespaces ready.
- `CHANGELOG.md` (this file).
- ADR-0007: Flux v2 chosen over ArgoCD.

## [0.6.0] — 2026-05-19  — Tier 7 (operations & onboarding)

### Added
- `.pre-commit-config.yaml` — local lint gate mirroring CI.
- Observability stack in `kind-up.sh --with-observability` — kube-prom-stack
  + Loki via Helm, Grafana exposed on http://localhost:3000.
- `scripts/onboard.sh` + `make onboard` — one-shot from clone to Grafana.
- `scripts/validate-host.sh` + `make validate` — preflight (no sudo).
- `sops` + `age` + `vault` CLI in the `dev_tools` role.
- `.sops.yaml.template` for ngolacloud-* projects.
- ADR-0006: sops + age for repo secrets.

## [0.5.0] — 2026-05-19  — Tier 6 (CI + remote access)

### Added
- `.github/workflows/lint.yml` — ansible-lint + shellcheck + yamllint on
  every PR + push to main.
- `wireguard` role — opt-in tunnel to a remote endpoint.
- `LICENSE` — Apache 2.0.
- ADR-0005: mold as default Rust linker.

## [0.4.0] — 2026-05-19  — Tier 5 (nested KVM staging)

### Added
- `kvm_host` role — libvirt + qemu-kvm + virt-install.
- `kvm/staging-cluster.toml` + `kvm/cloud-init-user-data.yml.template`.
- `make lint` (ansible-lint + shellcheck + yamllint targets).
- ADR-0004: nested KVM staging tier.

## [0.3.0] — 2026-05-19  — Tier 3+4 (toolchains + docs)

### Added
- `rust_toolchain` role (rustup, sccache, mold, cargo config).
- `dev_tools` role (direnv, fzf, rg, bat, eza, yq).
- `scripts/benchmark.sh`.
- `docs/divergence-from-prod.md` + `docs/troubleshooting.md`.
- ADRs 0001-0003.

## [0.2.0] — 2026-05-19  — Tier 2 (Kubernetes tooling)

### Added
- `kind_tools` role — kind/kubectl/helm/kustomize/k9s/krew/stern via
  GitHub releases with sha256 verification.
- `kind/cluster-dev.yaml` (1 CP + 3 workers).
- `kind/cilium-values.yaml`.
- `scripts/kind-up.sh` / `kind-down.sh` / `kind-load-image.sh`.

## [0.1.0] — 2026-05-19  — Tier 0+1 (base setup)

### Added
- Initial scaffold of `ngolacloud-dev-setup/`.
- Three roles: `system_tuning`, `resource_slicing`, `docker_engine`.
- `Makefile` + `scripts/health-check.sh`.
- `ansible/setup.yml` orchestrator.

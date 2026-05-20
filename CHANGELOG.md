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

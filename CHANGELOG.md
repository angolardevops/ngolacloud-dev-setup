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

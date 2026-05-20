# =============================================================================
# ngolacloud-dev-setup — workstation provisioning Makefile
# =============================================================================
# Targets group into four classes:
#   setup-*   : provisioning (Ansible)
#   kind-*    : cluster lifecycle (scripts/, Tier 2)
#   health-*  : diagnostics
#   prune-*   : reclaim disk/RAM
# =============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.ONESHELL:
.DELETE_ON_ERROR:

CYAN  := \033[0;36m
GREEN := \033[0;32m
RED   := \033[0;31m
YEL   := \033[0;33m
DIM   := \033[0;90m
NC    := \033[0m

ANSIBLE_DIR := ansible
PLAYBOOK    := $(ANSIBLE_DIR)/setup.yml
# Path is relative to ANSIBLE_DIR because every ansible-* target cd's in
# first (so ansible.cfg next to it is auto-discovered).
INVENTORY   := inventory.ini
TAGS        ?=
VERBOSE     ?=

# Allow `make setup TAGS=docker,slice  VERBOSE=-vvv`
ANSIBLE_FLAGS := -i $(INVENTORY) $(VERBOSE)
ifneq ($(strip $(TAGS)),)
	ANSIBLE_FLAGS += --tags $(TAGS)
endif

.PHONY: help setup setup-check setup-diff health reboot-if-needed \
        prune prune-aggressive uninstall \
        kind-up kind-up-recreate kind-down kind-down-deep kind-reset kind-load \
        bench version validate onboard onboard-yes \
        lint lint-ansible lint-shell lint-yaml \
        staging-up staging-down \
        wireguard-up \
        kyverno-install kyverno-enforce kyverno-uninstall \
        dr-snapshot dr-restore dr-drill \
        flux-install flux-install-sample flux-uninstall \
        trivy-install kube-bench security-report security-uninstall \
        falco-install falco-test falco-tail falco-uninstall \
        opencost-install opencost-report opencost-ui opencost-uninstall \
        security-stack \
        cosign-install cosign-keygen cosign-sign cosign-verify \
        cosign-policy-apply cosign-policy-remove supply-chain-stack \
        cosign-attest cosign-verify-attest cosign-policy-slsa \
        eso-install eso-with-vault eso-demo eso-uninstall \
        chaos-install chaos-apply chaos-target chaos-status chaos-uninstall \
        resilience-stack \
        uninstall-cluster uninstall-host molecule-test \
        bootstrap-dev pre-commit-update direnv-allow

.DEFAULT_GOAL := help

help: ## Show this help
	@printf "$(CYAN)ngolacloud-dev-setup$(NC) — workstation provisioning\n\n"
	@awk 'BEGIN{FS=":.*?## "}/^[a-zA-Z_-]+:.*?## /{printf "  $(GREEN)%-22s$(NC) %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@printf "\n  Pass $(YEL)TAGS=foo,bar$(NC) to scope a run.\n"
	@printf "  Pass $(YEL)VERBOSE=-vv$(NC) (or -vvv) for debug output.\n\n"

validate: ## Pre-flight check (no sudo, no writes) — run BEFORE `make setup`
	@scripts/validate-host.sh

# ──────────────────────────────────────────────────────────────────────────
# Bootstrap dev environment — single command for a fresh laptop
# ──────────────────────────────────────────────────────────────────────────
bootstrap-dev: ## One-time: apt + pipx + pre-commit + direnv + hooks installed
	@printf "$(CYAN)── bootstrap-dev — preparing a fresh workstation ──$(NC)\n"
	@printf "$(DIM)Idempotent: re-running detects what's already there and skips ahead.$(NC)\n\n"

	@# ── 1) apt packages (need sudo) ─────────────────────────────────
	@printf "$(CYAN)[1/5]$(NC) apt: pipx + direnv + shellcheck + ansible + git\n"
	@sudo apt-get update -qq
	@sudo apt-get install -y -qq \
		pipx \
		direnv \
		shellcheck \
		ansible \
		git \
		curl \
		jq \
		make

	@# ── 2) pipx PATH ─────────────────────────────────────────────────
	@printf "$(CYAN)[2/5]$(NC) pipx ensurepath (idempotent)\n"
	@pipx ensurepath >/dev/null

	@# ── 3) pipx-installed Python CLIs ───────────────────────────────
	@printf "$(CYAN)[3/5]$(NC) pipx install pre-commit + ansible-lint + yamllint\n"
	@for tool in pre-commit ansible-lint yamllint; do \
		if pipx list --short 2>/dev/null | grep -qw $$tool; then \
			printf "  $(GREEN)✓$(NC) $$tool already installed\n"; \
		else \
			pipx install $$tool >/dev/null && printf "  $(GREEN)✓$(NC) $$tool installed\n"; \
		fi; \
	done

	@# ── 4) ansible-galaxy collections (idempotent, version-pinned) ──
	@printf "$(CYAN)[4/5]$(NC) ansible-galaxy: install -r ansible/requirements.yml\n"
	@ansible-galaxy collection install -r ansible/requirements.yml --force >/dev/null 2>&1 \
		&& printf "  $(GREEN)✓$(NC) community.general (<11) + ansible.posix (<2) installed\n"

	@# ── 5) pre-commit + direnv local config ─────────────────────────
	@printf "$(CYAN)[5/5]$(NC) pre-commit install + direnv allow\n"
	@if [ -d .git ]; then \
		~/.local/bin/pre-commit install --install-hooks >/dev/null 2>&1 || pre-commit install --install-hooks; \
		~/.local/bin/pre-commit install --hook-type commit-msg >/dev/null 2>&1 || pre-commit install --hook-type commit-msg; \
		printf "  $(GREEN)✓$(NC) pre-commit hooks installed (pre-commit + commit-msg)\n"; \
	else \
		printf "  $(YEL)!$(NC) skipped pre-commit install (not in a git repo)\n"; \
	fi
	@if [ -f .envrc ]; then \
		direnv allow . >/dev/null 2>&1 && printf "  $(GREEN)✓$(NC) direnv approved .envrc\n" || \
		printf "  $(YEL)!$(NC) direnv allow needs to run inside the dir (try: cd . && direnv allow)\n"; \
	fi

	@printf "\n$(GREEN)bootstrap-dev complete ✓$(NC)\n"
	@printf "  Next:\n"
	@printf "    $(CYAN)source ~/.bashrc$(NC)   (refresh PATH if pipx was just installed)\n"
	@printf "    $(CYAN)make validate$(NC)       (preflight)\n"
	@printf "    $(CYAN)make onboard$(NC)         (full setup → cluster → Grafana)\n"

pre-commit-update: ## Refresh pre-commit hook pins to latest tagged releases
	@command -v pre-commit >/dev/null || { printf "$(YEL)pre-commit missing — run 'make bootstrap-dev' first$(NC)\n"; exit 1; }
	@pre-commit autoupdate
	@printf "$(GREEN)pre-commit pins refreshed. Review .pre-commit-config.yaml diff before committing.$(NC)\n"

direnv-allow: ## Approve the .envrc in this dir (alias for `direnv allow`)
	@command -v direnv >/dev/null || { printf "$(YEL)direnv missing — run 'make bootstrap-dev' first$(NC)\n"; exit 1; }
	@direnv allow .
	@printf "$(GREEN).envrc approved$(NC)\n"

onboard: ## One-shot: preflight + setup + kind-up (+obs) + bench + Grafana
	@scripts/onboard.sh

onboard-yes: ## onboard --yes (unattended; assume Y to all prompts)
	@scripts/onboard.sh --yes

setup: ## Run the full Ansible playbook (host + slice + docker)
	@printf "$(CYAN)── setup ──$(NC)\n"
	cd $(ANSIBLE_DIR) && ansible-playbook setup.yml $(ANSIBLE_FLAGS)

setup-check: ## Dry-run the playbook (--check --diff)
	@# `--check` makes mutating modules pretend; they don't actually
	@# apply state. Subsequent `Verify` tasks (tagged 'verify') then
	@# read the real system back and assert — which fails because the
	@# state was never applied. Skip those asserts in dry-run; the
	@# real `make setup` runs them.
	cd $(ANSIBLE_DIR) && ansible-playbook setup.yml $(ANSIBLE_FLAGS) --check --diff --skip-tags verify

setup-diff: ## Show diff without applying (--check --diff)
	cd $(ANSIBLE_DIR) && ansible-playbook setup.yml $(ANSIBLE_FLAGS) --diff --check --skip-tags verify

health: ## Run scripts/health-check.sh
	@scripts/health-check.sh

reboot-if-needed: ## Reboot only if /var/run/reboot-required exists
	@if [ -f /var/run/reboot-required ]; then \
		printf "$(YEL)Reboot needed — rebooting in 5s. Ctrl+C to abort.$(NC)\n"; \
		sleep 5; sudo reboot; \
	else \
		printf "$(GREEN)No reboot needed.$(NC)\n"; \
	fi

prune: ## docker container/image/network/builder prune (safe — keeps volumes)
	docker container prune -f
	docker image prune -f
	docker network prune -f
	docker builder prune -f
	@df -h / | tail -1

prune-aggressive: ## Add `docker volume prune` (DELETES UNATTACHED VOLUMES — data loss possible!)
	@printf "$(RED)⚠  This will delete unattached Docker volumes. Ctrl+C to abort.$(NC)\n"
	@sleep 5
	docker volume prune -f
	$(MAKE) prune

kind-up: ## Bring up the ngolacloud-dev Kind cluster + Cilium
	@scripts/kind-up.sh

kind-up-recreate: ## kind-up with --recreate (wipes existing cluster)
	@scripts/kind-up.sh --recreate

kind-down: ## Destroy the dev cluster + docker prune
	@scripts/kind-down.sh

kind-down-deep: ## kind-down --prune-volumes (DELETES UNATTACHED VOLUMES)
	@scripts/kind-down.sh --prune-volumes

kind-reset: kind-down kind-up ## Recreate the dev cluster from scratch

kind-load: ## Load a local image into the cluster. Usage: make kind-load TAG=ngolacloud/portal:0.1.0
	@scripts/kind-load-image.sh $(TAG)

bench: ## Run scripts/benchmark.sh (baseline timings)
	@scripts/benchmark.sh

# ──────────────────────────────────────────────────────────────────────────
# Lint — no sudo, no host changes; safe for CI
# ──────────────────────────────────────────────────────────────────────────
lint: lint-ansible lint-shell lint-yaml ## Run all linters (Ansible + shellcheck + yamllint)

lint-ansible: ## ansible-lint over roles + playbook
	@command -v ansible-lint >/dev/null || { printf "$(YEL)ansible-lint missing — pipx install ansible-lint$(NC)\n"; exit 1; }
	@cd $(ANSIBLE_DIR) && ansible-lint --offline setup.yml roles/

lint-shell: ## shellcheck over scripts/*.sh
	@command -v shellcheck >/dev/null || { printf "$(YEL)shellcheck missing — sudo apt install -y shellcheck$(NC)\n"; exit 1; }
	@shellcheck -x scripts/*.sh

lint-yaml: ## yamllint over ansible/ and kind/ + cloud-init
	@command -v yamllint >/dev/null || { printf "$(YEL)yamllint missing — pipx install yamllint$(NC)\n"; exit 1; }
	@yamllint -d '{extends: default, rules: {line-length: {max: 140}, document-start: disable, truthy: {check-keys: false}}}' \
		ansible/ kind/

# ──────────────────────────────────────────────────────────────────────────
# Staging (nested KVM)
# ──────────────────────────────────────────────────────────────────────────
staging-up: ## (placeholder) Spin up the nested KVM staging cluster
	@command -v ngolacloud >/dev/null || { printf "$(RED)ngolacloud CLI not in PATH$(NC)\n"; exit 1; }
	@printf "$(CYAN)Running:$(NC) ngolacloud infra apply -f kvm/staging-cluster.toml\n"
	ngolacloud infra apply -f kvm/staging-cluster.toml

staging-down: ## (placeholder) Tear down the nested KVM staging cluster
	@command -v ngolacloud >/dev/null || { printf "$(RED)ngolacloud CLI not in PATH$(NC)\n"; exit 1; }
	ngolacloud infra destroy -f kvm/staging-cluster.toml

# ──────────────────────────────────────────────────────────────────────────
# WireGuard (opt-in remote tunnel)
# ──────────────────────────────────────────────────────────────────────────
wireguard-up: ## Install + start WireGuard tunnel (configure via inventory.ini)
	cd $(ANSIBLE_DIR) && ansible-playbook setup.yml $(ANSIBLE_FLAGS) --tags wireguard

# ──────────────────────────────────────────────────────────────────────────
# Tier 8 — GitOps / policies / DR
# ──────────────────────────────────────────────────────────────────────────
kyverno-install: ## Install Kyverno + apply baseline policies in Audit mode
	@scripts/kyverno-install.sh

kyverno-enforce: ## Flip all ClusterPolicies from Audit to Enforce
	@scripts/kyverno-install.sh --enforce

kyverno-uninstall: ## Remove Kyverno + all policies
	@scripts/kyverno-install.sh --uninstall

dr-snapshot: ## Take an etcd snapshot to /tmp/ngc-dr/
	@scripts/dr-drill.sh snapshot

dr-restore: ## Restore from snapshot. Usage: make dr-restore FILE=/tmp/ngc-dr/etcd-...db
	@scripts/dr-drill.sh restore $(FILE)

dr-drill: ## Full DR drill: snapshot + sandbox + chaos + restore + verify
	@scripts/dr-drill.sh full

flux-install: ## Install Flux controllers (bare — no sample reconciler)
	@scripts/flux-install.sh --bare

flux-install-sample: ## Install Flux + apply sample GitRepository/Kustomization
	@scripts/flux-install.sh --sample

flux-uninstall: ## Remove Flux entirely
	@scripts/flux-install.sh --uninstall

# ──────────────────────────────────────────────────────────────────────────
# Tier 9 — security & cost (defence-in-depth + cost model)
# ──────────────────────────────────────────────────────────────────────────
trivy-install: ## Install Trivy Operator (continuous CVE + config scan)
	@scripts/security-scan.sh trivy

kube-bench: ## Run kube-bench Job (CIS benchmark) and print output
	@scripts/security-scan.sh bench

security-report: ## Aggregate Kyverno + Trivy + kube-bench findings
	@scripts/security-scan.sh report

security-uninstall: ## Remove Trivy + kube-bench
	@scripts/security-scan.sh uninstall

falco-install: ## Install Falco (modern_ebpf) for runtime threat detection
	@scripts/falco-install.sh

falco-test: ## Trigger the custom "netcat listener" Falco rule
	@scripts/falco-install.sh --test

falco-tail: ## Tail Falco alerts (Ctrl+C to stop)
	@scripts/falco-install.sh --tail

falco-uninstall: ## Remove Falco
	@scripts/falco-install.sh --uninstall

opencost-install: ## Install opencost (cost model in AOA)
	@scripts/opencost-install.sh

opencost-report: ## Print per-namespace cost summary (last 24h)
	@scripts/opencost-install.sh --report

opencost-ui: ## Port-forward the opencost UI to http://localhost:9090
	@scripts/opencost-install.sh --ui

opencost-uninstall: ## Remove opencost
	@scripts/opencost-install.sh --uninstall

security-stack: kyverno-install trivy-install falco-install opencost-install ## Install ALL Tier 9 tools (Kyverno + Trivy + Falco + opencost)

# ──────────────────────────────────────────────────────────────────────────
# Tier 10 — Supply chain (cosign + verifyImages + SBOM)
# ──────────────────────────────────────────────────────────────────────────
cosign-install: ## Install cosign CLI
	@scripts/cosign-setup.sh install

cosign-keygen: ## Generate Cosign key-pair in ~/.config/cosign/
	@scripts/cosign-setup.sh keygen

cosign-sign: ## Sign an image (keyless). Usage: make cosign-sign IMAGE=ghcr.io/foo/bar:1.0
	@scripts/cosign-setup.sh sign $(IMAGE)

cosign-verify: ## Verify an image's signature. Usage: make cosign-verify IMAGE=...
	@scripts/cosign-setup.sh verify $(IMAGE)

cosign-policy-apply: ## kubectl apply the verifyImages ClusterPolicy (Audit mode)
	@scripts/cosign-setup.sh apply-policy

cosign-policy-remove: ## kubectl delete the verifyImages ClusterPolicy
	@scripts/cosign-setup.sh remove-policy

supply-chain-stack: cosign-install cosign-policy-apply ## Install supply-chain trust gate

cosign-attest: ## Attach a SLSA attestation. Usage: make cosign-attest IMAGE=... PREDICATE=slsa.json
	@scripts/cosign-setup.sh attest $(IMAGE) $(PREDICATE)

cosign-verify-attest: ## Verify SLSA attestation. Usage: make cosign-verify-attest IMAGE=...
	@scripts/cosign-setup.sh verify-attest $(IMAGE)

cosign-policy-slsa: ## Apply the SLSA-required verifyImages policy
	@scripts/cosign-setup.sh apply-policy-slsa

# ──────────────────────────────────────────────────────────────────────────
# Tier 11 — resilience + secret sync
# ──────────────────────────────────────────────────────────────────────────
eso-install: ## Install External Secrets Operator
	@scripts/eso-install.sh

eso-with-vault: ## Install ESO + Vault dev + sample wiring
	@scripts/eso-install.sh --with-vault

eso-demo: ## Show the synced K8s Secret value (after eso-with-vault)
	@scripts/eso-install.sh --demo

eso-uninstall: ## Remove ESO + Vault dev
	@scripts/eso-install.sh --uninstall

chaos-install: ## Install chaos-mesh
	@scripts/chaos-install.sh

chaos-apply: ## Install chaos-mesh + apply 3 baseline experiments
	@scripts/chaos-install.sh --apply

chaos-target: ## Create a sample chaos-target/chaos-canary deployment
	@scripts/chaos-install.sh --target

chaos-status: ## Show running chaos experiments + recent events
	@scripts/chaos-install.sh --status

chaos-uninstall: ## Remove chaos-mesh + experiments
	@scripts/chaos-install.sh --uninstall

resilience-stack: eso-with-vault chaos-apply ## Install Tier 11 (ESO + Vault + chaos)

# ──────────────────────────────────────────────────────────────────────────
# Tier 12 — quality (molecule tests; smoke/release run only in CI)
# ──────────────────────────────────────────────────────────────────────────
molecule-test: ## Run molecule tests for the system_tuning role
	@command -v molecule >/dev/null || { printf "$(YEL)molecule missing — sudo apt install -y pipx && pipx ensurepath && pipx install 'molecule[docker]'$(NC)\n"; exit 1; }
	cd ansible/roles/system_tuning && molecule test

uninstall: uninstall-cluster uninstall-host ## Full reversal: cluster stacks then host config

uninstall-cluster: ## Remove every in-cluster opt-in stack (Tier 7-11)
	@printf "$(YEL)── uninstall: cluster stacks ──$(NC)\n"
	-@scripts/chaos-install.sh --uninstall 2>/dev/null || true
	-@scripts/eso-install.sh --uninstall 2>/dev/null || true
	-@scripts/falco-install.sh --uninstall 2>/dev/null || true
	-@scripts/security-scan.sh uninstall 2>/dev/null || true
	-@scripts/opencost-install.sh --uninstall 2>/dev/null || true
	-@scripts/cosign-setup.sh remove-policy 2>/dev/null || true
	-@scripts/kyverno-install.sh --uninstall 2>/dev/null || true
	-@scripts/flux-install.sh --uninstall 2>/dev/null || true
	@printf "$(GREEN)Cluster stacks removed. Kind cluster itself: make kind-down$(NC)\n"

uninstall-host: ## Revert host config (slice + sysctl + udev). GRUB + swap kept.
	@printf "$(RED)── uninstall: host config ──$(NC)\n"
	sudo rm -f /etc/sysctl.d/99-ngolacloud-dev.conf
	sudo rm -f /etc/modules-load.d/ngolacloud-dev.conf
	sudo rm -f /etc/udev/rules.d/60-ioschedulers.rules
	sudo rm -f /etc/systemd/system/ngolacloud-dev.slice
	sudo rm -f /etc/systemd/system/docker.service.d/slice.conf
	sudo systemctl daemon-reload
	sudo systemctl restart docker.service || true
	@printf "$(GREEN)Removed slice + sysctl + udev. Docker daemon.json + GRUB + swap kept.$(NC)\n"
	@printf "  To revert GRUB: edit /etc/default/grub manually then run sudo update-grub\n"
	@printf "  To revert swap: sudo swapoff /swapfile && sudo rm /swapfile && edit /etc/fstab\n"

version: ## Print versions of installed tools
	@printf "$(CYAN)Tool versions$(NC)\n"
	@printf "  ansible : "; ansible --version 2>/dev/null | head -1 || echo MISSING
	@printf "  docker  : "; docker --version 2>/dev/null || echo MISSING
	@printf "  kind    : "; kind --version 2>/dev/null || echo MISSING
	@printf "  kubectl : "; kubectl version --client --output=yaml 2>/dev/null | grep gitVersion | head -1 || echo MISSING

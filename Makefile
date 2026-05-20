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
NC    := \033[0m

ANSIBLE_DIR := ansible
PLAYBOOK    := $(ANSIBLE_DIR)/setup.yml
INVENTORY   := $(ANSIBLE_DIR)/inventory.ini
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
        cosign-policy-apply cosign-policy-remove supply-chain-stack

.DEFAULT_GOAL := help

help: ## Show this help
	@printf "$(CYAN)ngolacloud-dev-setup$(NC) — workstation provisioning\n\n"
	@awk 'BEGIN{FS=":.*?## "}/^[a-zA-Z_-]+:.*?## /{printf "  $(GREEN)%-22s$(NC) %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@printf "\n  Pass $(YEL)TAGS=foo,bar$(NC) to scope a run.\n"
	@printf "  Pass $(YEL)VERBOSE=-vv$(NC) (or -vvv) for debug output.\n\n"

validate: ## Pre-flight check (no sudo, no writes) — run BEFORE `make setup`
	@scripts/validate-host.sh

onboard: ## One-shot: preflight + setup + kind-up (+obs) + bench + Grafana
	@scripts/onboard.sh

onboard-yes: ## onboard --yes (unattended; assume Y to all prompts)
	@scripts/onboard.sh --yes

setup: ## Run the full Ansible playbook (host + slice + docker)
	@printf "$(CYAN)── setup ──$(NC)\n"
	cd $(ANSIBLE_DIR) && ansible-playbook setup.yml $(ANSIBLE_FLAGS)

setup-check: ## Dry-run the playbook (--check --diff)
	cd $(ANSIBLE_DIR) && ansible-playbook setup.yml $(ANSIBLE_FLAGS) --check --diff

setup-diff: ## Show diff without applying (--check --diff)
	cd $(ANSIBLE_DIR) && ansible-playbook setup.yml $(ANSIBLE_FLAGS) --diff --check

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
	@command -v ansible-lint >/dev/null || { printf "$(YEL)ansible-lint missing — pip install ansible-lint$(NC)\n"; exit 1; }
	@cd $(ANSIBLE_DIR) && ansible-lint --offline setup.yml roles/

lint-shell: ## shellcheck over scripts/*.sh
	@command -v shellcheck >/dev/null || { printf "$(YEL)shellcheck missing — apt install shellcheck$(NC)\n"; exit 1; }
	@shellcheck -x scripts/*.sh

lint-yaml: ## yamllint over ansible/ and kind/ + cloud-init
	@command -v yamllint >/dev/null || { printf "$(YEL)yamllint missing — pip install yamllint$(NC)\n"; exit 1; }
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

uninstall: ## Revert as much as possible (slice + sysctl override + daemon.json)
	@printf "$(RED)── uninstall ──$(NC)\n"
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

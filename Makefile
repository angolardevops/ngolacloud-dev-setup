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
        bench version validate \
        lint lint-ansible lint-shell lint-yaml \
        staging-up staging-down \
        wireguard-up

.DEFAULT_GOAL := help

help: ## Show this help
	@printf "$(CYAN)ngolacloud-dev-setup$(NC) — workstation provisioning\n\n"
	@awk 'BEGIN{FS=":.*?## "}/^[a-zA-Z_-]+:.*?## /{printf "  $(GREEN)%-22s$(NC) %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@printf "\n  Pass $(YEL)TAGS=foo,bar$(NC) to scope a run.\n"
	@printf "  Pass $(YEL)VERBOSE=-vv$(NC) (or -vvv) for debug output.\n\n"

validate: ## Pre-flight check (no sudo, no writes) — run BEFORE `make setup`
	@scripts/validate-host.sh

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

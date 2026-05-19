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
        kind-up kind-down kind-reset \
        version

.DEFAULT_GOAL := help

help: ## Show this help
	@printf "$(CYAN)ngolacloud-dev-setup$(NC) — workstation provisioning\n\n"
	@awk 'BEGIN{FS=":.*?## "}/^[a-zA-Z_-]+:.*?## /{printf "  $(GREEN)%-22s$(NC) %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@printf "\n  Pass $(YEL)TAGS=foo,bar$(NC) to scope a run.\n"
	@printf "  Pass $(YEL)VERBOSE=-vv$(NC) (or -vvv) for debug output.\n\n"

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

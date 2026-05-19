# ngolacloud-dev-setup

Provisioning idempotente da workstation (Zorin OS 18 / Ubuntu 24.04, 64 GB RAM)
como ambiente de desenvolvimento `ngolacloud infra dev`. Foco em:

- **Slice de recursos 32 GB** para Kind + Docker (deixa 32 GB para builds Rust,
  IDE, browser, hibernação)
- **Docker Engine** com `daemon.json` operacional (overlay2 + cgroup systemd +
  ipv6 off + log rotation + address pool sem conflitos)
- **Kernel tuning** para Kind (sysctls, GRUB THP=madvise, swap file 16 GB)
- **I/O scheduler** por classe de dispositivo (NVMe none, SSD mq-deadline,
  HDD bfq)

## Quickstart (5 passos)

```bash
# 1. Sanity check da workstation
make help
make health                            # estado actual (antes do setup)

# 2. Dry-run para ver o que mudaria
make setup-check                       # --check --diff (sem mexer)

# 3. Aplicar
make setup                             # ~5-10 min na primeira vez

# 4. Re-boot se GRUB foi alterado (madvise THP)
make reboot-if-needed

# 5. Validar pós-setup
make health                            # deve estar tudo OK
```

## Workflows

```bash
# Stand up the local Kind cluster (3 workers, Cilium, metrics-server)
make kind-up

# Build a portal image and load it into the cluster
make kind-load TAG=ngolacloud/portal:dev

# Tear it down
make kind-down

# Optional: nested KVM staging (Tier 5 — opt-in, ~16 GB RAM)
make setup TAGS=kvm                    # install libvirt + qemu first
make staging-up                        # runs `ngolacloud infra apply -f kvm/...`
make staging-down

# Pre-commit checks (CI-friendly, no sudo)
make lint                              # ansible-lint + shellcheck + yamllint
```

## Layout

```
ngolacloud-dev-setup/
├── Makefile                  # entry point
├── README.md                 # este ficheiro
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.ini         # localhost + versions pinned
│   ├── setup.yml             # orquestrador
│   └── roles/
│       ├── system_tuning/    # sysctl + GRUB + udev + swap
│       ├── resource_slicing/ # ngolacloud-dev.slice
│       ├── docker_engine/    # daemon.json + slice integration
│       ├── kind_tools/       # kind/kubectl/helm/k9s/stern/krew via GitHub releases
│       ├── rust_toolchain/   # rustup + sccache + mold + cargo config
│       ├── dev_tools/        # direnv/fzf/rg/bat/eza/yq
│       └── kvm_host/         # (opt-in TAGS=kvm) libvirt + qemu for Tier 5 staging
├── kind/                     # cluster-dev.yaml + cilium-values.yaml
├── kvm/                      # (opt-in) staging-cluster.toml + cloud-init template
├── scripts/
│   ├── kind-up.sh / kind-down.sh / kind-load-image.sh
│   ├── health-check.sh
│   └── benchmark.sh
└── docs/
    └── adr/                  # decisões arquitecturais
```

## Targets do Makefile

| Target | O que faz |
|---|---|
| `make setup` | Aplica o playbook completo (idempotente) |
| `make setup-check` | Dry-run: mostra diff sem mexer |
| `make setup TAGS=docker` | Aplica só tasks com tag `docker` (tags válidas: `system`, `tuning`, `sysctl`, `grub`, `swap`, `io`, `slice`, `systemd`, `docker`, `daemon`, `verify`) |
| `make health` | Tabela de estado (Docker, slice, Kind, RAM, disco, swap, THP) |
| `make prune` | `docker container/image/network/builder prune` (mantém volumes) |
| `make prune-aggressive` | Apaga também volumes Docker (⚠ perde dados) |
| `make uninstall` | Remove slice + sysctl override + udev. GRUB + swap mantidos |
| `make reboot-if-needed` | Reboot se `/var/run/reboot-required` existir |
| `make version` | Versões instaladas de ansible/docker/kind/kubectl |

## Pré-requisitos

- **OS**: Zorin 18.x ou Ubuntu 24.04+
- **Kernel**: 6.x com cgroup v2 unified
- **Disco**: ≥ 50 GB livres em `/`
- **sudo** sem password (ou `ansible-playbook --ask-become-pass`)
- **ansible** 2.16+ (`apt install ansible`)

### Opcional — para `make lint`

```bash
sudo apt install shellcheck
pip install ansible-lint yamllint
```

## Princípios

1. **Idempotência absoluta** — `make setup` 10× = mesmo estado
2. **Versões pinned** — toda mudança de versão num só sítio (`inventory.ini`)
3. **Sem `curl | bash` directo** — todos os downloads passam por GPG + checksum
4. **Sem Snap Docker** — playbook aborta se detectar
5. **Backup automático** de `daemon.json` antes de sobrescrever
6. **Reversível** — `make uninstall` desfaz a maior parte (GRUB/swap manual)

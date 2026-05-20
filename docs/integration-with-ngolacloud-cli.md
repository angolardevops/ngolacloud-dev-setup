# Integrating with `ngolacloud-cli`

How this lab supports the **NgolaCloud CLI** (Rust binary `ngolacloud`) —
during development, testing, and prod codepath validation.

## Layout

```
~/workspaces/delonix/
├── ngolacloud-dev-setup/                ← this repo (provisions the lab)
└── ngolacloud-lab/
    └── ngolacloud-integration/
        └── ngolacloud-cli/              ← Rust workspace (separate repo)
```

The CLI is **the operator's primary surface** — `ngolacloud init`,
`ngolacloud infra apply`, `ngolacloud platform deploy`, ...

The lab gives the CLI:

- A **Rust toolchain** ready to compile the workspace fast (sccache + mold)
- A **KVM/libvirt host** to test `ngolacloud infra apply` against real VMs
  before going to Hetzner / Z440
- A **signed-image pipeline** for the CLI binary itself (cosign attest L3)

## Day-1 workflow

```bash
# 1. Lab + Rust toolchain (done by `make onboard` already)
cd ~/workspaces/delonix/ngolacloud-dev-setup
make onboard                                    # includes rust_toolchain role
make setup TAGS=kvm                             # nested KVM for prod codepath validation

# 2. Get the CLI repo
git clone https://github.com/angolardevops/ngolacloud-integration \
  ~/workspaces/delonix/ngolacloud-lab/ngolacloud-integration

# 3. First build — uses sccache + mold from the lab
cd ~/workspaces/delonix/ngolacloud-lab/ngolacloud-integration/ngolacloud-cli
cargo build --release                           # ~75 s cold on i9-13900H
```

## Fast iteration loop

The `rust_toolchain` role wired `sccache` + `mold` into
`~/.cargo/config.toml`, so every cargo invocation gets:

- **mold** linker (5–10× faster than `ld`) — see [ADR-0005](adr/0005-mold-as-default-rust-linker.md)
- **sccache** caching layer (replays compiler outputs across runs)

Result on the reference workstation:

| Build | Time | Notes |
|---|---|---|
| `cargo check` (warm) | ~3 s | sccache hits ≥ 80 % |
| `cargo build --debug` (incremental) | ~8 s | one crate touched |
| `cargo build --release` (cold) | ~75 s | fresh checkout |
| `cargo test --workspace` | ~12 s | with `cargo-nextest`, sccache warm |

Recommended workflow command (`cargo watch` is installed via `dev_tools`):

```bash
cargo watch -x 'check --workspace --all-features' \
            -x 'test --workspace' \
            -x 'build --release'
```

## Testing `ngolacloud infra apply` against nested KVM

This is the **lab's killer feature** for the CLI: instead of bricking a
prod cluster while debugging, the CLI runs against KVM VMs on your own
laptop, using the same kubeadm + cloud-init + Cilium codepath.

```bash
# Pre-cond: kvm_host role installed (`make setup TAGS=kvm`)
cd ~/workspaces/delonix/ngolacloud-dev-setup

# 1. Spin up the nested cluster (1 CP + 2 workers, ~16 GB RAM)
make staging-up                               # ≈ `ngolacloud infra apply -f kvm/staging-cluster.toml`

# 2. Verify
virsh --connect qemu:///system list           # 3 VMs running
kubectl --context kind-ngolacloud-staging get nodes

# 3. Iterate: change a CLI flag, re-test
cargo build --release
./target/release/ngolacloud infra apply -f \
  ~/workspaces/delonix/ngolacloud-dev-setup/kvm/staging-cluster.toml

# 4. Tear down
make staging-down
```

The staging cluster runs Ubuntu 24.04 cloud images with the
prod-identical containerd + kubeadm prereqs (see
`kvm/cloud-init-user-data.yml.template`).

## Signing CLI release binaries with Cosign

When the CLI ships a tarball release (via the CLI repo's own
`.github/workflows/release.yml`), sign it with Cosign keyless against the
GitHub Actions OIDC token:

```yaml
# Inside ngolacloud-cli's release workflow:
- uses: sigstore/cosign-installer@v3
- name: Sign release tarball
  env:
    COSIGN_EXPERIMENTAL: 1
  run: |
    cosign sign-blob --yes ngolacloud-${VERSION}-x86_64-unknown-linux-gnu.tar.gz \
      --output-signature ngolacloud-${VERSION}-x86_64-unknown-linux-gnu.tar.gz.sig
```

Verifying on the lab:

```bash
cd ~/workspaces/delonix/ngolacloud-dev-setup
scripts/cosign-setup.sh install                      # if not done yet
cosign verify-blob \
  --certificate-identity-regexp 'https://github.com/angolardevops/.*' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  --signature ngolacloud-v1.0.0-x86_64.tar.gz.sig \
  ngolacloud-v1.0.0-x86_64.tar.gz
```

The lab's `verify-images-policy.yaml` (Tier 10) already covers
`ngolacloud/*` container images — if the CLI ships a containerised
variant, signature + admission gate work end-to-end.

## CLI commands that hit the lab

| CLI command | Where it goes | Lab feature it leverages |
|---|---|---|
| `ngolacloud init --dev` | Kind cluster on `localhost` | `make kind-up` |
| `ngolacloud infra apply -f staging.toml` | libvirt nested VMs | `kvm_host` role |
| `ngolacloud infra status` | reads kubeconfig | `make kind-up` |
| `ngolacloud platform deploy` | Helm install ngolacloud-portal | observability + ingress already up |
| `ngolacloud publish --pinggy` | exposes via Pinggy tunnel | nothing lab-side; CLI handles |

## Where CLI assumptions could drift from the lab

Watch for these — they're the same 20 % the
[divergence-from-prod.md](divergence-from-prod.md) lists:

- **Storage classes**: Kind = `standard` (Docker volume). Prod = `longhorn-ssd`
  or `ceph-rbd`. The CLI's `ngolacloud infra setup` writes a default
  `StorageClass` — verify it picks the right one per environment.
- **Multi-AZ HA**: Kind has 1 CP node; the CLI's `cluster.ha=true` flag
  needs the **nested KVM** path (which has 1 CP too — full HA validation
  belongs on Z440).
- **MetalLB / LoadBalancer**: Kind uses hostPorts (no LB IPAM); prod
  uses MetalLB. The CLI's `ngolacloud publish` must handle both.

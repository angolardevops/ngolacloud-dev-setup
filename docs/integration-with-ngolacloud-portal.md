# Integrating with `ngolacloud-portal`

How this lab feeds the **NgolaCloud portal** (Django + React SPA — the
tenant + admin web surfaces) during development.

## Layout

```
~/workspaces/delonix/
├── ngolacloud-dev-setup/           ← this repo (provisions the lab)
└── ngolacloud-lab/
    └── ngolacloud-integration/
        └── ngolacloud-portal/      ← Django + React (separate repo)
```

The lab provides: **Kind cluster + observability + secrets + GitOps**.
The portal provides: **the application that runs on top**.

## Day-1 workflow (fresh laptop)

```bash
# 1. Provision the host (run-once)
cd ~/workspaces/delonix/ngolacloud-dev-setup
make onboard                              # 15 min: host + kind + Grafana
make security-stack                       # +5 min: Kyverno + Trivy + Falco + opencost

# 2. Get the portal repo
git clone https://github.com/angolardevops/ngolacloud-integration \
  ~/workspaces/delonix/ngolacloud-lab/ngolacloud-integration

# 3. Build + load the portal image into the lab cluster
cd ~/workspaces/delonix/ngolacloud-lab/ngolacloud-integration
docker build -t ngolacloud/portal:dev ngolacloud-portal/

# 4. Use the lab's helper to load + (when ready) sign it
cd ~/workspaces/delonix/ngolacloud-dev-setup
make kind-load TAG=ngolacloud/portal:dev          # fast path
# OR full supply-chain path:
make cosign-sign IMAGE=ngolacloud/portal:dev      # requires registry, not local-only
```

## Hot-reload loop (every code change)

```bash
# in ngolacloud-portal/
make portal-image                         # docker build → portal:dev

# in ngolacloud-dev-setup/
make kind-load TAG=ngolacloud/portal:dev  # ~5s — pushes into kind nodes
kubectl -n ngolacloud rollout restart deploy/portal
```

Average iteration time on the reference workstation: **~12 s from save → pod restarted**.

## Seeding demo data into the running portal

The portal ships its own Django management command (`seed_demo`) — not
provided by this lab. But the lab makes it easy to invoke:

```bash
POD=$(kubectl -n ngolacloud get pod -l app=portal -o name | head -1)
kubectl -n ngolacloud exec "$POD" -- python manage.py seed_demo
```

The command auto-detects host capacity via `/proc/cpuinfo` and seeds
12 demo tenants + 8 containers proportional to your CPU/RAM (already
documented in the portal repo's `apps/_shared/management/commands/seed_demo.py`).

## How the lab's observability sees the portal

The `kind-up.sh --with-observability` install bundles kube-prom-stack
+ Loki + Grafana. Without any portal-side config, you get:

| Metric source | Where to look in Grafana |
|---|---|
| Pod CPU / memory | Dashboard 7249 (Kubernetes Cluster) → filter by `namespace=ngolacloud` |
| Pod restarts | Dashboard 6417 (Kubernetes Pods) |
| Container logs | Loki Quick Search (13407) → `{namespace="ngolacloud", app="portal"}` |
| Cilium flows | Hubble UI: `kubectl -n kube-system port-forward svc/hubble-ui 12000:80` |

For **custom application metrics**, the portal needs to expose `/metrics`
on a port + add a `ServiceMonitor` CR in `ngolacloud/` namespace. Out of
scope for this lab; the moment a `ServiceMonitor` exists the kube-prom
operator picks it up automatically (`serviceMonitorSelector: {}` in our
values).

## How the lab's security stack sees the portal

| Layer | What it does to the portal | Where the report shows up |
|---|---|---|
| Kyverno PSS Baseline (Tier 8) | Blocks the portal pod if it tries `privileged: true` or runAsRoot | `kubectl get policyreports -n ngolacloud` |
| Kyverno verifyImages (Tier 10) | Audit-only by default. Requires `ngolacloud/portal:*` to be Cosign-signed once policy is in Enforce | Same |
| Trivy Operator (Tier 9) | Scans the portal image for HIGH+ CVE every ~24h | `kubectl get vulnerabilityreports -n ngolacloud` |
| Falco (Tier 9) | Flags suspicious behaviour inside the portal pod | Loki tenant=falco; Grafana dashboard 11914 |
| opencost (Tier 9) | Calculates `ngolacloud` namespace cost in AOA | `make opencost-ui` → http://localhost:9090 |

## Production parity

The portal's prod deploy (`ngolacloud platform deploy` via the Rust CLI)
runs the same Helm chart against the same Cilium + Kyverno + Trivy
stack we have locally. The only "dev → prod" deltas are documented in
[`divergence-from-prod.md`](divergence-from-prod.md):

- Single replica vs. HA (1 CP × 3 workers vs. 3 CP × N workers)
- Docker volumes vs. Longhorn / Ceph for PVCs
- Cilium tunnel-mode VXLAN vs. native routing on bare metal
- No real LoadBalancer (uses hostPorts on Kind)

These deltas mean 80 % of bugs you catch locally are real prod bugs.
The remaining 20 % are caught in the **nested KVM staging** (Tier 5 —
see [`docs/adr/0004-nested-kvm-staging.md`](adr/0004-nested-kvm-staging.md)).

## Per-project `.envrc` template

Drop this in the portal repo root (the template ships in this lab as
`~/workspaces/delonix/ngolacloud-dev-setup/.envrc.template`):

```bash
# .envrc — sourced by direnv when you `cd` into the portal repo
use_nix nodejs python311
export KUBECONFIG="${HOME}/.kube/config"
export KIND_CLUSTER="ngolacloud-dev"
export NGOLACLOUD_DEV_DATA="${HOME}/.local/share/ngolacloud-dev/portal"
mkdir -p "$NGOLACLOUD_DEV_DATA"
```

Run `direnv allow` once after copying it in.

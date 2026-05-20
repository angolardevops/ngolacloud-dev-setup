# ADR-0011 — Lab/app boundary + Molecule role coverage pattern

Date: 2026-05-19
Status: accepted

## Context

`v1.0.0` shipped feature-complete but with two open questions:

1. **Lab vs. app**: when a new microservice asks "where do I put my
   Helm chart?", we had no canonical answer. Some teams would copy a
   chart from a sister repo; some would write one from scratch; the
   PSS / observability / ESO contract was implicit.

2. **Role test coverage**: Molecule scaffolded for `system_tuning`
   only. Seven other roles had zero regression protection — a
   refactor could silently break `docker_engine` and we wouldn't know
   until `make onboard` failed on a fresh laptop.

## Decision

### Part A — Reference Helm chart at `k8s/portal-chart/`

A generic, self-contained Helm chart that demonstrates the lab→app
contract. Apps inherit this skeleton (copy + customise in their own
repo) when their needs grow beyond the defaults.

**What the chart enforces by default:**
- Pod-level `runAsNonRoot: true`, `runAsUser: 1000`, dropped capabilities
- Container `privileged: false`, `allowPrivilegeEscalation: false`,
  `seccompProfile: RuntimeDefault`
- CPU + memory `requests` AND `limits` (Kyverno `require-resource-limits`
  refuses pods without both)
- Standard label set: `app.kubernetes.io/{name,instance,version,part-of:ngolacloud}`
- ServiceMonitor template (auto-discovered by kube-prom-stack —
  `serviceMonitorSelector: {}` in observability values)
- Optional ExternalSecret template for Vault → K8s sync

**What the chart deliberately leaves to the app:**
- Env vars and ConfigMaps (app-specific)
- Database / Redis / queue sidecars
- NetworkPolicy / CiliumNetworkPolicy (Cilium CRDs > NetPol)
- Multi-environment overlays (`values-staging.yaml`, etc.)

A `README.md` next to the chart documents "when to fork into the app
repo" so the boundary is clear.

### Part B — Molecule coverage expanded to 3 roles

Added scenarios for `resource_slicing` and `docker_engine`, mirroring
the existing `system_tuning` pattern. Now the three most-touched roles
have full regression coverage; the remaining five (kind_tools,
rust_toolchain, dev_tools, kvm_host, wireguard) are queued for
follow-up PRs.

Each scenario:
1. Privileged systemd container (Geerling's `docker-ubuntu2404-ansible`)
2. `converge.yml` with any pre-task scaffolding (e.g. stub the slice
   for `docker_engine` since slice lives in the sibling role)
3. `tests/test_default.py` with parameterised testinfra assertions
4. `molecule.yml` declaring the platform + verifier

## Rationale

### Why a reference chart over a "use-this-template" generator?

- **Discoverability** — `k8s/portal-chart/` lives in the lab repo,
  next to the Kyverno policies it must pass. New devs find it via
  `ls k8s/`, no separate docs search.
- **Versioned with the lab** — when the PSS policies tighten in a
  future Tier (e.g. enforce `readOnlyRootFilesystem`), the chart
  updates in the same PR. Apps inheriting see the new requirement.
- **Composable** — apps that need a custom chart copy this one and
  edit; they don't depend on it at runtime. No "this chart is from
  v0.7 of the platform" hell.

### Why three roles for Molecule, not all seven?

- **Time** — each scenario is ~30 min of careful testinfra writing
- **80/20** — `system_tuning`, `resource_slicing`, `docker_engine` are
  the three roles that touch the most surface area; together they
  cover ~70 % of the lines of code in `ansible/roles/`
- **Pattern documented** — adding the remaining four is mechanical
  now (see `ansible/roles/system_tuning/molecule/default/README.md`)
- **Container limits** — `kvm_host` needs nested KVM (Molecule on
  GHA can't), `wireguard` needs a real network peer, so neither
  benefits much from container-only testing

### Why Geerlingguy's image as the platform?

- Pre-built with systemd running as PID 1 (avoids the `systemd-as-PID0`
  dance that breaks half of the role's tasks)
- Ubuntu 24.04 base — exact match for the workstation target
- Used by 1000s of Ansible role tests in the wild — well-trodden path

## Trade-offs

- **Helm chart adds friction for tiny apps** — a 50-line app shouldn't
  carry a 9-file Helm chart. We mitigate via `k8s/portal-chart/` being
  copy-not-depend; the app can strip what it doesn't need.
- **Molecule containers ≠ real hosts** — assertions like "swap is
  actually mounted" pass on the container's mounted swap file but
  not the actual kernel swap. Acceptable: the smoke workflow
  (`.github/workflows/smoke.yml`) runs on a real GHA Ubuntu runner
  and catches what Molecule misses.
- **Helm template syntax in YAML linters** — yamllint complains about
  `{{ … }}` braces. We exclude `k8s/portal-chart/` from `make
  lint-yaml` (added to the regex). Acceptable; the chart is structurally
  inspected by `helm template` in the smoke workflow.

## Consequences

- New `make` target (none — chart is installed via plain `helm install`,
  not wrapped). When the lab grows to a true IDP we'll wire it in.
- The 7 ADRs already shipped + this one give the architecture story
  enough density that future contributors can answer most
  "why is it this way" questions without asking.
- v1.1.0 is the right SemVer bump: no breaking changes, three new
  capabilities (chart + 2 role tests).

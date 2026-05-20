# ADR-0010 — Resilience (chaos-mesh), secret sync (ESO), SLSA L3 (cosign attest)

Date: 2026-05-19
Status: accepted

## Context

Tier 10 closed the *supply-chain trust* triangle (signature + scan +
admission gate). What was still missing for a v1.0-ready lab:

1. **Resilience evidence** — we *think* the cluster recovers from pod
   loss / network partition / CPU stress, but we've never proven it.
2. **Secret distribution** — Vault dev-mode exists (Tier 7) but apps
   can't *consume* secrets from it without bespoke client code.
3. **SLSA Level 3** — Tier 10 reached L2 (signed images + transparency
   log). L3 requires *build provenance attestations* that pin the image
   to a specific build pipeline.

## Decision

Three independent additions, all opt-in:

| Concern | Tool | What it produces |
|---|---|---|
| Resilience | **chaos-mesh** (v2.7) | Scheduled PodChaos / NetworkChaos / StressChaos with opt-in label scope |
| Secret sync | **External Secrets Operator** (v0.10) | K8s `Secret` objects auto-refreshed from a Vault `ClusterSecretStore` |
| SLSA L3 | **cosign attest** + sibling Kyverno policy | Pods only admitted if a Sigstore-verifiable SLSA provenance predicate exists |

Plus a CI gate: a weekly **kube-bench drift detector** spins up a fresh
Kind cluster on a GitHub Actions runner, runs the CIS Benchmark, and
fails the workflow if the FAIL count regresses past the baseline.

## Rationale

### Why chaos-mesh over Litmus / Gremlin / Pumba?

- **Scoped, label-driven targeting** — workloads must opt in
  (`chaos.ngolacloud.ao/eligible=true` label). Litmus chaos is also
  opt-in but the scope syntax is more verbose; chaos-mesh's selector
  is YAML-native
- **Dashboard built-in** — `chaos-dashboard` Service is part of the
  Helm chart, no separate UI install. Litmus has ChaosCenter but it's
  a separate operator
- **PodChaos + NetworkChaos + StressChaos in one operator** — Pumba is
  Docker-only (no NetworkChaos); Gremlin is SaaS-only
- **CNCF Incubating, active maintenance** — comparable graduation
  status to Litmus, more active GitHub commits

### Opt-in scope is non-negotiable

Chaos engineering on a cluster that *also* runs the SRE's tooling
(Grafana, Loki, Kyverno, Falco) would shoot itself in the foot —
killing a Prometheus pod mid-incident loses the trail. The default
selector targets only `chaos-target` namespace + explicit label, so
nothing in the system or observability namespaces is ever touched.

### Why ESO over Vault Agent / Vault CSI / Secrets Store CSI Driver?

| Option | Pro | Con |
|---|---|---|
| **ESO (chosen)** | Native K8s Secret object (no app changes); refreshInterval; ClusterSecretStore = one config, many ns | Adds 1 operator + 1 CRD chain |
| Vault Agent Injector | Sidecar pattern, no K8s Secret on disk | Every pod needs annotations; no native K8s Secret consumption |
| Vault CSI Provider | Mount as volume; no K8s Secret | App must read from file; less ergonomic |
| Secrets Store CSI | Provider-agnostic (AWS/GCP/Azure too) | Heavier setup; same volume-mount UX problem |

ESO wins because the K8s Secret object is the universal API — every
Helm chart we'll ship references `secretRef`, not Vault-specific
volume mounts. Plus the refresh-on-interval semantics mean rotation
in Vault propagates automatically.

### Why SLSA L3 needs both `cosign sign` AND `cosign attest`?

The SLSA framework distinguishes:
- **L1**: build script exists in source
- **L2**: build is signed → "this came from somewhere with a key"
- **L3**: build is signed *and provenance-attested* → "this was built by
  a specific GitHub Actions workflow against a specific source commit"
- **L4**: hermetic, reproducible build (out of scope for now)

`cosign sign` gives us L2; we need `cosign attest --type slsaprovenance`
to add the predicate `{ builder: ..., invocation: ..., materials: ... }`.
Kyverno's `verifyImages.attestations` block checks the predicate.

### Why kube-bench in CI (not just on-demand)?

The local `make kube-bench` is a SRE-driven check — the operator runs
it before a release. The CI workflow catches *drift*: a kind config
change or a sysctl update that silently regresses a CIS rule shows
up as a failing weekly workflow before anyone notices in production.

The baseline `MAX_FAILS=5` is intentionally lenient at first — Kind
on a laptop will never match a hardened bare-metal CIS posture. The
goal is "don't regress", not "achieve perfection".

## Trade-offs

- **chaos-mesh + Falco interaction** — chaos-mesh injects faults via
  syscalls Falco may flag as suspicious. Documented exception in
  `falco-values.yaml` exclusions (TODO for a future PR).
- **ESO failure mode** — if Vault is unreachable, ExternalSecrets stop
  refreshing. K8s Secrets stay at their last good value (correct
  default). Pods keep running on stale secrets — acceptable for the
  lab but in prod we'd add an alert on `external_secrets_sync_calls_error`.
- **SLSA L3 attestation requires CI** — local devs running
  `docker build && kind load` can't (and shouldn't) produce an L3
  attestation. The SLSA policy is therefore Audit-only; only the
  L2 policy (`verify-images-policy.yaml`) goes to Enforce.
- **kube-bench CI = 5 min per run** — uses a fresh GitHub Actions
  runner with full Kind boot. We bound it to weekly + path-based
  triggers so it doesn't drown the PR feedback loop.

## Consequences

- 3 new top-level directories: `k8s/secrets/`, `k8s/chaos/`,
  `k8s/supply-chain/` (already existed; now has both `verify-images*.yaml`).
- 3 new scripts: `eso-install.sh`, `chaos-install.sh`, plus
  `cosign-setup.sh` extended with `attest` / `verify-attest` /
  `apply-policy-slsa` subcommands.
- 1 new CI workflow: `kube-bench.yml`.
- Tag v0.10.0 marks the **v1.0-candidate** state. A future v1.0.0
  release should consolidate (squash duplicate docs, remove `--demo`
  scripts that don't survive beyond a developer's first afternoon)
  rather than add features.

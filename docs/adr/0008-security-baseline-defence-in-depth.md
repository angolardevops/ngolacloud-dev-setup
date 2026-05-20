# ADR-0008 — Security baseline: defence in depth (4 layers)

Date: 2026-05-19
Status: accepted

## Context

The lab cluster started with zero security tooling. Going to prod with
"it worked locally" as the only check is professional malpractice — we
need a layered defence that catches issues at four distinct moments:

  1. **Admission time** — block bad configs before they run
  2. **Build time** — flag vulnerable images before they ship
  3. **Audit time** — measure cluster posture vs an external standard
  4. **Runtime** — catch behaviour anomalies in live pods

Each layer is independent; a finding in one is not blocked by another's
failure. Defence in depth, classic SRE/SecOps pattern.

## Decision

Adopt this four-tool baseline (all CNCF-graduated or sandbox, all
opt-in via separate `make` targets so onboarding stays light):

| Layer | Tool | When | Failure mode |
|---|---|---|---|
| 1. Admission | **Kyverno** (Tier 8) | Pod create / update | Reject or audit |
| 2. Build (continuous) | **Trivy Operator** | Periodic scan of every running image | Report CRDs |
| 3. Audit | **kube-bench** | On-demand Job (CIS Kubernetes Benchmark) | Pass/Fail per check |
| 4. Runtime | **Falco** | Continuous, kernel-level | Alert to stdout / falcosidekick |

Plus, as a cost-control adjunct (not security per se but adjacent
governance):

| Layer | Tool | Why here |
|---|---|---|
| Cost | **opencost** | Detects runaway pods that would burn the prod budget |

## Rationale

**Why Kyverno over OPA Gatekeeper?**
- YAML rules vs. Rego (steeper learning curve)
- Pod-level mutations + validations + generations in one engine
- Built-in policy reports (no need for separate Constraint reporting)

**Why Trivy Operator over a CI-time scan only?**
- Catches *running* images, not just images at PR time. A base image
  CVE that didn't exist at build-time can appear days later.
- Reports as CRDs, so other tools (Grafana, alertmanager) can
  subscribe without parsing log lines.

**Why kube-bench as a Job, not a DaemonSet?**
- Audit is point-in-time. Running it continuously wastes CPU and
  produces noise. On-demand `make kube-bench` matches how SRE teams
  actually consume CIS reports (weekly/monthly review).

**Why Falco with modern_ebpf (not kmod or legacy ebpf)?**
- Kind on a kernel 6.x host (Zorin 18) supports modern_ebpf
  out-of-the-box via CO-RE — no kernel-header gymnastics
- Lower overhead than the legacy ebpf driver
- kmod refuses to compile in Kind because /lib/modules isn't mounted

**Why opencost over Kubecost?**
- opencost is the open-source heart Kubecost is built on, donated to
  CNCF. Same data model, no licence drama.
- Plays nicely with the kube-prom-stack Prometheus we already have.

## Trade-offs

- **Memory overhead** — full stack adds ~2.5 GB to the 32 GB slice:
  ```
  trivy-operator:   ~500 MB
  kyverno:          ~400 MB (already counted in Tier 8)
  falco (DS):       ~250 MB × 4 nodes = 1 GB
  opencost:         ~150 MB
  ──────────────────
  Total new:        ~1.65 GB on top of the 1.6 GB observability stack
  ```
- **Trivy first-scan latency** — initial DB pull is ~600 MB; takes
  ~3 min on first install. After that incremental updates are <30 MB.
- **Falco modern_ebpf** — requires kernel 5.8+. Documented in the
  `validate-host.sh` preflight (kernel ≥ 6 is checked).
- **kube-bench skips master** — Kind exposes the control plane only
  inside a single Docker container; the "node" target covers it.
  Production with separate CP nodes runs the "master" target too.

## Consequences

- New `make` targets: `kyverno-install` (existing), `security-scan`
  (trivy + bench + report), `falco-install`, `opencost-install`.
- `scripts/onboard.sh` does NOT auto-install the security stack —
  it's opt-in per-tool. Reason: a new contributor needs ~10 min and
  a smaller cluster; security adds ~5 min and ~2.5 GB.
- A future Tier 10 should add **Cosign + image signing** (so the
  cluster only runs signed images) — Kyverno + Trivy is the
  foundation that makes Cosign meaningful.
- `docs/divergence-from-prod.md` needs a row noting that "the
  security stack runs in dev *exactly the same way* as in prod" —
  unlike storage/networking, this layer transfers 100%.

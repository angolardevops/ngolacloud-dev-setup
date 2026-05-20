# ADR-0009 — Supply chain trust: Cosign + Trivy CI + Kyverno verifyImages

Date: 2026-05-19
Status: accepted

## Context

Tier 9 covered the four runtime security layers (Kyverno admission +
Trivy continuous scan + kube-bench audit + Falco runtime). What it
*didn't* cover: **how do we trust the images themselves**?

A signed-but-vulnerable image is worse than an unsigned but clean one,
because the signature creates false confidence. We need three things
working together:

1. **Provenance** — was this image built by us, in our CI?
2. **Hygiene** — is this image free of known CVEs?
3. **Enforcement** — does the cluster *actually refuse* untrusted images?

## Decision

Adopt the **SLSA L2-ish** triangle: Cosign (provenance) + Trivy
(hygiene) + Kyverno verifyImages (enforcement).

| Concern | Tool | Where | What it produces / blocks |
|---|---|---|---|
| Provenance | **Cosign** | CI build step | Signature in OCI registry + Rekor log entry |
| Hygiene (shift-left) | **Trivy CI** | `.github/workflows/trivy.yml` | Blocks PR merge if HIGH+ CVE / config issue |
| Hygiene (continuous) | **Trivy Operator** | In-cluster (Tier 9) | VulnerabilityReport CRDs |
| Enforcement | **Kyverno verifyImages** | Admission webhook | Rejects pods with unsigned images |

Default signing mode: **keyless** (Sigstore OIDC). Allowed signer
identity regex: `https://github.com/angolardevops/.*`. Key-based mode
documented for air-gapped Z440 / Hetzner stages where Rekor isn't
reachable.

## Rationale

### Why keyless by default?

- **No private key to lose** — the signing certificate is ephemeral
  (10-min lifetime); the audit trail lives in the public Rekor log
- **Identity-tied** — a signature is bound to the OIDC subject (the
  GitHub Actions workflow run); rotating "trust" = changing the
  identity regex, not redistributing keys
- **No password management** — no `COSIGN_PASSWORD` env var to rotate
- **CI-native** — `id-token: write` permission in workflow + 2 lines
  of cosign sign — no secret stores involved

### Why key-based as a fallback?

- Air-gapped clusters (Z440 in a sealed network, edge Hetzner without
  internet egress) can't reach `https://rekor.sigstore.dev` — keyless
  verification fails closed
- One-off signers (manual hotfix images built outside CI) need
  *something* — a long-lived key is the pragmatic answer

### Why Trivy in CI on top of the Operator?

- **Shift-left UX** — operator finds CVEs at scan time (post-deploy);
  CI finds them at PR time (pre-merge). The PR author sees the SARIF
  inline on their PR diff.
- **Filesystem scan catches secrets** — operator only scans images;
  CI scans the raw repo and would catch a `.env` accidentally
  committed
- **SBOM generation** — CI produces an SPDX SBOM as a build artifact
  (90-day retention). Required for any supply-chain audit (NIST 800-218,
  EU CRA).

### Why Kyverno verifyImages, not Sigstore policy-controller?

- We already run Kyverno (4 baseline policies in Tier 8). Adding ONE
  more `ClusterPolicy` is lower friction than adding a second admission
  controller.
- Kyverno's verifyImages supports the same keyless / keys / certificate
  attestor types as policy-controller.
- Single source of policy state (kubectl get cpol) for both PSS and
  supply-chain rules.

## Trade-offs

- **First-time keyless sign is interactive** — opens a browser for
  OIDC consent. CI avoids this via `id-token: write` permission +
  GitHub Actions OIDC. Local devs signing ad-hoc images face the
  browser prompt once per session.
- **Rekor dependency at verify time** — `kubectl apply pod.yaml` that
  references a signed image fans out to a network call to
  `rekor.sigstore.dev` from the kyverno webhook. Cached for 5 min by
  default; outage = admission webhook timeout. Mitigated by setting
  `failurePolicy: Fail` so we fail closed (no untrusted pods slip in
  during an outage).
- **Audit → Enforce migration window** — the policy ships in Audit so
  first-week run shows the violations without breaking deploys.
  Promotion to Enforce is a 1-line `kubectl patch`.

## Consequences

- The portal CI (separate repo) needs a new `cosign sign` step after
  `docker push`. Template in `scripts/cosign-setup.sh`.
- `make trivy-install` (Tier 9) + `scripts/cosign-setup.sh apply-policy`
  (Tier 10) is the complete supply-chain stack.
- ADRs 0008 + 0009 together describe the security architecture. A
  future Tier 11 could add **SLSA L3** (build provenance attestations
  via cosign attest + Kyverno requiring them) — not done now because
  it requires re-jigging every CI workflow.
- The `verify-images-policy.yaml` lives next to `kyverno/` but in a
  separate `supply-chain/` directory because its lifecycle is
  different — image signing is a CI concern; PSS policies are a
  cluster concern.

# ADR-0007 — Flux v2 chosen over ArgoCD for cluster-state GitOps

Date: 2026-05-19
Status: accepted

## Context

The Kind dev cluster currently has cluster state applied imperatively:
`kind-up.sh` runs `kubectl apply` for Cilium + metrics-server +
observability + Kyverno. This works for dev but:

- Cluster state drifts silently from what's in git
- Promoting changes to prod = running the same scripts manually
- No reconciliation loop catches accidental `kubectl apply -f local.yaml`

We need GitOps. Two serious candidates: **Flux v2** (CNCF, lighter
footprint) and **ArgoCD** (CNCF, UI-heavy).

## Decision

Use **Flux v2** (toolkit-based: source-controller, kustomize-controller,
helm-controller, notification-controller). Install via
`scripts/flux-install.sh` — opt-in, not part of the default `kind-up.sh`.

Sample `GitRepository` + `Kustomization` manifests live in `k8s/flux/`
pointing at this repo itself (sample mode); production replaces them
with the actual cluster-state repo.

## Rationale

| Criterion | Flux v2 | ArgoCD |
|---|---|---|
| RAM footprint (full install) | ~300 MB (4 controllers) | ~1 GB (server + repo-server + dex) |
| Helm support | first-class HelmRelease CRD | needs `argocd-image-updater` add-on |
| Multi-tenancy primitives | RBAC at Kustomization level | Project + AppProject |
| UI | none built-in (use `flux` CLI + Grafana panel) | full-featured |
| OCI artifact source | native (`OCIRepository`) | plugin |
| Notification routing | native (`Provider` + `Alert` CRDs) | webhooks only |
| Pull vs push | pull-only | pull-only |

The deciding factors:
- **Footprint** — 300 MB vs 1 GB matters inside the 32 GB slice budget
- **HelmRelease as first-class** — the portal will ship a Helm chart;
  HelmRelease's `valuesFrom` integrates with Vault + sops natively
- **No UI** — for a lab we don't need one; production gets a Grafana panel
  via the `flagger` notification CRDs
- **OCI source** — when we start signing manifests with cosign + storing
  in Harbor, OCIRepository is built-in

## Trade-offs

- **No GUI** — operators who like ArgoCD's app graph have to learn
  `flux get …` and read Grafana panels
- **Bootstrap commit needed** — production `flux bootstrap github` writes
  back to git; for the lab we skip bootstrap and use plain `flux install`
- **GitOps for cluster state, NOT for app code** — `kind load
  docker-image` is still the fast path for dev iteration. Flux watches
  the Helm chart + values, not the source code

## Consequences

- Three workflows coexist:
  1. **Dev iteration** — `docker build` + `kind load` + `kubectl rollout
     restart` (no GitOps in the loop)
  2. **Cluster-state changes** (Cilium config, Kyverno policies, ingress
     setup) — commit to git, Flux reconciles
  3. **Production deploys** — bump image tag in git, Flux's HelmRelease
     picks up the new chart version, rolls out
- The `flux-install.sh` script stays opt-in. Most contributors don't
  need GitOps locally; those who do run `--sample` and see it work
- ADR-0008 (when written) will cover **what** goes in the cluster-state
  repo (multi-cluster directory layout, encrypted secrets, image
  automation policies)

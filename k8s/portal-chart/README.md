# `portal-chart` — reference Helm chart for NgolaCloud apps

Generic skeleton chart that any NgolaCloud microservice can inherit from
when deploying to the dev cluster. Demonstrates **what the lab expects
from an app** (PSS-compliant security context, mandatory resource limits,
ServiceMonitor for kube-prom-stack, ExternalSecret for ESO).

## Usage

```bash
# Render to stdout (sanity-check the templates)
helm template canary k8s/portal-chart

# Install to the lab cluster
helm install portal-dev k8s/portal-chart \
  --namespace ngolacloud --create-namespace \
  --set image.tag=dev \
  --set ingress.hosts[0].host=portal.ngolacloud.local

# Iterate: rebuild the image, reload it, restart pods
make kind-load TAG=ngolacloud/portal:dev
kubectl -n ngolacloud rollout restart deploy/portal-dev

# Upgrade with new values
helm upgrade portal-dev k8s/portal-chart \
  --reuse-values \
  --set autoscaling.enabled=true
```

## What's enforced by default

| Tier | Concern | How this chart satisfies it |
|---|---|---|
| 8 (Kyverno PSS Baseline) | No privileged containers | `securityContext.privileged: false` |
| 8 (Kyverno PSS Restricted) | runAsNonRoot | `runAsUser: 1000`, `runAsNonRoot: true` |
| 8 (require-resource-limits) | CPU + memory limits set | `.Values.resources.limits.{cpu,memory}` required |
| 9 (kube-prom-stack) | Metrics scrape | `ServiceMonitor` template |
| 11 (ExternalSecrets Operator) | Secret pulled from Vault, not committed | `externalSecrets.enabled=true` + ESO installed |
| 10 (Cosign verifyImages) | Image is signed | tag must be a real cosign-signed digest, not `:latest` |

## What's NOT in this skeleton

- App-specific env vars / ConfigMaps — define in the consuming repo
- Database / Redis / etc. — those have their own charts
- Multi-container pods (sidecars) — extend `templates/deployment.yaml`
- NetworkPolicy — defer to the consuming repo (Cilium CRDs > NetPol)

## When to fork into the app repo

The moment you need ≥1 of these, copy this chart into the app repo and
diverge:

- Custom CRDs the app installs
- App-specific volume mounts (PVCs, ConfigMap projections)
- Multi-environment overlays (`values-staging.yaml`, `values-prod.yaml`)
- StatefulSet instead of Deployment

This skeleton stays generic — its job is to **demonstrate the contract**,
not to be the production chart.

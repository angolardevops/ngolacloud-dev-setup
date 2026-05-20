# NgolaCloud — SRE + Platform Engineering + 12 Factor

Use this skill for any operational concern: SLOs, runbooks, on-call,
chaos, cost, platform features, application architecture for cloud-native.

## When to invoke

- Designing a new microservice — does it satisfy 12 Factor?
- Setting up alerting / SLOs for a new feature
- Writing a runbook for an incident type
- Discussing IDP (Internal Developer Platform) capabilities
- Reviewing whether something is "production ready"

## 12 Factor App — applied to NgolaCloud

### I. Codebase

One codebase per app, tracked in git, deployed multiple times (dev, staging, prod).

- ✅ Each NgolaCloud app lives in its own dir under `ngolacloud-integration/` (cli/portal/agent/sdk/stacks)
- ✅ The lab (`ngolacloud-dev-setup`) is its own repo — different deploy cadence
- ❌ Don't fork an app per environment; deploy the same code with different config

### II. Dependencies

Explicitly declared, never global.

- ✅ Python: `pyproject.toml` with pinned versions
- ✅ Rust: `Cargo.toml` + `Cargo.lock` committed
- ✅ Ansible: collections pinned in inventory.ini + `ansible-galaxy collection install` in CI
- ❌ Never `pip install --user` random tools in onboarding without versioning

### III. Config

Env vars; never in code.

- ✅ Portal reads `DATABASE_URL`, `REDIS_URL`, `VAULT_ADDR` from env
- ✅ Dev: `.envrc` (direnv) loads env vars per-project
- ✅ Prod: ExternalSecrets Operator syncs Vault → K8s Secret → env var
- ❌ Hardcoded API tokens in source (sops/age if it MUST be in repo)

### IV. Backing services

Treat backing services (DB, cache, queue) as attached resources.

- ✅ Portal's `DATABASE_URL=postgres://user:pass@host:5432/db` — swappable to RDS or local Postgres without code change
- ✅ MinIO + S3 share the API; only the endpoint URL differs
- ❌ Code that imports `psycopg2` and constructs SQL string-by-string

### V. Build, Release, Run

Strictly separate.

- ✅ **Build** = `docker build` in CI → image with SHA
- ✅ **Release** = `cosign sign` + `helm package` → chart version + image tag
- ✅ **Run** = Flux reconciles HelmRelease → pods running
- ❌ "Build on the production host" — never

### VI. Processes

Stateless + share-nothing.

- ✅ Portal pods write zero local state. Postgres + MinIO hold the truth
- ✅ Sessions in Redis (shared), not in pod memory
- ❌ Cron job that writes a state file in /tmp expecting it to be there next run

### VII. Port binding

Export services via port binding.

- ✅ Each container EXPOSES port 8000; ingress-nginx maps host → service
- ✅ ngolacloud-cli `publish` opens a Pinggy tunnel binding to the container's port
- ❌ Hardcoded `localhost:8000` in code (use service DNS or env var)

### VIII. Concurrency

Scale via the process model (horizontal pods, not bigger pods).

- ✅ HPA scales the portal Deployment 1→4 replicas on CPU 70%
- ✅ Celery worker pods scale independently of web pods
- ❌ Single jumbo pod with 32 GB memory limit

### IX. Disposability

Fast startup, graceful shutdown.

- ✅ Portal pod ready in ~10 s (lightweight `python manage.py runserver` would NOT count; gunicorn warmed up does)
- ✅ SIGTERM → 30 s drain (Django closes DB connections; ngolacloud-agent drains active tunnels)
- ✅ `preStop` lifecycle hook for explicit cleanup
- ❌ App that takes 2 min to start because it loads a 4 GB ML model — bake into image

### X. Dev/Prod parity

Keep dev, staging, prod as similar as possible.

- ✅ Same Cilium + Kyverno + Trivy stack in dev (this lab) and prod
- ✅ Same Helm chart deploys both (different values overlay)
- ✅ `docs/divergence-from-prod.md` documents the unavoidable 20%
- ❌ Sqlite in dev, Postgres in prod (use Postgres in both)

### XI. Logs

Treat as event streams. Write to stdout.

- ✅ Portal logs to stdout; promtail tails the pod's stdout into Loki
- ✅ Structured JSON when readable; plain text when not
- ❌ App that writes to a `/var/log/myapp.log` file (no rotation, no aggregation, lost when pod dies)

### XII. Admin processes

Run admin/management tasks as one-off processes.

- ✅ `kubectl -n ngolacloud exec deploy/portal -- python manage.py seed_demo`
- ✅ `kubectl -n ngolacloud exec deploy/portal -- python manage.py migrate`
- ❌ Embedding "if first-run, migrate" in the main app startup

## SRE — the operational practices

### SLO / SLI / Error Budget

- **SLI** (Service Level Indicator): a single measurable signal
  - `availability_30d = successful_requests / total_requests`
  - `latency_p99 = histogram_quantile(0.99, http_duration_bucket)`
- **SLO** (Service Level Objective): a target for the SLI
  - "99.9% availability over 30 days" → 43m allowed downtime
- **Error budget**: 1 - SLO = what you're allowed to spend
  - At 99.9% target, you have 0.1% × 30 days = 43.2 min of downtime budget

Where to define them:
- `docs/slo/<service>.md` — markdown file with the metric query + target
- Prometheus rule: `record: slo:availability_30d` + an alert when budget burn > 2× normal rate

### Runbooks

Every alert MUST link to a runbook.

```
slo:burn_rate{job="portal"} > 14 → "Portal 99.9% SLO burning fast"
   ↳ runbook: docs/runbooks/portal-burn-rate.md
```

Runbook template:

```markdown
# Portal — high burn rate

## Symptom
Alert `slo:portal-burn-rate-fast` firing. p99 latency or error rate sustained > 10× normal.

## First 5 minutes
1. Check Grafana dashboard `Portal SLO`
2. Are there failing pods? `kubectl -n ngolacloud get pods`
3. Recent deploy? `kubectl rollout history deploy/portal`

## Common causes
- DB slow query (check Postgres `pg_stat_statements`)
- Cilium NetworkPolicy regression (check Hubble flows)
- Cosign signature mismatch (Kyverno blocking new pods)

## Mitigation
- Roll back the last deploy if it correlates: `kubectl rollout undo deploy/portal`
- Scale up replicas: `kubectl scale deploy/portal --replicas=4`

## Postmortem trigger
> 30 min duration OR customer-visible → mandatory postmortem
```

### On-call hygiene

- **Rotation** — never more than 1 week, never less than 1 day
- **Hand-off** — verbal sync or written summary of in-flight issues
- **Postmortem** — every customer-visible incident, blameless format
- **Action items** — tracked as GitHub issues with `incident:<id>` label

### Chaos engineering

The lab installs chaos-mesh (Tier 11). Use it:

```bash
# Mark workloads as eligible
kubectl label deploy/portal -n ngolacloud chaos.ngolacloud.ao/eligible=true

# Apply the baseline experiments (pod-kill + network-loss + cpu-stress)
make chaos-apply

# Observe
make chaos-status
```

Run weekly on staging. Never in prod without explicit go.

### Cost (FinOps)

opencost projects per-namespace cost in AOA. Review monthly:

```bash
make opencost-report
make opencost-ui            # http://localhost:9090
```

If a namespace exceeds its budget, the SRE on-call investigates with the
team — not auto-scales down (could break SLO).

## Platform Engineering — IDP capabilities

This lab IS a minimal IDP. The capabilities a platform team typically provides:

| Capability | Lab provides |
|---|---|
| **Self-service deployment** | `make kind-load TAG=...` + Helm chart reference |
| **Golden paths** | portal-chart skeleton, .envrc.template, onboard.sh |
| **Observability included** | ServiceMonitor auto-discovered, Grafana dashboards |
| **Security guardrails** | Kyverno enforce policies, Trivy continuous scan |
| **Cost transparency** | opencost UI per-namespace |
| **Identity + secrets** | sops/age for repo, ESO for runtime |
| **GitOps** | Flux v2 install path |
| **Audit + compliance** | kube-bench drift gate, Falco runtime alerts |

Scaling next:

- **Backstage** (service catalog) — once you have ≥ 5 microservices in the ecosystem
- **Telemetry pipeline** — OpenTelemetry collector → Jaeger/Tempo
- **Multi-cluster** — Argo Rollouts or Flux multi-tenancy

## Anti-patterns

- **"It works on my machine"** — if it doesn't work in CI, it doesn't work
- **"Just SSH in and fix it"** — every fix in a hot prod node creates drift; do it in git
- **"We'll add monitoring later"** — late observability = late incidents
- **"Our service is special, doesn't need limits"** — every workload has limits; the question is what they are
- **"No SLO, just keep it running"** — without an SLO you can't tell if you're burning budget or have headroom

## When to invoke this skill (LLM prompts)

- "Is this design 12 Factor compliant?"
- "What's the right SLO for X?"
- "Write me a runbook for Y"
- "Should this be a sidecar or a separate deployment?"
- "How do I scale this service horizontally?"

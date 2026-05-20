# NgolaCloud — SOLID + CQRS + Clean Architecture

Use this skill when designing or reviewing software changes across any
NgolaCloud repo. Aligns Python (portal), Rust (CLI, agent), Go (sdk
helpers) and Ansible roles under one architectural vocabulary.

## When to invoke

- Designing a new module / service / role
- Reviewing a PR that touches business logic
- Refactoring a large file ("this view is 800 lines")
- Onboarding — explaining the architecture to a new contributor

## SOLID — five short rules

### S — Single Responsibility

A module has one reason to change.

- ✅ `ansible/roles/system_tuning/` — host kernel tuning ONLY. Doesn't touch Docker.
- ✅ `apps/instances/services.py` → `InstanceService.start()` — only orchestrates the start lifecycle. Doesn't render HTML, doesn't write to billing.
- ❌ A `helpers.py` that has db queries + http parsing + email sending — three reasons to change in one file.

### O — Open / Closed

Open for extension, closed for modification.

- ✅ Tier N+1 of the lab adds new roles/scripts; doesn't edit Tier N-1.
- ✅ Kyverno policies extend via new `ClusterPolicy` CRs; don't edit Kyverno itself.
- ❌ Hacking `kind-up.sh` with a giant `if-flag-then-special-case` block instead of adding a sibling script.

### L — Liskov Substitution

A subtype must be substitutable for its parent without breaking callers.

- ✅ `k8s/portal-chart/` is the contract; the real portal's chart in the app repo is a substitutable subtype (same values shape).
- ✅ Multiple `ServiceMonitor`-emitting charts are interchangeable from kube-prom's perspective.
- ❌ A "PortalChart" subclass that suddenly returns a different shape from `template.values` would break the kube-prom scraper.

### I — Interface Segregation

Many small interfaces > one large one.

- ✅ Scripts have ONE responsibility + flags (`kind-up.sh` ≠ `kind-down.sh`).
- ✅ Make targets are small, composable (`make security-stack = kyverno + trivy + falco + opencost`).
- ❌ A `manage.py do_everything --flag1 --flag2 --flag3 --flag4` god command.

### D — Dependency Inversion

High-level modules depend on **abstractions**, not concretes.

- ✅ `ngolacloud-cli` consumes a `.ngolacloud.toml` schema (the abstraction). Whether the host is libvirt KVM or Hetzner Cloud is a detail the CLI doesn't care about.
- ✅ The portal reads secrets via env vars (abstraction); ESO syncs them from Vault (concrete impl).
- ❌ A Django view that imports `psycopg2` directly + builds SQL strings — coupled to Postgres specifics.

## CQRS — Command/Query Responsibility Segregation

Split **reads** from **writes**. They have different scaling, caching,
and consistency needs.

### When CQRS is worth it

- The read path is **read-heavy** (admin dashboards, list views)
- The write path needs **eventual consistency** (deploys, async jobs)
- You need a **denormalised view** of data that's expensive to compute live

### How NgolaCloud uses it

#### Reads (Query side)

**GET endpoints** in `apps/api/v1/admin_screens.py` aggregate from
multiple models into a single read-only Response. No model mutations.

```python
# apps/api/v1/admin_screens.py
class AdminOverviewView(APIView):
    """Read-only aggregator. No DB writes."""
    def get(self, request):
        return Response({
            "stats": _aggregate_stats(),
            "regions": _region_summary(),
            "alerts": _recent_alerts(since=24h),
            "top_tenants": _top_n_by_mrr(5),
        })
```

#### Writes (Command side)

**POST endpoints** emit a command + return 202 Accepted. The actual
state change is async, observable via separate query endpoints.

```python
# apps/instances/services.py
class InstanceService:
    def start(self, instance_id) -> AcceptedCommand:
        # Validate authority
        instance = self._authorize_or_404(instance_id)
        # Emit the command — actual work in a Celery worker
        emit_event("instance.start.requested", instance_id, by=user)
        return AcceptedCommand(202, "Starting...")
```

The reader sees the change via the next query (eventually consistent).

### When NOT to do CQRS

For simple CRUD (create-read-update-delete on a single entity), CQRS
adds overhead without benefit. Use it when the read shape genuinely
differs from the write shape.

## Clean Architecture — concentric layers

Dependencies point **inward**. Each ring depends only on rings closer
to the centre.

```
┌─────────────────────────────────────────────┐
│  4. Frameworks & Drivers                    │
│  Django, DRF, Celery, requests, libvirt-py  │
├─────────────────────────────────────────────┤
│  3. Interface Adapters                      │
│  views.py, serializers.py, presenters       │
├─────────────────────────────────────────────┤
│  2. Use Cases (Services)                    │
│  InstanceService, BillingService, ...       │
├─────────────────────────────────────────────┤
│  1. Entities                                │
│  Tenant, Instance, Invoice (pure data)      │
└─────────────────────────────────────────────┘
        ▲                       ▲
        │                       │
   inner layers don't know     outer layers depend
   about outer layers          on inner ones
```

### Practical mapping in `ngolacloud-portal`

| Layer | File pattern | Example |
|---|---|---|
| Entities | `apps/<x>/models.py` | `Tenant`, `Instance` — Django models with invariants |
| Use cases | `apps/<x>/services.py` | `InstanceService.start()`, `BillingService.invoice()` |
| Adapters | `apps/api/v1/<x>.py` | `InstanceViewSet`, `TenantSerializer` |
| Frameworks | `requirements.txt` deps | Django, DRF, Celery, ... |

### The rules in practice

1. **`models.py` never imports `views.py` or `serializers.py`**.
2. **`services.py` never imports DRF**. If a service needs HTTP context,
   pass it as a function arg or a domain-specific request object.
3. **Views are thin** — translate HTTP → service call → HTTP response.
4. **Domain logic lives in `services.py`** — testable without Django.
5. **`models.py` can have business invariants** (`def is_active()`,
   `def can_transition_to(state)`) but no I/O.

### Smell: violated dependency direction

```python
# ❌ Anti-pattern: a model imports a serializer
from apps.api.v1.serializers import InstanceSerializer
class Instance(models.Model):
    def to_api(self):
        return InstanceSerializer(self).data    # WRONG

# ✅ Correct: serializer imports model
from apps.instances.models import Instance
class InstanceSerializer(ModelSerializer):
    class Meta:
        model = Instance
```

## Putting it together — a worked example

**Scenario:** Add "suspend tenant" capability.

### Bad (violates SOLID + Clean)

```python
# apps/api/v1/tenants.py
class TenantViewSet(ViewSet):
    @action(['post'])
    def suspend(self, request, pk):
        # ❌ HTTP, DB, billing, email all mixed
        t = Tenant.objects.get(pk=pk)
        t.is_active = False
        t.suspended_at = timezone.now()
        t.save()
        send_email(t.owner_email, "You've been suspended")
        return Response({"status": "suspended"})
```

### Good

```python
# apps/tenancy/services.py — use case (no HTTP)
class TenantService:
    def __init__(self, mailer, emit):
        self._mailer = mailer
        self._emit = emit

    def suspend(self, tenant_id: str, by_user, reason: str) -> Tenant:
        # Single responsibility: orchestrate the suspend lifecycle
        t = Tenant.objects.select_for_update().get(pk=tenant_id)
        t.transition_to("suspended", reason=reason)  # invariant in model
        t.save()
        self._emit("tenant.suspended", tenant_id, by=by_user, reason=reason)
        self._mailer.send_suspension_notice(t.owner_email, reason)
        return t

# apps/api/v1/tenants.py — adapter (thin)
class TenantViewSet(ViewSet):
    @action(detail=True, methods=['post'])
    def suspend(self, request, pk):
        try:
            t = self.service.suspend(pk, by_user=request.user, reason=request.data['reason'])
        except IllegalTransition as e:
            return Response({"error": str(e)}, status=409)
        return Response(TenantSerializer(t).data)
```

Now:
- **S** — service has one job (orchestrate suspend)
- **O** — adding "ban" reuses the model's `transition_to` without editing existing code
- **L** — a test-double `TenantService` is substitutable in unit tests
- **I** — mailer + emitter are small, single-purpose interfaces
- **D** — viewset depends on `TenantService` (abstraction), not on `Mailer` directly

## File organisation that follows the layers

```
apps/<feature>/
├── models.py        # Entities (layer 1)
├── services.py      # Use cases (layer 2)
├── selectors.py     # Query helpers (layer 2 read side)
├── tasks.py         # Async use cases (Celery)
├── signals.py       # Side effects in response to model events
├── admin.py         # Django admin adapter (layer 3)
├── api/             # DRF adapter (layer 3)
│   ├── serializers.py
│   ├── views.py
│   └── urls.py
└── tests/           # Unit at layer 2; integration at layer 3
```

## Anti-patterns to flag in code review

- **Fat view** (anything beyond ~30 lines doing real logic — push to service)
- **Anaemic domain** (model = pure data class with zero invariants)
- **Service that imports DRF** (then it's not a service)
- **`models.py` calling external APIs** (use a `signals.py` or service)
- **One-off scripts duplicating service logic** (extract a CLI entrypoint that calls the service)

## When SOLID is overkill

Throwaway scripts, one-off migrations, demos. Don't enforce on a 30-line
prototype. Apply rigour proportional to lifetime.

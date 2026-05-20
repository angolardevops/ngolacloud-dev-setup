# NgolaCloud — PR workflow

Use this skill whenever a contributor (human or LLM) opens a pull request
against any NgolaCloud repo: `ngolacloud-dev-setup`, `ngolacloud-integration`
(portal, cli, agent, sdk), or `ngolacloud-infra`. Defines the contract
between author + reviewer.

## When to invoke

- User asks "how should I open a PR for X?"
- User shares a PR body / commit message draft and asks for review
- User wants to set up branch protection / CODEOWNERS

## Branching model

**Trunk-based + short-lived feature branches.** No gitflow `develop`/`release`
overhead. `main` (or `1.0` in active repos) is always deployable.

### Branch naming

```
feat/<topic>          # new capability       (≤ 1 week life)
fix/<topic>           # bug fix              (≤ 2 days)
chore/<topic>         # housekeeping
docs/<topic>          # docs only
refactor/<topic>      # structure change, no behaviour
perf/<topic>          # performance work
test/<topic>          # tests only
ci/<topic>            # workflows, lint, hooks
security/<topic>      # CVE response, hardening
```

`<topic>` is kebab-case, ≤ 6 words. Avoid ticket IDs in branch names
(they go in the PR body instead).

## PR checklist (every PR)

1. **Branch named** following the conventions above
2. **Commits follow Conventional Commits** (see `semantic-commits` skill)
3. **`make lint` passes locally** (pre-commit hook automates this — see
   `pre-commit-bestpractices` skill)
4. **`make health` is green** before pushing the final commit
5. **CHANGELOG.md updated** if change is user-facing
6. **ADR written** if the change has architectural implications
   (new dependency, new boundary, breaking contract)
7. **Tests added or updated** when behaviour changes
   - Ansible role change → corresponding Molecule scenario
   - App code change → unit + integration tests
8. **PR description** includes: **Context · Decision · Trade-offs** (not
   just "what changed")
9. **Review** by ≥ 1 other engineer (more for security/architecture)
10. **Squash + merge** to keep `main` linear

## PR body template

```markdown
## Context
What problem does this solve? Link the issue, ADR, or incident report.

## Decision
What does this PR do? One paragraph, no code yet.

## Trade-offs
Why this approach and not alternative X?
What did we explicitly NOT do?

## Risk
- [ ] No risk (docs/CI/test-only)
- [ ] Low (idempotent setup, reversible)
- [ ] Medium (cluster state change, but uninstall-friendly)
- [ ] High (data migration, schema change, breaking API)

## Validation
- [ ] `make lint` passes
- [ ] `make health` green
- [ ] CHANGELOG.md updated
- [ ] ADR added (if architectural)
- [ ] Smoke workflow ran on this branch

## Closes / Related
Closes #N · Related #M · Supersedes #P
```

## Reviewer checklist

When reviewing:

1. **Does the diff match the description?** If not, send back.
2. **Are the trade-offs honest?** Reject "we just need this" — demand the *why*.
3. **Is the test coverage proportional to the risk?**
4. **Is the new code reachable from CI?** (lint, smoke, kube-bench)
5. **Does it break the lab→app boundary?** (see ADR-0011)
6. **Idempotent?** Re-running the playbook / make target must not regress.
7. **Secrets safe?** Never inline tokens; use sops or ESO.
8. **Backward compat?** If breaking, MAJOR bump + migration notes.

## Branch protection (recommended on main)

```yaml
required_status_checks:
  - lint
  - trivy
  - smoke
required_pull_request_reviews:
  required_approving_review_count: 1
  dismiss_stale_reviews: true
restrictions: null
allow_force_pushes: false
allow_deletions: false
```

## Hot-path exceptions

For critical production fixes (security CVE, prod outage):

1. Open PR with branch `security/<cve-id>` or `fix/prod-<incident-id>`
2. Mark as **draft + RFC** if review needed; **non-draft + emergency**
   if shipping immediately
3. Required reviews drop to 0 ONLY if explicitly approved by on-call SRE
4. ADR (postmortem) written within 48h of merge

## Anti-patterns to reject

- "Refactor + feature in same PR" — split into 2 PRs
- "Disable test that's been flaky" — fix the flake or replace the test
- "Skip CI just this once" — never
- "Cosmetic + behaviour" mixed — split
- PR > 500 lines without a clear sub-feature boundary — likely needs splitting
- "I'll update CHANGELOG later" — no; do it in the same PR

# NgolaCloud — Semantic commits + SemVer + Gitflow-lite

Use this skill whenever someone asks how to format a commit, when to
bump a version, or how to tag a release in any NgolaCloud repo.

## When to invoke

- Drafting commit messages
- Deciding `v1.2.3` vs `v1.3.0` vs `v2.0.0`
- Setting up commit-msg hooks
- Writing release notes

## Conventional Commits 1.0

Format:

```
<type>(<scope>): <subject>

<body>

<footer>
```

### Header (subject line)

- `<type>` — see table below
- `<scope>` — optional; the affected component (e.g. `kind-up`, `kyverno`, `portal-chart`)
- `<subject>` — imperative ("add", "fix", "remove"), **lowercase**, no period, **≤ 72 chars total** (including type/scope)

### Types

| Type | Bumps | When to use |
|---|---|---|
| `feat` | MINOR | New capability, new role, new make target |
| `fix` | PATCH | Bug fix that restores documented behaviour |
| `docs` | PATCH | Documentation only |
| `chore` | PATCH | Housekeeping (version pin, dep update, formatting) |
| `refactor` | PATCH | Structural change, no behaviour change |
| `perf` | PATCH | Performance improvement |
| `test` | PATCH | Tests only |
| `ci` | PATCH | GitHub Actions, hooks, lint config |
| `security` | PATCH/MINOR/MAJOR | CVE response — bump depends on severity |
| `revert` | per reverted | Revert of a previous commit |

### Breaking changes

Append `!` after the type or scope:

```
feat(makefile)!: split uninstall into cluster + host stages
```

OR add a `BREAKING CHANGE:` footer:

```
feat(setup): replace docker with podman as default container runtime

BREAKING CHANGE: existing `make setup` users must uninstall docker first.
See MIGRATION.md.
```

Either form bumps MAJOR.

### Body

Mandatory for non-trivial commits. Cover **WHY**, not WHAT:

```
fix(kind-up): wait for Cilium pods Running before declaring cluster ready

Pre-fix: kind-up.sh emitted "cluster ready" as soon as nodes were
Ready, but Cilium init containers were still pulling on the workers.
Subsequent `kubectl apply` of test pods hit DNS failures (Cilium
hadn't programmed the eBPF maps yet).

Fix: add a wait_for "Cilium pods Running" with a 90s timeout between
the kind cluster creation and the metrics-server install.

Closes #42
```

### Footer

Optional. Examples:

```
Co-Authored-By: Maria Lopes <maria@ngolacloud.ao>
Closes #42
Refs ADR-0010
Reviewed-by: Carlos M.
```

## Examples (good + bad)

### Good

```
feat(kyverno): add disallow-latest-tag PSS policy
fix(kind-up): wait for Cilium pods Running before declaring ready
docs(adr): ADR-0011 lab/app boundary rationale
chore(deps): bump kind 0.30.0 → 0.30.1
perf(rust): switch linker from lld to mold (5-10× faster)
ci(trivy): block PR on HIGH+ CVE in fs scan
security(falco): add netcat-listener custom rule
```

### Bad

```
Update files                                 # no type, no scope, vague
fix: bug                                     # what bug?
feat(huge): massive refactor of everything   # split me
WIP                                          # never on main
Fixed                                        # incomplete + capitalised + past tense
```

## SemVer 2.0 application

| Change | Bump |
|---|---|
| Breaking change to `make setup` contract | MAJOR (X.0.0) |
| New role added to `ansible/roles/` | MINOR |
| New make target | MINOR |
| New kind value / Cilium upgrade with new feature | MINOR |
| Kyverno policy added | MINOR |
| Bug fix in existing role | PATCH (1.X.Y) |
| Version pin bump (kind/kubectl/helm) | PATCH |
| Doc-only change | PATCH |
| CHANGELOG-only change | (no version, no tag) |

## Tagging convention

```bash
# 1. Update CHANGELOG.md in a separate commit
git add CHANGELOG.md
git commit -m "release: v1.2.0"

# 2. Annotated tag (NEVER lightweight `git tag X`)
git tag -a v1.2.0 -m "v1.2.0 — Tier N: <short summary>"

# 3. Push branch + tags
git push origin main
git push origin v1.2.0
```

The `release.yml` GitHub Actions workflow triggers on `v*` tag push and:
- Extracts the `## [1.2.0]` entry from CHANGELOG.md
- Generates an SBOM via Trivy
- Creates a tarball
- Publishes a GitHub Release

Format `vMAJOR.MINOR.PATCH` strictly — no `-rc1` / `-beta` suffixes in
the release workflow (it ignores them deliberately).

## CHANGELOG entry format

```markdown
## [1.2.0] — 2026-05-23  — Tier N: <human-readable theme>

### Added
- Feature one with context (`scripts/foo.sh`)
- Feature two

### Changed
- Behaviour change with migration note

### Fixed
- Bug N (#issue)

### Removed
- Deprecated thing

### Security
- CVE fix
```

Order: Added → Changed → Fixed → Removed → Security. Match Keep-a-Changelog.

## Commit-msg hook (auto-validate locally)

Add to `.pre-commit-config.yaml`:

```yaml
- repo: https://github.com/compilerla/conventional-pre-commit
  rev: v3.6.0
  hooks:
    - id: conventional-pre-commit
      stages: [commit-msg]
      args: [feat, fix, docs, chore, refactor, perf, test, ci, security, revert]
```

Then `pre-commit install --hook-type commit-msg`.

## When NOT to bump

Some changes don't ship in any release:

- README typo fix in a feature branch (lands when the feature lands)
- Internal `docs/` changes that don't affect a user (still commit + push, but no tag)
- CHANGELOG.md edits during the release prep (the `release:` commit itself bundles them)

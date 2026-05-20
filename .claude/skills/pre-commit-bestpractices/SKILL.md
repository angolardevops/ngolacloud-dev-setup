# NgolaCloud — Pre-commit hooks best practice

Use this skill when setting up pre-commit hooks, debugging hook failures,
or proposing new hooks for any NgolaCloud repo.

## When to invoke

- Setting up a new contributor's local env
- Adding a new file type to a repo (needs a matching hook)
- A CI lint fails but the dev's local run didn't catch it
- Onboarding a new check that should run pre-push too

## Why pre-commit, not just CI

CI catches issues 5-15 min after push; pre-commit catches them BEFORE
the push happens. Same checks, faster feedback loop, **no shame in a
public CI fail**.

## Install (one-time per dev)

```bash
pip install --user pre-commit
cd ~/workspaces/delonix/ngolacloud-dev-setup
pre-commit install                          # adds .git/hooks/pre-commit
pre-commit install --hook-type commit-msg   # for Conventional Commits gate
pre-commit run --all-files                  # validate the whole tree now
```

Subsequent commits run the hooks automatically. Bypass (use sparingly):

```bash
git commit --no-verify -m "..."   # SKIP all hooks
SKIP=shellcheck git commit -m "..."  # SKIP one hook
```

## The baseline `.pre-commit-config.yaml` (already in this repo)

```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-merge-conflict
      - id: check-added-large-files
        args: [--maxkb=512]
      - id: check-yaml
        args: [--allow-multiple-documents, --unsafe]
      - id: check-toml
      - id: check-executables-have-shebangs
      - id: check-shebang-scripts-are-executable
  - repo: https://github.com/shellcheck-py/shellcheck-py
    rev: v0.10.0.1
    hooks:
      - id: shellcheck
        args: [-x]
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.37.0
    hooks:
      - id: yamllint
  - repo: https://github.com/ansible/ansible-lint
    rev: v25.10.0
    hooks:
      - id: ansible-lint
        files: ^ansible/.*\.(ya?ml)$
        args: [--offline]
```

## Hooks by repo type

| Repo | Add these hooks |
|---|---|
| **ngolacloud-dev-setup** (this) | trailing-whitespace, eof, yamllint, shellcheck, ansible-lint, markdownlint |
| **ngolacloud-portal** (Django) | + black, ruff, mypy, djlint, sqlfluff, bandit |
| **ngolacloud-cli** (Rust) | + cargo fmt --check, cargo clippy -- -D warnings, cargo deny |
| **ngolacloud-stacks** (compose YAML) | + docker-compose config validate |

## Adding a new hook

1. Find the upstream repo on https://pre-commit.com/hooks.html
2. Add to `.pre-commit-config.yaml` with the latest stable `rev:`
3. Run `pre-commit run <new-hook-id> --all-files` to see the baseline noise
4. Fix the violations OR add ignores (in `.gitignore`-style files specific to the tool)
5. Commit `.pre-commit-config.yaml` + the noise fixes in **one PR**
6. CI catches anyone who skipped local installation

## Common hook failures + fixes

| Failure | Fix |
|---|---|
| `trailing-whitespace` | Run `pre-commit run trailing-whitespace --all-files` (hooks auto-fix; re-stage + commit) |
| `end-of-file-fixer` | Same — auto-fixes |
| `shellcheck SC2086: Double quote to prevent globbing` | Quote the variable: `"$foo"` not `$foo` |
| `ansible-lint package-latest` | Pin the package version in inventory.ini |
| `yamllint line too long` | Either break the line or raise the per-rule limit in the config |
| `check-added-large-files` (>512KB) | If legitimately needed, use Git LFS; otherwise rethink |

## Auto-update hook versions

Monthly:

```bash
pre-commit autoupdate    # bumps rev: pins to the latest stable
pre-commit run --all-files
```

If `autoupdate` introduces noise, either fix it OR pin to the previous
working version. Then commit.

## CI integration

`.github/workflows/lint.yml` already runs the same tools (ansible-lint
+ shellcheck + yamllint). The pre-commit step IS optional in CI —
running it via CLI does the same checks. Set up branch protection on
`lint` only.

## When to disable a hook

Almost never. Better alternatives:

- **Add a pragma exclusion**: `# shellcheck disable=SC2034`
- **Add a path exclusion** in the hook's config (`exclude: '^vendored/'`)
- **Configure the tool**: e.g. `.ansible-lint`, `.yamllintrc`
- **Replace the hook**: if the tool is wrong for the job

If you find yourself adding many `--no-verify` commits, that's a smell:
the hook is mis-tuned, not the repo.

## Commit-msg hook for Conventional Commits

```yaml
- repo: https://github.com/compilerla/conventional-pre-commit
  rev: v3.6.0
  hooks:
    - id: conventional-pre-commit
      stages: [commit-msg]
      args: [feat, fix, docs, chore, refactor, perf, test, ci, security, revert]
```

Install with: `pre-commit install --hook-type commit-msg`

Rejects commits whose message doesn't match `<type>(scope): subject`.

## Make-target wrapper

`make lint` runs the same checks as the hooks (without the commit-msg
validator), suitable for ad-hoc CI runs or contributors not using
pre-commit. Both should give identical exit codes.

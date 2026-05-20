# ADR-0006 — sops + age for repository secrets

Date: 2026-05-19
Status: accepted

## Context

Several NgolaCloud repos need to ship encrypted secrets in-tree:
local-dev DB passwords, S3 access keys for backup demos, Pinggy
tokens. The status quo was a per-project `.envrc.secret` listed in
.gitignore — which keeps the secret out of git but also means:

- Anyone joining the team needs the secret re-shared out-of-band
- Rotating a secret requires emailing the new value to N people
- No audit trail of "who has had access"
- No way to ship a working repo to a fresh laptop without manual setup

We need encryption with **per-recipient keys** (so a team member
leaving can be removed via a key-rotation PR), **multi-format support**
(YAML / JSON / .env), and **transparent edit UX** (no special
editors).

## Decision

Adopt **sops** (Mozilla) as the encryption tool, with **age** (Filippo
Valsorda) as the key backend. PGP/KMS backends stay available for
specific niches (e.g. Vault unseal keys → AWS KMS) but `age` is the
default for repository-level secrets.

The `dev_tools` role installs both: `sops` from GitHub releases, `age`
from the Ubuntu 24.04 apt repos. A `.sops.yaml.template` lives at the
root of `ngolacloud-dev-setup` and is copied into each project that
needs encrypted secrets.

## Rationale

- **Per-recipient encryption** — `creation_rules` accept a list of age
  pubkeys. Adding/removing a team member is a 1-line PR
- **Transparent UX** — `sops edit foo.yaml` decrypts to a temp file,
  spawns `$EDITOR`, re-encrypts on save. No need to memorise extra
  commands
- **Format-aware** — only the matching keys are encrypted, structure
  stays diffable in git (vs. encrypting the whole file as a blob)
- **No daemons / KMS** — age is just a CLI; no Vault server needed
  for repo-level secrets
- **Vault for runtime, sops for config** — clear separation of concerns:
  runtime secrets (DB passwords, JWT signing keys) go in Vault dev
  mode; config secrets (S3 keys for the backup tool, Pinggy tokens)
  go in sops-encrypted YAML committed to the repo

## Trade-offs

- **Key management is on the operator** — age keys live in
  `~/.config/sops/age/keys.txt`. Lose them, lose access. We mitigate
  by encrypting to MULTIPLE recipients (yours + a team escrow pubkey
  + a second admin)
- **Pre-commit gate needed** — without one, a careless `git add` of an
  unencrypted file leaks the secret. Recommended hook:
  `pre-commit-hook-sops` (in `.pre-commit-config.yaml`)
- **`age` < 1 year of age-team-key support** — pre-1.0 the team-key
  feature shipped behind a feature flag; we use 1.1+ (Ubuntu 24.04
  ships 1.1.1)

## Why not these alternatives?

| Tool | Why not |
|---|---|
| **git-crypt** | Single symmetric key per repo; rotating requires re-encrypting everything; no per-key audit |
| **PGP via gpg-agent** | GPG keyring management is famously fragile; YubiKey UX is rough |
| **AWS KMS / GCP KMS** | Couples your local dev loop to cloud APIs; offline = no decrypt |
| **HashiCorp Vault transit** | Needs a running Vault server; overkill for "encrypt this YAML" |
| **dotenv-vault.com** | SaaS dependency; commercial service |

## Consequences

- Every ngolacloud project that ships encrypted secrets copies
  `.sops.yaml.template` to its root and customises the `age:` list
- The Vault dev-mode server (from `dev_tools` role) is the choice for
  **runtime** secrets (apps fetch via API). sops is only for **config**
  secrets (in-tree YAML)
- `make setup TAGS=tools` installs `sops`, `age`, `vault` at once
- The pre-commit-config catches unencrypted `secrets/*.yaml` files
  before they hit git

# ADR-0016 — Identity stage (SSH + signed commits + remote probe)

- **Status:** Accepted
- **Date:** 2026-05-20
- **Driver:** Phases F + G of the dev-setup → CLI consolidation roadmap.
  Eliminate the "first hour googling git ssh signing" experience that
  every new dev currently goes through.

## Context

A new NgolaCloud dev today, after running `ngolacloud infra dev`, still
has to:

1. Generate an SSH key (`ssh-keygen` flags vary by tutorial).
2. Add the public key to GitHub (and maybe GitLab) by clicking through
   a settings page.
3. Configure git to sign commits — and decide between GPG (the old
   default, requires `gpg-agent`) and SSH-signing (newer, simpler,
   supported by git ≥ 2.34 and GitHub since 2022).
4. Verify everything works via a test push.

Each of those steps has at least one common failure mode (wrong key
type, ssh-agent not loaded, wrong gpg.format value, no `user.email`).
Onboarding velocity suffers; in the worst case a commit lands unsigned
and triggers a CI rejection a day later.

## Decision

Add a new stage 0a to `ngolacloud infra dev` called the **identity
stage**, running BEFORE host-setup (Ansible) so the dev's first
interactive moment isn't mixed with sudo prompts.

The stage is idempotent and skip-safe (`--skip-identity-setup` for
power users with hardware keys / work-laptop policy):

1. Detect `git config --global user.email` + `user.name`. Missing →
   warn + print copy-paste commands; stage exits `Skipped`.
2. Probe `~/.ssh/id_ed25519`. Absent → `ssh-keygen -t ed25519
   -C <email> -N "" -f ~/.ssh/id_ed25519`. After generation, print
   the public key + paste-here URLs (GitHub + GitLab).
3. Configure git for SSH-based commit signing:
   ```ini
   [commit] gpgsign = true
   [gpg]    format  = ssh
   [user]   signingkey = ~/.ssh/id_ed25519.pub
   ```
   Skipped when already set.
4. Probe `ssh -T git@github.com` (and `git@<gitlab>` if
   `NGOLACLOUD_GITLAB_HOST` env is set). Pure read-only — the remote
   answers with "Hi <user>!" on success, "Permission denied" otherwise.
5. Verify `gh` CLI presence (and `glab` if a GitLab host is configured).
   Print install hints if absent; don't try to apt-install ourselves.

## Why SSH-signing instead of GPG

| Property | GPG | SSH-signing |
|---|---|---|
| User has to grok GPG keyring | Yes | No |
| Needs `gpg-agent` / `pinentry` | Yes | No |
| Same key for auth + signing | No (two keys) | **Yes** |
| GitHub/GitLab UI support | Long-standing | Since 2022 |
| Git minimum version | All | 2.34 |

For NgolaCloud's audience (modern devs on Ubuntu 24.04 / Zorin 18,
git 2.43+) the conceptual savings dominate. We retain the ability to
add GPG later via the same hook if a regulated customer demands it.

## Why ed25519

GitHub recommendation since 2021; smaller public key (one line on
screen, easy to paste); no factor-of-2× speed difference vs RSA-2048
on modern hardware; supported by every git provider we care about
(GitHub, GitLab, Bitbucket, Forgejo, Gitea).

## Consequences

### Positive

- **New devs hit `git push` and it Just Works.** The CLI gives them a
  signed-commits setup before they write their first line of code.
- **One key for auth + signing.** Same `id_ed25519` lets you `git
  push` AND sign commits — no second keypair to manage.
- **Forgiving idempotency.** Re-runs only flip what's not already set;
  hardware-key users opt out cleanly.

### Negative

- **We touch `~/.ssh/` and `~/.gitconfig`.** A dev who manages their
  own SSH (e.g. via a YubiKey) needs to remember to pass
  `--skip-identity-setup`. Surfaced clearly in `--help`.
- **The key has no passphrase.** Tradeoff: a passphrase-protected key
  needs `ssh-agent` setup before any push; we'd be back to the
  onboarding friction this stage is supposed to remove. Operator can
  add a passphrase manually any time:
  `ssh-keygen -p -f ~/.ssh/id_ed25519`.
- **We don't add the key to GitHub for the user.** That needs a PAT;
  asking for one in the middle of `infra dev` is a worse footgun than
  asking the user to paste into the browser. The probe step catches
  the "key not added yet" case and surfaces actionable instructions.

### Neutral

- **`gh` CLI is detected, not installed by the CLI.** Apt install
  belongs in the Ansible playbook (it's been added to the dev_tools
  list there). The CLI just warns if missing.
- **GitLab support is opt-in via env var.** Setting
  `NGOLACLOUD_GITLAB_HOST=gitlab.com` (or `gitlab.example.com` for
  self-hosted) enables the probe + glab check.

## Implementation

`ngolacloud-cli/src/infra.rs`:

- New section "Identity orchestration (stage 0a of `infra dev`)" with
  helpers `ssh_key_path`, `home_dir`, `git_identity`,
  `git_signing_configured`, `configure_git_signing`,
  `ssh_keygen_ed25519`, `probe_ssh_access`,
  `print_pubkey_paste_instructions`.
- `dev_identity_stage()` is the entry point; returns `StageOutcome`.
- `InfraCmd::Dev` enum gains `skip_identity_setup: bool` flag.
- `cmd_dev` runs the stage before host-setup; summary table now
  shows the identity row first.

## Verification

```console
$ ngolacloud infra dev --dry-run --skip-host-setup
━━━ infra dev · identity + host + kind + portal · DRY RUN
  → stage 0a: identity (SSH key + git signing + remote probe)
  git user           Walter Angolar <angolar.devops@gamil.com>
  ✓ ssh key already present: /home/walter/.ssh/id_ed25519
  → would: git config --global commit.gpgsign true / gpg.format ssh / user.signingkey <pub>
  → would: ssh -T git@github.com
  …
```

Real run (no dry-run, with no key on disk):

```console
$ ngolacloud infra dev
…
  → stage 0a: identity …
  ✓ generated ed25519 key: /home/walter/.ssh/id_ed25519

  Add the public key to your Git provider so you can push/pull:

  ssh-ed25519 AAAAC3Nz…  you@example.com

  GitHub  → https://github.com/settings/ssh/new
  GitLab  → https://gitlab.com/-/profile/keys
  or use   gh ssh-key add /home/walter/.ssh/id_ed25519.pub

  ✓ git configured for SSH commit signing
  ⚠ GitHub SSH access not yet active: git@github.com: Permission denied (publickey).
     Add the public key shown above to https://github.com/settings/ssh/new
     then re-run `ngolacloud infra dev` (idempotent).
```

# ADR-0012 — `ngolacloud-cli` as the single entry-point for dev setup

- **Status:** Accepted
- **Date:** 2026-05-20
- **Driver:** Phase A of the dev-setup → CLI consolidation roadmap.

## Context

Until now, provisioning a NgolaCloud dev workstation required:

1. `git clone https://github.com/angolardevops/ngolacloud-dev-setup`
2. `cd ngolacloud-dev-setup`
3. `make bootstrap-dev` (apt + pipx + pre-commit + direnv)
4. `make setup` (slice + swap + Docker + kind tooling)
5. `make kind-up` (cluster + observability)

Five separate commands across two repos. A new dev was funnelled to the
README which explained the order — but discovering the second repo at all
required already knowing it existed.

Meanwhile `ngolacloud-cli` (Rust, the user-facing surface) already had
`ngolacloud infra dev` that brought up the kind cluster + manifests. It
just didn't do anything about the host underneath — devs had to know to
run the Makefile manually first.

The result was a chicken-and-egg: the CLI couldn't be the entry point
because it didn't do host setup; nobody documented the CLI as the entry
point because of that gap; new devs hit half-tuned hosts (no slice, no
swap) and spent hours diagnosing why their builds were OOM-killed.

## Decision

`ngolacloud infra dev` becomes the **single supported entry point** for
dev-workstation bootstrap.

- It probes the host for known gaps (resource slice configured? swap on?
  Docker reachable?) and runs the ngolacloud-dev-setup Ansible playbook
  whenever any gap is detected.
- It **calls `ansible-playbook` directly** — no `make` indirection — so
  the dev-setup repo doesn't need to be checked out at the user's CWD.
- If the dev-setup checkout isn't on disk, the CLI clones it from
  GitHub into `$XDG_STATE_HOME/ngolacloud/dev-setup/` (≈
  `~/.local/state/ngolacloud/dev-setup`) and runs from there.
- Discovery order is documented and overridable:
  1. `$NGOLACLOUD_DEV_SETUP_DIR` (operator override)
  2. Sibling of integration repo (`<integration>/../ngolacloud-dev-setup`)
  3. XDG state cache (`$XDG_STATE_HOME/ngolacloud/dev-setup`)
  4. Clone from `https://github.com/angolardevops/ngolacloud-dev-setup.git`

The `Makefile` in this repo remains as a low-level escape hatch — devs
hacking on the playbook itself, or running individual roles via `TAGS=`,
still benefit. But the README is updated to make the CLI path the
default first-class flow.

## Consequences

### Positive

- A fresh laptop with just the CLI installed bootstraps end-to-end.
- The CLI can enforce auth / version checks BEFORE running the playbook
  — something Make can't (Make has no knowledge of who's logged in).
- The dev-setup repo stops needing a "manual onboarding" doc — it's an
  implementation detail behind the CLI.
- Foundation for Phase B (progress bars), Phase C (rotating logs), Phase
  D (dynamic 50% resource cap) and Phase F (SSH/signed commits) — every
  one of those hooks into the CLI orchestration, not the playbook.

### Negative

- Two paths exist for the same setup (CLI vs Makefile). We tolerate the
  duplication because the Makefile is genuinely useful for playbook
  developers; we mitigate by making the CLI path the documented default.
- The auto-clone hides a network dependency at first run. Mitigated by:
  honouring `NGOLACLOUD_DEV_SETUP_DIR` for offline / air-gapped setups,
  and surfacing the clone URL in dry-run output.

### Neutral

- The CLI now shells out to `ansible-playbook` from Rust. We do *not*
  re-implement any role logic in Rust — that would duplicate ~600 lines
  of YAML across 8 roles. The CLI is a thin orchestrator.

## Implementation notes

Code lives in `ngolacloud-cli/src/infra.rs` — search for
`Host-setup orchestration (stage 0 of \`infra dev\`)`. Key functions:

| Function | Role |
|---|---|
| `discover_dev_setup()` | Env / sibling / cache directory probe |
| `ensure_dev_setup_clone()` | `git clone --depth 1` when nothing on disk |
| `host_setup_gaps()` | Probes slice / swap / Docker reachability |
| `dev_host_setup_stage()` | Stage-0 orchestrator called from `cmd_dev` |
| `run_ansible_setup()` | Spawns `ansible-playbook` with stdio inheritance |

Environment knobs:
- `NGOLACLOUD_DEV_SETUP_DIR` — pin the checkout location
- `NGOLACLOUD_DEV_SETUP_TAGS` — forwarded as `--tags X` to ansible
- `NGOLACLOUD_DEV_SETUP_VERBOSE` — e.g. `-vv` for ansible debug

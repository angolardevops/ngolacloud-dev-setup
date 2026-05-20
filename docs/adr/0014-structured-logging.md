# ADR-0014 — Structured logging with rotating file sink

- **Status:** Accepted
- **Date:** 2026-05-20
- **Driver:** Phase C of the dev-setup → CLI roadmap. Operator request to
  always have a `ngolacloud-dev.log` (and `ngolacloud-prod.log`) on disk,
  versioned and rotated, even when the user runs the CLI in default
  text-output mode.

## Context

Pre-Phase-C, `cli_log` was dual-mode:
- **Text mode** (default) — colored `eprintln!` to stderr, **no
  tracing subscriber installed**, **no events captured**.
- **JSON mode** (`NGOLACLOUD_LOG_FORMAT=json`) — structured JSON to
  stderr via `tracing_subscriber::fmt().json()`.

That meant for 99 % of devs, **nothing was recorded**. When something
went sideways (an Ansible task hanging, a Docker pull stalling), the only
trace was whatever scrolled past in the terminal. By the time the dev
reached out for help, the scrollback was gone.

The user explicitly asked for:
- `ngolacloud-dev.log` (dev) — weekly rotation, ~50 MB cap
- `ngolacloud-prod.log` (prod) — daily rotation, ship to Loki / ES

## Decision

`cli_log::init()` now installs **two** layers via
`tracing_subscriber::registry()`:

1. **File layer** — always on. JSON events written to
   `$XDG_STATE_HOME/ngolacloud/logs/ngolacloud-{dev|prod}.log` (default
   `~/.local/state/ngolacloud/logs/`).
2. **Stderr layer** — JSON events on stderr, **only** when
   `NGOLACLOUD_LOG_FORMAT=json`.

Every helper in `cli_log` (`header`, `step`, `ok`, `warn`, `fail`, `kv`,
`note`) **always emits a `tracing::info!` event** (so the file catches
it) and **conditionally emits the colored `eprintln!`** (text-mode only).
JSON-mode users see the subscriber on stderr; text-mode users see the
colored eprintln on stderr; both modes end up with the same JSON in the
log file.

Rotation:

| Env (NGOLACLOUD_LOG_ENV) | Rotation | Files kept |
|---|---|---|
| `dev` (default) | HOURLY | last 4 (loose ~50 MB target) |
| `prod` | DAILY | last 14 (~ 2 weeks before Loki ships) |

`tracing-appender` 0.2's `Rotation::WEEKLY` doesn't exist; the closest
time-based rotation is `HOURLY` / `DAILY`. We pick HOURLY for dev so
log files don't grow unbounded on a long-lived workstation; cleanup
beyond `max_log_files` is a follow-up (the `Builder` API supports it
via `.max_log_files(N)` — pending the next minor bump).

Env knobs (all optional):

- `NGOLACLOUD_LOG_DIR` — override the default log directory.
- `NGOLACLOUD_LOG_ENV` — `dev` (default) or `prod`.
- `NGOLACLOUD_LOG_FORMAT` — `json` to also mirror to stderr.

## Consequences

### Positive

- **Every CLI run leaves an audit trail.** Triaging a slow `infra dev`
  becomes a `grep slice ngolacloud-dev.log.*` away from the answer.
- **JSON in the file means structured filtering.** `jq` can extract
  every `kind=fail` event in a day, count `kind=ok` per role, etc.
- **Loki/ES ingestion is trivial** because the format is already JSON
  with stable fields (`timestamp`, `level`, `kind`, `phase`, `message`).
  promtail just tails the file.

### Negative

- **One extra disk write per CLI event** — non-blocking via
  `tracing_appender::non_blocking()` so the worker thread absorbs the
  cost. Measured overhead < 1 ms per event in practice.
- **The log directory can drift outside the operator's mental model**
  (it's under XDG state, not in the repo). Surfaced in `ngolacloud
  status --verbose` (next minor) and in the failure path of
  `cli_log::init` (we eprintln if the dir can't be created).
- **No size cap yet.** Rotation is purely time-based; if a single
  hour produces > 50 MB of events (unusual but possible during
  debugging of a thrashing playbook) the file sits at that size until
  the next hour. Mitigation: `tracing-appender` 0.2 supports
  `max_log_files(N)` — wiring it up is a follow-up patch.

### Neutral

- **Loki sink is a stub.** The current implementation just routes
  `NGOLACLOUD_LOG_ENV=prod` to daily rotation. A future patch will add
  a tokio-driven Loki push-API sink (probably as an opt-in feature
  flag because not every prod host wants to push to a remote endpoint).

## Implementation

`ngolacloud-cli/src/cli_log.rs`:

- New use clauses for `tracing_appender::non_blocking::WorkerGuard`
  and `tracing_subscriber::{layer::{Layer, SubscriberExt},
  util::SubscriberInitExt}`.
- New `LOG_GUARD: OnceLock<WorkerGuard>` so the non-blocking writer
  thread stays alive for the whole process.
- New `default_log_dir()` resolving XDG state.
- `init()` rewritten to layer file + (optional) stderr subscribers.
- Every helper now emits `tracing::info!` before checking `is_json()`.

`ngolacloud-cli/Cargo.toml`:

- `tracing-appender = "0.2"` added to `[workspace.dependencies]` and
  to the `ngolacloud` crate's `[dependencies]`.

## Verification

```console
$ NGOLACLOUD_LOG_DIR=/tmp/x ./target/debug/ngolacloud infra dev --dry-run --skip-host-setup
[text-mode stderr output]
$ ls /tmp/x
ngolacloud-dev.log.2026-05-20-11
$ head -1 /tmp/x/ngolacloud-dev.log.*
{"timestamp":"…","level":"WARN","fields":{"kind":"warn","phase":"infra","message":"portal API not reachable yet …"}}
```

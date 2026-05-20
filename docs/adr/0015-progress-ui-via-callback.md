# ADR-0015 — Progress UI via Ansible callback plugin

- **Status:** Accepted
- **Date:** 2026-05-20
- **Driver:** Phase B of the dev-setup → CLI roadmap. Operator request to
  replace the verbose `PLAY [foo] / TASK [bar]` banners with an elegant
  progress UI plus a tabular "what was installed" report at the end.

## Context

`ansible-playbook` defaults to the `default` stdout callback, which is
loud and verbose: every play, every task, every host. For an 8-role
provisioning run that's ~250 lines of output. A new dev seeing that for
the first time has no idea which line is the "stage 0 succeeded" signal.

The `dense` and `oneline` callbacks shipped with Ansible are concise but
not pretty — they're still text streams aimed at CI parsing.

`indicatif` (already a dep of `ngolacloud-cli`) renders elegant
multi-line progress bars in Rust. The missing piece was getting
Ansible's events out of the playbook process in a shape the CLI can
parse.

## Decision

A custom Ansible stdout callback at
`ansible/callback_plugins/ngolacloud_stream.py` wraps the bundled
`default` callback (subclasses it) and additionally emits one
`[NGC]<json>\n` line on stdout per significant playbook event:

| Event | Shape |
|---|---|
| Play started | `{"kind":"play_start","name":"…"}` |
| Role started | `{"kind":"role_start","role":"<role>"}` |
| Task result  | `{"kind":"task","role":"<role>","name":"<task>","status":"ok\|changed\|skipped\|failed","host":"…"}` |
| Role ended   | `{"kind":"role_end","role":"<role>","ok":N,"changed":N,"failed":N,"skipped":N}` |
| Play ended   | `{"kind":"play_end","stats":{...}}` |

The CLI (`ngolacloud-cli/src/infra.rs::run_ansible_setup`) spawns
ansible with `ANSIBLE_STDOUT_CALLBACK=ngolacloud_stream`, pipes stdout,
and reads it line by line:

- Lines starting with `[NGC]` → parse JSON, drive `indicatif`
  progress bars (one per role) and accumulate a `RoleProgress` struct.
- Other lines → emitted as `tracing::info!(kind="ansible_raw", line=…)`
  so the log file (ADR-0014) captures the raw ansible output for
  triage. We do **not** echo to stderr — that would clash with the
  progress bars.

After the playbook exits, `render_setup_report(&progress)` prints a
table grouped by category (Host tuning / Resource budget / Docker /
K8s tooling / Rust / Dev tools) with a one-line description per role.

## When the structured UI is bypassed

The CLI falls back to passthrough (no callback, no bar, inherited
stdio — pre-Phase-B behaviour) when **any** of:

- `NGOLACLOUD_LOG_FORMAT=json` is set (operator wants structured stderr
  — emitting NGC events on top would double-render).
- stdout is not a TTY (CI, redirected to file, piped to `tee`).
- `NGOLACLOUD_NO_PROGRESS` is set (escape hatch).

This preserves the contract that `ngolacloud infra dev | tee setup.log`
still produces a useful, parseable log file.

## Consequences

### Positive

- **8 progress bars + a 1-page report replaces ~250 lines of
  default-callback noise.** Drastically more readable for a new dev.
- **The callback subclasses `default`**, so anyone running
  `ansible-playbook setup.yml` directly (without the CLI) still sees
  the familiar PLAY / TASK output. No regression for power users.
- **Categories + descriptions in the report** answer the implicit
  question "what did I just install?" with one click — links the role
  name to its purpose for new joiners.

### Negative

- **Coupling between two repos.** The callback plugin (lives in
  `ngolacloud-dev-setup`) and its consumer (lives in `ngolacloud-cli`)
  must agree on the event schema. We mitigate by **versioning the
  schema in this ADR** — schema changes bump the dev-setup minor and
  the CLI consumer follows.
- **The callback only fires when ansible-playbook is invoked via the
  CLI's `run_ansible_setup`.** Manual `make setup` users see the old
  default-callback output. Acceptable because the CLI is the canonical
  entry point (ADR-0012).

### Neutral

- **No persistent state in the callback.** Counters reset per playbook
  run; the CLI accumulates them. Simpler to reason about, and the
  ansible callback API doesn't promise persistence anyway.

## Schema versioning

This ADR pins **schema v1**. Any added fields are forwards-compatible
(the CLI ignores unknown keys). Removed or renamed fields → schema v2 +
new ADR + matching CLI release.

## Verification

```console
$ ANSIBLE_STDOUT_CALLBACK=ngolacloud_stream \
  ANSIBLE_CALLBACK_PLUGINS=ansible/callback_plugins \
  ansible-playbook -i ansible/inventory.ini ansible/setup.yml 2>&1 \
  | grep '^\[NGC\]' | head -3
[NGC]{"kind": "play_start", "name": "ngolacloud-dev workstation setup"}
[NGC]{"kind": "role_start", "role": "system_tuning"}
[NGC]{"kind": "task", "role": "system_tuning", "name": "Preflight — …", "status": "ok", "host": "localhost"}
```

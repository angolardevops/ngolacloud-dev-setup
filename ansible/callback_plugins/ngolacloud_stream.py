"""
ngolacloud_stream — ansible callback plugin emitting JSON-line events for
the ngolacloud-cli progress UI.

Activation:
    ANSIBLE_STDOUT_CALLBACK=ngolacloud_stream
    ANSIBLE_CALLBACK_PLUGINS=ansible/callback_plugins

The plugin emits one line per significant playbook event with the prefix
`[NGC]` followed by a JSON payload. ngolacloud-cli's `run_ansible_setup`
function pipes stdout, looks for that prefix, and drives an `indicatif`
progress bar + final report table from the events.

Event shapes:

    {"kind": "play_start",  "name": "<play name>"}
    {"kind": "role_start",  "role": "<role name>"}
    {"kind": "task",        "role": "<role>", "name": "<task name>",
                            "status": "ok|changed|skipped|failed",
                            "host": "<hostname>", "msg": "<truncated>"}
    {"kind": "role_end",    "role": "<role>", "ok": N, "changed": N,
                            "failed": N, "skipped": N}
    {"kind": "play_end",    "stats": {<host>: {"ok": ..., "failed": ...}}}

Lines that don't start with `[NGC]` are normal ansible output — the
plugin delegates them to the bundled `default` callback so the operator
still sees the per-task TASK / PLAY banners when they tail the log file.
"""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

import json
import sys

from ansible.plugins.callback import CallbackBase
from ansible.plugins.callback.default import CallbackModule as DefaultCallback


DOCUMENTATION = r"""
    name: ngolacloud_stream
    type: stdout
    short_description: Emits [NGC] JSON lines for ngolacloud-cli progress UI.
    description:
      - Wraps the bundled `default` stdout callback so humans still see the
        normal PLAY/TASK banners while the CLI consumes structured events.
    requirements:
      - Set as ANSIBLE_STDOUT_CALLBACK before ansible-playbook starts.
"""


class CallbackModule(DefaultCallback):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "stdout"
    CALLBACK_NAME = "ngolacloud_stream"

    def __init__(self) -> None:
        super().__init__()
        self._current_role: str | None = None
        # Per-role counters for the role_end event.
        self._role_counts: dict[str, int] = {"ok": 0, "changed": 0,
                                             "failed": 0, "skipped": 0}

    # ── Helpers ─────────────────────────────────────────────────────────
    def _emit(self, **payload: object) -> None:
        """Write one `[NGC]<json>\n` line to stdout, unbuffered."""
        # json.dumps with ensure_ascii=False so role names with accented
        # PT-PT comments survive intact (they're rare here but possible).
        sys.stdout.write("[NGC]" + json.dumps(payload, ensure_ascii=False, default=str) + "\n")
        sys.stdout.flush()

    def _role_of(self, task) -> str | None:
        """Best-effort extraction of the role name from a TaskResult."""
        try:
            r = task._role  # noqa: SLF001 — ansible internal
            return r.get_name() if r else None
        except Exception:  # noqa: BLE001
            return None

    def _flush_role(self) -> None:
        if self._current_role is not None:
            self._emit(kind="role_end", role=self._current_role, **self._role_counts)
            self._role_counts = {"ok": 0, "changed": 0, "failed": 0, "skipped": 0}

    def _maybe_role_start(self, task) -> None:
        role = self._role_of(task)
        if role != self._current_role:
            self._flush_role()
            self._current_role = role
            if role is not None:
                self._emit(kind="role_start", role=role)

    # ── Callbacks ───────────────────────────────────────────────────────
    def v2_playbook_on_play_start(self, play):
        self._flush_role()
        self._current_role = None
        self._emit(kind="play_start", name=play.get_name() or "<unnamed>")
        return super().v2_playbook_on_play_start(play)

    def v2_runner_on_ok(self, result):
        task = result._task  # noqa: SLF001
        self._maybe_role_start(task)
        status = "changed" if result.is_changed() else "ok"
        self._role_counts[status] += 1
        self._emit(
            kind="task",
            role=self._current_role,
            name=task.get_name() or "<unnamed>",
            status=status,
            host=result._host.get_name(),  # noqa: SLF001
        )
        return super().v2_runner_on_ok(result)

    def v2_runner_on_failed(self, result, ignore_errors=False):
        task = result._task  # noqa: SLF001
        self._maybe_role_start(task)
        self._role_counts["failed"] += 1
        msg = (result._result or {}).get("msg", "")  # noqa: SLF001
        if isinstance(msg, str) and len(msg) > 200:
            msg = msg[:200] + "…"
        self._emit(
            kind="task",
            role=self._current_role,
            name=task.get_name() or "<unnamed>",
            status="failed",
            host=result._host.get_name(),  # noqa: SLF001
            msg=msg,
        )
        return super().v2_runner_on_failed(result, ignore_errors)

    def v2_runner_on_skipped(self, result):
        task = result._task  # noqa: SLF001
        self._maybe_role_start(task)
        self._role_counts["skipped"] += 1
        self._emit(
            kind="task",
            role=self._current_role,
            name=task.get_name() or "<unnamed>",
            status="skipped",
            host=result._host.get_name(),  # noqa: SLF001
        )
        return super().v2_runner_on_skipped(result)

    def v2_playbook_on_stats(self, stats):
        self._flush_role()
        per_host: dict[str, dict[str, int]] = {}
        for h in stats.processed.keys():
            s = stats.summarize(h)
            per_host[h] = {
                "ok":       int(s.get("ok", 0)),
                "changed":  int(s.get("changed", 0)),
                "failed":   int(s.get("failures", 0)),
                "skipped":  int(s.get("skipped", 0)),
                "rescued":  int(s.get("rescued", 0)),
                "ignored":  int(s.get("ignored", 0)),
            }
        self._emit(kind="play_end", stats=per_host)
        return super().v2_playbook_on_stats(stats)

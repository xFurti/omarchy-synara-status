#!/usr/bin/env python3
"""Read local Synara status for the Omarchy bar widget.

The scanner stays on the machine: it resolves the Synara data directory,
reads runtime + provider-status files, and (when unlocked) the local
SQLite projection. A later MCP / HTTP status source can replace or
augment the snapshot without changing the QML contract.

Secrets in server-runtime.json (MCP runtime tokens, pairing secrets) are
stripped before anything is printed.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

PROVIDER_NAMES = {
    "claudeAgent": "Claude",
    "claude": "Claude",
    "codex": "Codex",
    "cursor": "Cursor",
    "grok": "Grok",
    "opencode": "OpenCode",
    "antigravity": "Antigravity",
    "kilo": "Kilo",
    "pi": "Pi",
    "droid": "Droid",
}

ACTIVE_STATUSES = {
    "running",
    "active",
    "streaming",
    "busy",
    "working",
    "generating",
    "in_progress",
    "in-progress",
    "thinking",
}
ERROR_STATUSES = {"error", "failed", "crashed", "interrupted", "unavailable"}
HANDOFF_PHASES = {"pending", "git_applied", "uncertain", "handing_off", "handoff"}

TASK_SQL = """
SELECT
  t.thread_id,
  t.project_id,
  t.title,
  t.branch,
  t.worktree_path,
  t.associated_worktree_path,
  t.associated_worktree_branch,
  t.associated_worktree_ref,
  t.working_directory,
  t.handoff_json,
  t.updated_at,
  t.settled_at,
  t.goal,
  p.title AS project_title,
  s.status AS session_status,
  s.provider_name,
  s.last_error,
  r.status AS runtime_status
FROM projection_threads t
LEFT JOIN projection_projects p ON p.project_id = t.project_id
LEFT JOIN projection_thread_sessions s ON s.thread_id = t.thread_id
LEFT JOIN provider_session_runtime r ON r.thread_id = t.thread_id
WHERE t.deleted_at IS NULL
  AND (t.archived_at IS NULL OR t.archived_at = '')
ORDER BY t.updated_at DESC
LIMIT 50
"""

HANDOFF_SQL = """
SELECT command_id, thread_id, phase, created_at, updated_at
FROM git_handoff_operations
WHERE phase IN ('pending', 'git_applied', 'uncertain')
ORDER BY updated_at DESC
LIMIT 20
"""

OPEN_TURN_SQL = "SELECT thread_id FROM provider_runtime_open_turns"


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def expand_path(value: str, home: str) -> str:
    text = (value or "").strip()
    if not text:
        return ""
    if text == "~":
        return home
    if text.startswith("~/"):
        return str(Path(home) / text[2:])
    if text.startswith("$HOME/"):
        return str(Path(home) / text[6:])
    if text.startswith("$SYNARA_HOME/"):
        synara_home = os.environ.get("SYNARA_HOME", "").strip() or str(Path(home) / ".synara")
        return str(Path(synara_home) / text[len("$SYNARA_HOME/") :])
    return str(Path(text).expanduser())


def candidate_homes(home: str, configured: str) -> list[str]:
    ordered = [
        expand_path(configured, home),
        expand_path(os.environ.get("SYNARA_STATUS_HOME", ""), home),
        expand_path(os.environ.get("SYNARA_HOME", ""), home),
        str(Path(home) / ".synara"),
        str(Path(home) / ".synara-canary"),
    ]
    seen: set[str] = set()
    out: list[str] = []
    for path in ordered:
        if not path or path in seen:
            continue
        seen.add(path)
        out.append(path)
    return out


def resolve_home(home: str, configured: str) -> tuple[str, str]:
    for base in candidate_homes(home, configured):
        userdata = Path(base) / "userdata"
        dev = Path(base) / "dev"
        if userdata.is_dir():
            return base, str(userdata)
        if dev.is_dir():
            return base, str(dev)
        if Path(base).is_dir():
            return base, str(userdata)
    default = str(Path(home) / ".synara")
    return default, str(Path(default) / "userdata")


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def sanitize_runtime(raw: Any) -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None
    pid = int(raw.get("pid") or 0)
    port = int(raw.get("port") or 0)
    return {
        "pid": pid if pid > 0 else 0,
        "host": str(raw.get("host") or "127.0.0.1"),
        "port": port if port > 0 else 0,
        "origin": str(raw.get("origin") or ""),
        "startedAt": str(raw.get("startedAt") or ""),
    }


def provider_display_name(provider_id: str) -> str:
    return PROVIDER_NAMES.get(provider_id, provider_id[:1].upper() + provider_id[1:] if provider_id else "Unknown")


def normalize_status(value: Any) -> str:
    return str(value or "").strip().lower().replace(" ", "_")


def worktree_name(path: str) -> str:
    text = str(path or "").rstrip("/")
    if not text:
        return ""
    return Path(text).name


def read_providers(state_dir: Path) -> list[dict[str, Any]]:
    status_dir = state_dir / "provider-status"
    if not status_dir.is_dir():
        return []
    providers: list[dict[str, Any]] = []
    for path in sorted(status_dir.glob("*.json")):
        raw = read_json(path)
        if not isinstance(raw, dict):
            continue
        provider_id = str(raw.get("provider") or path.stem)
        providers.append(
            {
                "id": provider_id,
                "name": provider_display_name(provider_id),
                "status": normalize_status(raw.get("status")),
                "available": raw.get("available") is True,
                "authStatus": str(raw.get("authStatus") or ""),
                "version": str(raw.get("version") or ""),
                "message": str(raw.get("message") or ""),
                "checkedAt": str(raw.get("checkedAt") or ""),
            }
        )
    return providers


def open_sqlite(db_path: Path) -> sqlite3.Connection | None:
    if not db_path.is_file():
        return None
    uri = "file:" + quote(str(db_path), safe="/") + "?mode=ro&immutable=1"
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=0.2)
        conn.row_factory = sqlite3.Row
        return conn
    except sqlite3.Error:
        return None


def has_handoff(handoff_json: str) -> bool:
    text = (handoff_json or "").strip()
    if text in ("", "null", "{}", "[]"):
        return False
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return True
    if parsed in (None, {}, []):
        return False
    if isinstance(parsed, dict):
        status = normalize_status(parsed.get("status") or parsed.get("phase") or parsed.get("state"))
        if status in HANDOFF_PHASES or status in ACTIVE_STATUSES:
            return True
        return any(parsed.values())
    return True


def read_database(state_dir: Path) -> dict[str, Any]:
    empty: dict[str, Any] = {"tasks": [], "handoffs": [], "worktrees": [], "openTurns": set()}
    conn = open_sqlite(state_dir / "state.sqlite")
    if conn is None:
        return empty
    try:
        open_turns = {str(row["thread_id"]) for row in conn.execute(OPEN_TURN_SQL)}
        handoff_rows = []
        try:
            handoff_rows = [dict(row) for row in conn.execute(HANDOFF_SQL)]
        except sqlite3.Error:
            handoff_rows = []
        handoff_threads = {str(row["thread_id"]) for row in handoff_rows}

        tasks = []
        worktrees: dict[str, dict[str, Any]] = {}
        try:
            rows = conn.execute(TASK_SQL)
        except sqlite3.Error:
            rows = []
        for row in rows:
            thread_id = str(row["thread_id"])
            worktree_path = str(row["associated_worktree_path"] or row["worktree_path"] or "")
            branch = str(row["associated_worktree_branch"] or row["branch"] or "")
            session_status = normalize_status(row["session_status"])
            runtime_status = normalize_status(row["runtime_status"])
            last_error = str(row["last_error"] or "")
            handoff_active = thread_id in handoff_threads or has_handoff(str(row["handoff_json"] or ""))
            open_turn = thread_id in open_turns
            status = runtime_status or session_status or "idle"
            if last_error and status not in ERROR_STATUSES:
                status = "error"
            elif open_turn and status not in ACTIVE_STATUSES and status not in ERROR_STATUSES:
                status = "running"
            task = {
                "id": thread_id,
                "title": str(row["title"] or "Untitled task"),
                "project": str(row["project_title"] or ""),
                "provider": str(row["provider_name"] or ""),
                "status": status,
                "sessionStatus": session_status,
                "runtimeStatus": runtime_status,
                "branch": branch,
                "worktreePath": worktree_path,
                "worktreeName": worktree_name(worktree_path),
                "worktreeBranch": str(row["associated_worktree_branch"] or ""),
                "workingDirectory": str(row["working_directory"] or ""),
                "updatedAt": str(row["updated_at"] or ""),
                "settledAt": str(row["settled_at"] or ""),
                "lastError": last_error,
                "handoffActive": handoff_active,
                "openTurn": open_turn,
                "goal": str(row["goal"] or ""),
            }
            tasks.append(task)
            if worktree_path:
                worktrees[worktree_path] = {
                    "path": worktree_path,
                    "name": worktree_name(worktree_path),
                    "branch": branch,
                    "threadId": thread_id,
                    "title": task["title"],
                    "inProgress": handoff_active or task["status"] in ACTIVE_STATUSES,
                }

        handoffs = []
        for row in handoff_rows:
            handoffs.append(
                {
                    "id": str(row["command_id"]),
                    "threadId": str(row["thread_id"]),
                    "phase": str(row["phase"]),
                    "updatedAt": str(row["updated_at"]),
                }
            )
        return {
            "tasks": tasks,
            "handoffs": handoffs,
            "worktrees": list(worktrees.values()),
            "openTurns": open_turns,
        }
    finally:
        conn.close()


def try_status_endpoint(url: str) -> dict[str, Any] | None:
    target = (url or "").strip()
    if not target:
        return None
    request = urllib.request.Request(
        target,
        headers={"Accept": "application/json", "User-Agent": "omarchy-synara-status/0.1.0"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=1.5) as response:
            payload = json.loads(response.read().decode("utf-8"))
            if isinstance(payload, dict):
                payload["source"] = "api"
                return payload
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, ValueError):
        return None
    return None


def counts_from(db: dict[str, Any]) -> dict[str, int]:
    tasks = db.get("tasks") or []
    active = 0
    for task in tasks:
        status = normalize_status(task.get("status"))
        if status in ACTIVE_STATUSES or task.get("openTurn"):
            active += 1
    worktrees = db.get("worktrees") or []
    in_progress_trees = sum(1 for tree in worktrees if tree.get("inProgress"))
    return {
        "activeAgents": active,
        "worktrees": in_progress_trees or len(worktrees),
        "handoffs": len(db.get("handoffs") or []),
        "recentTasks": len(tasks),
    }


def empty_snapshot() -> dict[str, Any]:
    return {
        "ok": True,
        "installed": False,
        "running": False,
        "source": "filesystem",
        "homeDir": "",
        "stateDir": "",
        "runtime": None,
        "lastRefreshAt": now_iso(),
        "lastRefreshMs": int(datetime.now(timezone.utc).timestamp() * 1000),
        "counts": {"activeAgents": 0, "worktrees": 0, "handoffs": 0, "recentTasks": 0},
        "providers": [],
        "tasks": [],
        "worktrees": [],
        "handoffs": [],
        "error": "",
    }


def scan(data_dir: str, endpoint: str) -> dict[str, Any]:
    home = os.environ.get("HOME") or str(Path.home())
    snapshot = empty_snapshot()
    base, state = resolve_home(home, data_dir)
    state_dir = Path(state)
    snapshot["homeDir"] = base
    snapshot["stateDir"] = state

    installed = state_dir.is_dir() or (state_dir / "settings.json").is_file() or (state_dir / "state.sqlite").is_file()
    snapshot["installed"] = installed
    if not installed:
        snapshot["error"] = ""
        return snapshot

    runtime_raw = read_json(state_dir / "server-runtime.json")
    runtime = sanitize_runtime(runtime_raw)
    snapshot["runtime"] = runtime
    snapshot["running"] = bool(runtime and pid_alive(int(runtime["pid"])))
    snapshot["providers"] = read_providers(state_dir)

    db = read_database(state_dir)
    snapshot["tasks"] = db["tasks"]
    snapshot["worktrees"] = db["worktrees"]
    snapshot["handoffs"] = db["handoffs"]
    snapshot["counts"] = counts_from(db)

    api_url = (endpoint or os.environ.get("SYNARA_STATUS_ENDPOINT") or "").strip()
    if not api_url and snapshot["running"] and runtime and runtime.get("origin"):
        api_url = str(runtime["origin"]).rstrip("/") + "/health"
    api = try_status_endpoint(api_url) if api_url else None
    if isinstance(api, dict) and api.get("tasks"):
        snapshot["source"] = "api"
        for key in ("tasks", "worktrees", "handoffs", "counts", "providers"):
            if key in api:
                snapshot[key] = api[key]
    return snapshot


def main() -> int:
    parser = argparse.ArgumentParser(description="Scan local Synara status")
    parser.add_argument("--data-dir", default="", help="Synara home directory override")
    parser.add_argument("--endpoint", default="", help="Optional HTTP status URL")
    args = parser.parse_args()
    snapshot = scan(args.data_dir, args.endpoint)
    json.dump(snapshot, sys.stdout, ensure_ascii=True, separators=(",", ":"))
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

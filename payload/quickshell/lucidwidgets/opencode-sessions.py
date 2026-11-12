#!/usr/bin/env python3
"""Merge the open-session snapshots written by the lucid-sessions TUI plugin.

Each OpenCode TUI process writes one `window-<pid>-<start>.json` file into
`$XDG_RUNTIME_DIR/opencode-lucid-sessions`. This helper keeps only the
snapshots whose process is still alive, folds duplicates (the same session open
in more than one window) into one row, and prints the result as JSON.

It is called by OpencodeWidget.qml once a second; it deliberately has no
dependencies beyond the Python standard library.
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any


def state_directories() -> list[Path]:
    """Both places the plugin may have written to, newest preference first."""
    directories: list[Path] = []
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        directories.append(Path(runtime) / "opencode-lucid-sessions")
    cache = Path(os.path.expanduser("~/.cache")) / "opencode-lucid-sessions"
    if cache not in directories:
        directories.append(cache)
    return directories


def process_start_ticks(pid: int) -> str | None:
    """Field 22 of /proc/<pid>/stat, or None when the process is gone."""
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
        fields = stat[stat.rindex(")") + 2 :].split()
        return fields[19]
    except (OSError, ValueError, IndexError):
        return None


def alive(pid: Any, start_ticks: Any) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    return process_start_ticks(pid) == str(start_ticks)


def merged() -> dict[str, Any]:
    sessions: dict[str, dict[str, Any]] = {}
    now = time.time()

    paths: list[Path] = []
    for directory in state_directories():
        paths.extend(directory.glob("window-*.json"))

    for path in sorted(set(paths)):
        try:
            snapshot = json.loads(path.read_text())
        except (OSError, ValueError):
            continue

        if not alive(snapshot.get("pid"), snapshot.get("startTicks")):
            # A crashed TUI cannot clean up after itself. Drop its file once it
            # is old enough that a just-starting process cannot own it.
            try:
                if now - path.stat().st_mtime > 60:
                    path.unlink()
            except OSError:
                pass
            continue

        pid = snapshot.get("pid")
        window_pid = snapshot.get("windowPid")
        window_address = snapshot.get("windowAddress")

        for item in snapshot.get("sessions") or []:
            session_id = item.get("id")
            if not isinstance(session_id, str) or session_id == "":
                continue

            row = sessions.get(session_id)
            if row is None:
                row = {
                    "id": session_id,
                    "title": str(item.get("title") or "").strip(),
                    "status": item.get("status") or "idle",
                    "active": False,
                    "attention": False,
                    "unread": item.get("unread"),
                    "directory": item.get("directory"),
                    "windowPid": None,
                    "windowAddress": None,
                    "windows": [],
                    "updatedAt": 0,
                    "doneAt": None,
                }
                sessions[session_id] = row

            status = item.get("status")
            if status == "busy":
                row["status"] = "busy"
            elif status == "attention" and row["status"] != "busy":
                row["status"] = "attention"
            elif row["status"] not in ("busy", "attention"):
                row["status"] = status or "idle"

            active = bool(item.get("active"))
            row["active"] = bool(row["active"]) or active
            row["attention"] = bool(row["attention"]) or bool(item.get("attention")) or item.get("unread") == "error"

            if not row["title"] and item.get("title"):
                row["title"] = str(item["title"]).strip()
            if not row["directory"] and item.get("directory"):
                row["directory"] = item["directory"]
            if row["unread"] is None and item.get("unread"):
                row["unread"] = item["unread"]

            if pid not in row["windows"]:
                row["windows"].append(pid)
            # The window that currently shows the session is the best click target.
            if active or row["windowAddress"] is None:
                row["windowPid"] = window_pid
                row["windowAddress"] = window_address
            row["updatedAt"] = max(int(row["updatedAt"] or 0), int(item.get("updatedAt") or 0))
            done_at = item.get("doneAt")
            if done_at is not None:
                row["doneAt"] = max(int(row["doneAt"] or 0), int(done_at))

    # Working first, then the ones that need attention, then finished sessions
    # newest-done first.
    def sort_key(row: dict[str, Any]) -> tuple:
        status = str(row["status"])
        rank = {"busy": 0, "attention": 1, "idle": 2}.get(status, 3)
        done = -int(row["doneAt"] or 0) if status == "idle" else 0
        return (rank, done, 0 if row["active"] else 1, str(row["title"]).lower())

    rows = sorted(sessions.values(), key=sort_key)
    for row in rows:
        if not row["title"]:
            row["title"] = "Untitled session"

    return {"version": 1, "generatedAt": int(time.time() * 1000), "sessions": rows}


def main() -> None:
    try:
        print(json.dumps(merged(), separators=(",", ":")))
    except Exception as error:  # never break the widget on an odd snapshot
        print(json.dumps({"version": 1, "generatedAt": int(time.time() * 1000), "sessions": [], "error": str(error)}))
    sys.exit(0)


if __name__ == "__main__":
    main()

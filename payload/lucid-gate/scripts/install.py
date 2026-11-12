#!/usr/bin/env python3
"""Wire lucid-gate into an existing lucid quickshell config.

Everything here is reversible and idempotent.  It only touches the two files
it owns a marked block in (shell.qml, Widgets.qml) and three symlinks.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
QS = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "quickshell"
STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "lucid-gate"

BEGIN = "    // >>> lucid-gate (managed by ~/src/lucid-gate/install.sh)"
END = "    // <<< lucid-gate"
IMPORT_LINE = 'import "./lucidgate"'
PRAGMA = "//@ pragma EnableQtWebEngineQuick"

SHELL_BLOCK = f"""{BEGIN}
    // The foreground half: a layer-shell gate over the window that asked, and a
    // corner pill while a task is running.  State lives in GateCore.
    GateOverlay {{
        id: gateOverlay
    }}
{END}
"""

CATALOGUE_ENTRY = '''        "options": []
    }, {
        "id": "gate",
        "name": "Gate",
        "blurb": "Compute, the next task, and what it pays.",
        "variants": [{
            "id": "quarter",
            "name": "Quarter",
            "blurb": "A 152 px square with Compute, a swipeable task and its reward.",
            "w": 152,
            "h": 152
        }],
        "options": []
    }]'''

WIDGETS_ANCHOR = '        "options": []\n    }]\n\n    // the full-width bars every preset stands on.'


def link(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_symlink() and Path(os.readlink(target)) == source:
        return
    if target.exists() or target.is_symlink():
        target.unlink()
    target.symlink_to(source)


def backup(path: Path) -> None:
    copy = path.with_name(path.name + ".bak.lucid-gate-" + str(int(time.time())))
    if not copy.exists():
        shutil.copy2(path, copy)


def patch_shell(dry: bool) -> str:
    path = QS / "shell.qml"
    text = path.read_text()
    if BEGIN in text:
        return "shell.qml already patched"
    if PRAGMA not in text:
        marker = "//@ pragma Env QSG_DISTANCEFIELD_ANTIALIASING=gray"
        if marker in text:
            text = text.replace(marker, marker + "\n" + PRAGMA, 1)
    if IMPORT_LINE not in text:
        anchor = 'import "./squircle"'
        if anchor not in text:
            raise SystemExit("shell.qml does not look like lucid shell (no squircle import)")
        text = text.replace(anchor, anchor + "\n" + IMPORT_LINE, 1)
    index = text.rfind("\n}")
    if index < 0:
        raise SystemExit("shell.qml has no closing brace")
    text = text[:index] + "\n\n" + SHELL_BLOCK + text[index:]
    if not dry:
        backup(path)
        path.write_text(text)
    return "patched shell.qml"


def patch_widgets(dry: bool) -> str:
    path = QS / "Widgets.qml"
    text = path.read_text()
    if '"id": "gate"' in text:
        return "Widgets.qml already has the gate entry"
    if WIDGETS_ANCHOR not in text:
        raise SystemExit("Widgets.qml does not look like lucid shell (no catalogue tail)")
    text = text.replace(WIDGETS_ANCHOR, CATALOGUE_ENTRY + "\n\n    // the full-width bars every preset stands on.", 1)
    if not dry:
        backup(path)
        path.write_text(text)
    return "patched Widgets.qml"


def unpatch_shell() -> str:
    path = QS / "shell.qml"
    text = path.read_text()
    start = text.find(BEGIN)
    end = text.find(END)
    if start >= 0 and end > start:
        text = text[:start].rstrip() + text[end + len(END):]
        text = text.replace(IMPORT_LINE + "\n", "", 1)
        path.write_text(text)
        return "unpatched shell.qml"
    return "shell.qml was not patched"


def unpatch_widgets() -> str:
    path = QS / "Widgets.qml"
    text = path.read_text()
    marker = '"id": "gate",\n        "name": "Gate",'
    index = text.find(marker)
    if index < 0:
        return "Widgets.qml had no gate entry"
    # walk back to the ", {" that opened the entry
    start = text.rfind("\n    }, {", 0, index)
    end = text.find("\n    }]", index)
    if start < 0 or end < 0:
        return "could not find the gate entry bounds"
    text = text[:start] + text[end:]
    path.write_text(text)
    return "unpatched Widgets.qml"


def install(dry: bool) -> None:
    print("lucid-gate installer" + (" (dry run)" if dry else ""))
    for source, target in [
        (REPO / "qml", QS / "lucidgate"),
        (REPO / "qml" / "GateCore.qml", QS / "GateCore.qml"),
        (REPO / "qml" / "GateWeb.qml", QS / "GateWeb.qml"),
        (REPO / "qml" / "GateWidget.qml", QS / "lucidwidgets" / "GateWidget.qml"),
        (REPO / "bin" / "gate", Path.home() / ".local" / "bin" / "gate"),
    ]:
        if not dry:
            link(source, target)
            if target.name == "gate":
                target.chmod(0o755)
        print(f"  link {target} -> {source}")

    config_file = CONFIG / "config.json"
    if not dry:
        CONFIG.mkdir(parents=True, exist_ok=True)
    if not config_file.exists() and not dry:
        config_file.write_text(json.dumps({
            "starting_balance": 0,
            "default_cost": 100,
            "place_costs": {
                "opencode": 100,
                "discord": 120,
                "steam": 200
            },
            "tasks": None
        }, indent=2) + "\n")
    print(f"  config {config_file}")

    print("  " + patch_shell(dry))
    print("  " + patch_widgets(dry))
    print()
    print("Restart the shell to pick it up:")
    print("  systemctl --user restart quickshell")
    print("If the card is not on the desktop yet, add it once:")
    print("  qs ipc call -- widgets add gate wallet")


def uninstall() -> None:
    print("lucid-gate uninstaller")
    for target in [
        QS / "lucidgate",
        QS / "GateCore.qml",
        QS / "GateWeb.qml",
        QS / "lucidwidgets" / "GateWidget.qml",
        Path.home() / ".local" / "bin" / "gate",
    ]:
        if target.is_symlink() or target.exists():
            if target.is_dir() and not target.is_symlink():
                shutil.rmtree(target)
            else:
                target.unlink()
            print(f"  removed {target}")
    print("  " + unpatch_shell())
    print("  " + unpatch_widgets())
    print("  state kept in", STATE / "lucid-gate")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--uninstall", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if not (QS / "shell.qml").exists():
        print(f"no quickshell config at {QS}", file=sys.stderr)
        return 2
    if args.uninstall:
        uninstall()
    else:
        install(args.dry_run)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

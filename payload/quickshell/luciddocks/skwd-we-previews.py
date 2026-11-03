#!/usr/bin/env python3
"""Map installed Wallpaper Engine scenes to their own preview image.

skwd's library gives a scene a WebP thumbnail, and some of those do not decode
in Qt. The workshop folder also keeps the author's preview.gif/jpg, which is
what the scene page itself uses. This prints:

    {"we:<id>": {"thumb": "/abs/preview.gif", "preview": "/abs/preview.gif"}}

`preview` is set only for an animated GIF, so the card can play it on hover.
"""

from __future__ import annotations

import json
import os
import sys

WORKSHOP = os.path.expanduser(
    "~/.local/share/Steam/steamapps/workshop/content/431960"
)
NAMES = ("preview.gif", "preview.jpg", "preview.png")


def main() -> int:
    out: dict[str, dict[str, str]] = {}
    try:
        entries = os.listdir(WORKSHOP)
    except OSError:
        json.dump(out, sys.stdout)
        sys.stdout.write("\n")
        return 0

    for scene_id in entries:
        folder = os.path.join(WORKSHOP, scene_id)
        if not os.path.isdir(folder):
            continue
        project = os.path.join(folder, "project.json")
        preferred = ""
        try:
            with open(project, encoding="utf-8") as f:
                preferred = str(json.load(f).get("preview") or "")
        except (OSError, ValueError):
            pass

        candidates = [preferred] + list(NAMES)
        chosen = ""
        for name in candidates:
            if not name or os.path.isabs(name):
                continue
            path = os.path.join(folder, name)
            if os.path.isfile(path):
                chosen = path
                break
        if chosen == "":
            continue

        ext = os.path.splitext(chosen)[1].lower()
        out["we:" + scene_id] = {
            "thumb": chosen,
            "preview": chosen if ext == ".gif" else "",
        }

    json.dump(out, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Backfill Wallhaven tags for pictures already in a local wallpaper folder.

Downloads made through the picker write the sidecar directly. This fills in
wallpapers that were downloaded before that, reading the same API detail and
writing `wallhaven-<id>.json` beside each image. It is resumable: sidecars that
already exist are skipped.

The API key is read from prefs and sent in a header, never in argv.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.request

API = "https://wallhaven.cc/api/v1/w/"
UA = "lucid-shell/1.0 (+wallpaper tags)"
NAME_RE = re.compile(r"^wallhaven-([A-Za-z0-9]+)(?: \(\d+\))?\.(jpg|jpeg|png|webp)$", re.I)
PREF = os.path.expanduser("~/.config/quickshell/lucidprefs/prefs.json")


def fetch(wall_id: str, key: str) -> dict | None:
    request = urllib.request.Request(API + wall_id, headers={"User-Agent": UA})
    if key:
        request.add_header("X-API-Key", key)
    try:
        with urllib.request.urlopen(request, timeout=20) as answer:
            return json.load(answer).get("data") or {}
    except Exception as error:  # noqa: BLE001
        print(f"{wall_id}: {error}", flush=True)
        return None


def sidecar_for(image: str) -> str:
    return os.path.splitext(image)[0] + ".json"


def write_sidecar(image: str, data: dict) -> None:
    tags = [str(t.get("name") or "").strip() for t in (data.get("tags") or [])]
    tags = [t for t in tags if t]
    name = ", ".join(tags) or ("wallhaven-" + str(data.get("id") or ""))
    payload = {
        "id": str(data.get("id") or ""),
        "name": name,
        "tags": tags,
        "url": data.get("url") or "",
        "source": data.get("source") or "",
        "purity": data.get("purity") or "",
        "category": data.get("category") or "",
        "resolution": data.get("resolution") or "",
        "fileSize": data.get("file_size") or 0,
        "colors": data.get("colors") or [],
    }
    target = sidecar_for(image)
    temporary = target + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
    os.replace(temporary, target)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", required=True)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--delay", type=float, default=1.4)
    parser.add_argument("--prefs", default=PREF)
    args = parser.parse_args()

    key = ""
    try:
        with open(args.prefs, encoding="utf-8") as handle:
            key = str(json.load(handle).get("wallhavenApiKey") or "")
    except OSError:
        pass

    try:
        names = sorted(os.listdir(args.dir))
    except OSError as error:
        print(error, flush=True)
        return 1

    pending = []
    for name in names:
        match = NAME_RE.match(name)
        if not match:
            continue
        image = os.path.join(args.dir, name)
        if os.path.exists(sidecar_for(image)):
            continue
        pending.append((match.group(1), image))
    if args.limit > 0:
        pending = pending[:args.limit]
    print(f"backfilling {len(pending)} Wallhaven pictures", flush=True)

    for number, (wall_id, image) in enumerate(pending, 1):
        data = fetch(wall_id, key)
        if data:
            write_sidecar(image, data)
            print(f"[{number}/{len(pending)}] {wall_id}", flush=True)
        if number < len(pending):
            time.sleep(max(0.2, args.delay))
    return 0


if __name__ == "__main__":
    sys.exit(main())

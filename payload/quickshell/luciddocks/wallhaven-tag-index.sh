#!/usr/bin/env bash
# One JSON line per local Wallhaven image that has a tag sidecar:
#   {"path": "...", "name": "...", "tags": [...]}
# The skwd library already supplies the image rows; this adds the Wallhaven
# metadata to them without asking the network.
set -u
DIR="${1:-}"
[ -d "$DIR" ] || exit 0
# One interpreter reads every sidecar. The old loop started jq once per image
# (157 processes, ~350 ms here); this is one process and a handful of file reads.
exec python3 - "$DIR" <<'PY'
import glob, json, os, sys

directory = sys.argv[1]
extensions = (".jpg", ".jpeg", ".png", ".webp", ".avif", ".jxl", ".gif")
for meta in sorted(glob.glob(os.path.join(directory, "wallhaven-*.json"))):
    stem = meta[:-5]
    image = ""
    for ext in extensions:
        if os.path.isfile(stem + ext):
            image = stem + ext
            break
    if image == "":
        continue
    try:
        with open(meta, encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:
        continue
    print(json.dumps({
        "path": image,
        "name": str(data.get("name") or ""),
        "tags": data.get("tags") or [],
    }, ensure_ascii=False, separators=(",", ":")))
PY

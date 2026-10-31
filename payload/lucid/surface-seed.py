#!/usr/bin/env python3
"""Compute the wallpaper's dominant chromatic hue for Theme.surface().

This is deliberately detached from the application fanout: a 4K PNG can take
~0.4 s to decode, and the shell already has a live palette before this runs.
The result is written atomically; Theme.qml watches surface-seed.json and
adopts it on the next frame. The previous seed stays in place until then, so a
wallpaper change never flashes the accent hue through every surface.

Cached by (wallpaper path, mtime, size, palette); a theme toggle on the same
wallpaper costs one shell test, not a decode.
"""
import colorsys
import fcntl
import json
import os
import sys
from collections import Counter


def main() -> int:
    if len(sys.argv) < 5:
        return 2
    wallpaper, palette_path, out, key = sys.argv[1:5]
    thumb = sys.argv[5] if len(sys.argv) > 5 else ""
    source_path = thumb if thumb and os.path.isfile(thumb) else wallpaper
    lock_path = out + ".lock"
    try:
        lock_fd = open(lock_path, "w")
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
    except OSError:
        return 0

    seed = None
    try:
        from PIL import Image

        palette = json.load(open(palette_path))
        primary = str(palette.get("primary", "#808080")).lstrip("#")
        ph = colorsys.rgb_to_hls(*(int(primary[i:i + 2], 16) / 255.0 for i in (0, 2, 4)))[0] * 360.0
        im = Image.open(source_path)
        try:
            # libjpeg draft; ignored for PNG, where the decode is unavoidable
            im.draft("RGB", (160, 160))
        except Exception:
            pass
        im = im.convert("RGB")
        im.thumbnail((160, 160))
        q = im.quantize(colors=16).convert("RGB")
        data = q.get_flattened_data() if hasattr(q, "get_flattened_data") else q.getdata()
        counts = Counter(data)
        total = sum(counts.values()) or 1
        candidates = []
        for rgb, n in counts.most_common():
            h, l, s = colorsys.rgb_to_hls(*(c / 255.0 for c in rgb))
            if n / total < 0.04 or s < 0.08 or l < 0.10 or l > 0.92:
                continue
            hue = h * 360.0
            d = abs(hue - ph) % 360.0
            d = min(d, 360.0 - d)
            candidates.append((n / total, hue, s, d))
        if candidates:
            # prefer a hue clearly apart from the accent, then the dominant one
            far = [c for c in candidates if c[3] >= 35.0]
            pick = max(far or candidates, key=lambda c: c[0])
            seed = {"hue": round(pick[1], 1), "saturation": round(pick[2], 3)}
    except Exception:
        seed = None

    tmp = out + ".tmp"
    with open(tmp, "w") as f:
        json.dump(seed or {}, f)
        f.write("\n")
    os.replace(tmp, out)
    key_path = os.path.join(os.path.dirname(out), "surface-seed.key")
    tmp_key = key_path + ".tmp"
    with open(tmp_key, "w") as f:
        f.write(key)
    os.replace(tmp_key, key_path)
    lock_fd.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

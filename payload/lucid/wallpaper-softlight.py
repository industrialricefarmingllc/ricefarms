#!/usr/bin/env python3
"""Bake the window-background overlay: a heavily blurred wallpaper, soft-light
blended against the surface colour, at 25%.

Doing the blend here keeps every consumer (Quickshell, kitty, GTK) on a plain
static image: no runtime shader, no backdrop capture. Regenerated only when the
wallpaper or the surface colour changes.
"""
import argparse
import colorsys
import hashlib
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageFilter, ImageOps

HOME = os.path.expanduser("~")
CACHE = os.path.join(HOME, ".cache", "quickshell")
KEY = os.path.join(CACHE, "wallpaper-softlight.key")
PATH_FILE = os.path.join(CACHE, "wallpaper-softlight.path")
WALL_STATE = os.path.join(HOME, ".cache", "current_wallpaper")
MIX = 1.0
VERSION = 3


def screen_size():
    try:
        monitors = json.loads(subprocess.check_output(
            ["hyprctl", "monitors", "-j"], stderr=subprocess.DEVNULL))
        monitor = next((m for m in monitors if m.get("focused")), monitors[0] if monitors else None)
        if monitor and monitor.get("width") and monitor.get("height"):
            scale = float(monitor.get("scale") or 1)
            return round(int(monitor["width"]) / scale), round(int(monitor["height"]) / scale)
    except Exception:
        pass
    return 1368, 912


def base_rgb(value):
    value = str(value or "").lstrip("#")
    if len(value) != 6:
        return (0, 0, 0)
    try:
        return tuple(int(value[i:i + 2], 16) / 255.0 for i in (0, 2, 4))
    except ValueError:
        return (0, 0, 0)


def soft_light(base, blend):
    d = np.where(base <= 0.25, ((16 * base - 16) * base + 4) * base, np.sqrt(base))
    return np.where(blend <= 0.5,
                    base - (1 - 2 * blend) * base * (1 - base),
                    base + (2 * blend - 1) * (d - base))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="#000000", help="surface colour behind the overlay")
    args = parser.parse_args()

    try:
        wallpaper = open(WALL_STATE).read().strip()
    except OSError:
        return 1
    if not wallpaper or not os.path.isfile(wallpaper):
        return 1

    width, height = screen_size()
    try:
        stamp = os.stat(wallpaper).st_mtime_ns
    except OSError:
        stamp = 0
    base = base_rgb(args.base)
    key = f"{wallpaper}\t{stamp}\t{width}x{height}\t{args.base}\t{MIX}\t{VERSION}"
    digest = hashlib.sha256(key.encode()).hexdigest()[:12]
    out = os.path.join(CACHE, f"wallpaper-softlight-{digest}.png")

    try:
        if open(PATH_FILE).read().strip() == out and os.path.isfile(out):
            return 0
    except OSError:
        pass

    try:
        image = Image.open(wallpaper).convert("RGB")
        image = ImageOps.fit(image, (width, height), method=Image.LANCZOS)
        # heavy blur, cheap: crush to ~1/16 size, blur, scale back up
        small = image.resize((max(64, width // 4), max(40, height // 4)), Image.LANCZOS)
        small = small.filter(ImageFilter.GaussianBlur(radius=7))
        blurred = np.asarray(small.resize((width, height), Image.BICUBIC), dtype=np.float32) / 255.0
        # a heavily blurred photo against a surface derived from the same photo
        # is nearly flat; stretch its local variation so the 25% layer reads
        mean = blurred.mean(axis=(0, 1), keepdims=True)
        blurred = np.clip((blurred - mean) * 1.8 + mean, 0.0, 1.0)

        b = np.array(base, dtype=np.float32)
        blended = soft_light(b, blurred)
        result = np.clip(b * (1.0 - MIX) + blended * MIX, 0.0, 1.0)
        out_image = Image.fromarray((result * 255.0 + 0.5).astype(np.uint8), "RGB")

        os.makedirs(CACHE, exist_ok=True)
        tmp = out + ".tmp"
        out_image.save(tmp, format="PNG", optimize=True)
        os.replace(tmp, out)
        with open(PATH_FILE, "w") as f:
            f.write(out)
        with open(KEY, "w") as f:
            f.write(key)
        for old in os.listdir(CACHE):
            if old.startswith("wallpaper-softlight-") and old.endswith(".png") and os.path.join(CACHE, old) != out:
                try:
                    os.remove(os.path.join(CACHE, old))
                except OSError:
                    pass
    except Exception as exc:
        print(f"wallpaper-softlight: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

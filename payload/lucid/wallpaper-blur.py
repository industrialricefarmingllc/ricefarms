#!/usr/bin/env python3
"""Generate a heavily blurred, 10%-alpha wallpaper for window backgrounds.

One static PNG, shared by kitty, GTK and Quickshell. No runtime blur or shader:
the expensive work happens only when the wallpaper changes, which keeps
scrolling and window resizes cheap.
"""
import hashlib
import json
import os
import subprocess
import sys

from PIL import Image, ImageFilter, ImageOps

HOME = os.path.expanduser("~")
OUT = os.path.join(HOME, ".cache", "quickshell", "wallpaper-blur.png")
KEY = os.path.join(HOME, ".cache", "quickshell", "wallpaper-blur.key")
WALL_STATE = os.path.join(HOME, ".cache", "current_wallpaper")
ALPHA = 26  # 10% of 255


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


def main():
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
    key = f"{wallpaper}\t{stamp}\t{width}x{height}\t{ALPHA}"
    try:
        if open(KEY).read() == key and os.path.isfile(OUT):
            return 0
    except OSError:
        pass

    try:
        image = Image.open(wallpaper).convert("RGB")
        image = ImageOps.fit(image, (width, height), method=Image.LANCZOS)
        # heavy blur, cheap: crush to ~1/16 size, blur, scale back up
        small = image.resize((max(32, width // 16), max(20, height // 16)), Image.LANCZOS)
        small = small.filter(ImageFilter.GaussianBlur(radius=10))
        image = small.resize((width, height), Image.BICUBIC).convert("RGBA")
        image.putalpha(ALPHA)
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        tmp = OUT + ".tmp"
        image.save(tmp, format="PNG", optimize=True)
        os.replace(tmp, OUT)
        with open(KEY, "w") as f:
            f.write(key)
    except Exception as exc:
        print(f"wallpaper-blur: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

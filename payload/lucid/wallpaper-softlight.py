#!/usr/bin/env python3
"""Bake the window-background overlay: a heavily blurred wallpaper, soft-light
blended against the surface colour, at 25%.

Doing the blend here keeps every consumer (Quickshell, kitty, GTK) on a plain
static image: no runtime shader, no backdrop capture. Regenerated only when the
wallpaper or the surface colour changes.

Performance notes (the overlay is deliberately generated *small*):
  * the wash is a heavily blurred image; a half-resolution texture stretched
    over the screen is visually identical to full resolution, but costs ~4x
    less to decode, blend and write
  * JPEGs are decoded with libjpeg's draft mode, so a 4K photo is never
    materialised at full size just to be reduced to a thumbnail-sized wash
  * the output is a plain PNG at compress_level=1; optimize=True spent most of
    the old 5 s budget on zlib for no visible gain
  * generation is serialised with flock, so a burst of wallpaper changes can
    never run several full-screen blends at once
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys

HOME = os.path.expanduser("~")
CACHE = os.path.join(HOME, ".cache", "quickshell")
KEY = os.path.join(CACHE, "wallpaper-softlight.key")
PATH_FILE = os.path.join(CACHE, "wallpaper-softlight.path")
LOCK = os.path.join(CACHE, "wallpaper-softlight.lock")
WALL_STATE = os.path.join(HOME, ".cache", "current_wallpaper")
MIX = 1.0
VERSION = 7
# 2 = half the screen's logical resolution. Set 1 for full resolution, 3 for
# a third (still fine under a 14 px blur at typical viewing distance).
SCALE = max(1, int(os.environ.get("LUCID_SOFTLIGHT_SCALE", "2")))


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
    import numpy as np
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

    logical_w, logical_h = screen_size()
    width, height = max(1, logical_w // SCALE), max(1, logical_h // SCALE)
    try:
        stamp = os.stat(wallpaper).st_mtime_ns
    except OSError:
        stamp = 0
    base = base_rgb(args.base)
    key = f"{wallpaper}\t{stamp}\t{logical_w}x{logical_h}\t{args.base}\t{MIX}\t{VERSION}\t{SCALE}"
    digest = hashlib.sha256(key.encode()).hexdigest()[:12]
    out = os.path.join(CACHE, f"wallpaper-softlight-{digest}.png")

    # A previous run may have already produced this exact texture; publishing
    # the path is all that is left. This is the common case on a re-apply.
    if os.path.isfile(out):
        try:
            if open(PATH_FILE).read().strip() != out:
                with open(PATH_FILE + ".tmp", "w") as f:
                    f.write(out)
                os.replace(PATH_FILE + ".tmp", PATH_FILE)
        except OSError:
            pass
        return 0

    # One blend at a time. A burst of requests leaves the newest key in the
    # cache; the older caller simply exits and lets the newest one publish.
    try:
        import fcntl
        lock_fd = open(LOCK, "w")
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return 0
    except Exception:
        lock_fd = None

    try:
        from PIL import Image, ImageFilter, ImageOps
        import numpy as np

        image = Image.open(wallpaper)
        # libjpeg draft: decode at ~2x the output size, never at full camera
        # resolution. Other formats ignore it and go through the normal path.
        try:
            image.draft("RGB", (width * 2, height * 2))
        except Exception:
            pass
        image = image.convert("RGB")
        image = ImageOps.fit(image, (width, height), method=Image.LANCZOS)
        # heavy blur, cheap: crush to ~1/4 size, blur, scale back up
        small = image.resize((max(32, width // 4), max(24, height // 4)), Image.LANCZOS)
        small = small.filter(ImageFilter.GaussianBlur(radius=max(3, 14 // SCALE)))
        blurred = np.asarray(small.resize((width, height), Image.BICUBIC), dtype=np.float32) / 255.0
        mean = blurred.mean(axis=(0, 1), keepdims=True)
        blurred = np.clip((blurred - mean) * 1.8 + mean, 0.0, 1.0)

        b = np.array(base, dtype=np.float32)
        blended = soft_light(b, blurred)
        result = np.clip(b * (1.0 - MIX) + blended * MIX, 0.0, 1.0)
        # 8x8 ordered dither: the wash is a near-flat gradient, and the
        # 10/25% alpha quantisation bands visibly on a large screen
        bayer = np.array([
            [0, 32, 8, 40, 2, 34, 10, 42],
            [48, 16, 56, 24, 50, 18, 58, 26],
            [12, 44, 4, 36, 14, 46, 6, 38],
            [60, 28, 52, 20, 62, 30, 54, 22],
            [3, 35, 11, 43, 1, 33, 9, 41],
            [51, 19, 59, 27, 49, 17, 57, 25],
            [15, 47, 7, 39, 13, 45, 5, 37],
            [63, 31, 55, 23, 61, 29, 53, 21],
        ], dtype=np.float32) / 64.0 - 0.5
        tile = np.tile(bayer, (height // 8 + 1, width // 8 + 1))[:height, :width]
        result = np.clip(result + tile[..., None] / 255.0, 0.0, 1.0)
        # bake the screen-bezel squircle corners into the overlay: black and
        # opaque outside the superellipse, the 25% wash inside. This removes a
        # second full-screen shader pass.
        try:
            prefs = json.load(open(os.path.join(HOME, ".config", "quickshell", "lucidprefs", "prefs.json")))
            corner = min(72, round(float(prefs.get("barHeight", 35)) / 2)) / SCALE
            f = float(prefs.get("squircleF", 0.5))
        except (OSError, ValueError, TypeError):
            corner, f = 19 / SCALE, 0.5
        exponent = 2.0 + 4.0 * max(0.0, min(1.0, f))
        alpha = np.full((height, width), 0.25, dtype=np.float32)
        corner = max(1, min(int(round(corner)), height // 2, width // 2))
        yy, xx = np.mgrid[0:corner, 0:corner].astype(np.float32) + 0.5
        edge = exponent / corner
        quads = [
            ((corner - xx) / corner, (corner - yy) / corner),
            (xx / corner, (corner - yy) / corner),
            ((corner - xx) / corner, yy / corner),
            (xx / corner, yy / corner),
        ]
        for i, (qx, qy) in enumerate(quads):
            v = np.power(qx, exponent) + np.power(qy, exponent)
            cover = np.clip((v - 1.0) / edge + 0.5, 0.0, 1.0)
            ys = 0 if i < 2 else height - corner
            xs = 0 if i in (0, 2) else width - corner
            alpha[ys:ys + corner, xs:xs + corner] = 1.0 - (1.0 - alpha[ys:ys + corner, xs:xs + corner]) * (1.0 - cover)
            result[ys:ys + corner, xs:xs + corner] *= (1.0 - cover[..., None])
        out_rgba = np.dstack([np.clip(result, 0.0, 1.0), np.clip(alpha, 0.0, 1.0)])
        out_image = Image.fromarray((out_rgba * 255.0 + 0.5).astype(np.uint8), "RGBA")

        os.makedirs(CACHE, exist_ok=True)
        tmp = out + ".tmp"
        out_image.save(tmp, format="PNG", compress_level=1)
        os.replace(tmp, out)
        # Publish only after the file is complete; readers watch this path.
        with open(PATH_FILE + ".tmp", "w") as f:
            f.write(out)
        os.replace(PATH_FILE + ".tmp", PATH_FILE)
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
    finally:
        if lock_fd is not None:
            lock_fd.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

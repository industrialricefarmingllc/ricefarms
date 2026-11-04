#!/usr/bin/env python3
"""Resolve what Lucid's spatial renderer should play for the current wallpaper.

    spatial-assets.py --path <wallpaper path or skwd:we:<id>>

The picker can show a still, a video, or a Wallpaper Engine scene. The spatial
renderer wants two things in every case:

  motion  what to draw (still, GIF or video)
  poster  one representative frame for the depth model

Workshop scenes use the 10-second background-only recording Lucid already cuts
after an apply when it exists; otherwise the author's preview GIF/picture keeps
the scene animated until that recording lands. Plain videos use their own file.
"""

from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
from pathlib import Path

WORKSHOP = Path.home() / ".local/share/Steam/steamapps/workshop/content/431960"
LIVE = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "lucid/live-previews"
WALLPAPER_EXTS = (".jpg", ".jpeg", ".png", ".webp")
VIDEO_EXTS = (".mp4", ".webm", ".mkv", ".mov", ".m4v")


def live_index() -> dict:
    try:
        return json.loads((LIVE / "index.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def scene_id(path: str) -> str:
    if path.startswith("skwd:we:"):
        return path[8:]
    marker = "/431960/"
    if marker in path:
        tail = path.split(marker, 1)[1].split("/", 1)[0]
        if tail.isdigit():
            return tail
    return ""


def ffprobe_size(path: str) -> tuple[int, int]:
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=width,height", "-of", "json", path],
            capture_output=True, text=True, timeout=10, check=False)
        stream = json.loads(result.stdout or "{}").get("streams", [{}])[0]
        return int(stream.get("width") or 0), int(stream.get("height") or 0)
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0, 0


def _jpeg_size(path: str) -> tuple[int, int] | None:
    try:
        with open(path, "rb") as handle:
            if handle.read(2) != b"\xff\xd8":
                return None
            while True:
                byte = handle.read(1)
                while byte and byte != b"\xff":
                    byte = handle.read(1)
                while byte == b"\xff":
                    byte = handle.read(1)
                if not byte:
                    return None
                marker = byte[0]
                if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
                    continue
                length_bytes = handle.read(2)
                if len(length_bytes) < 2:
                    return None
                length = struct.unpack(">H", length_bytes)[0]
                if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6,
                              0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                    data = handle.read(5)
                    if len(data) < 5:
                        return None
                    height = struct.unpack(">H", data[1:3])[0]
                    width = struct.unpack(">H", data[3:5])[0]
                    return (width, height) if width and height else None
                handle.seek(max(0, length - 2), os.SEEK_CUR)
    except OSError:
        return None


def _header_size(path: str) -> tuple[int, int] | None:
    try:
        with open(path, "rb") as handle:
            head = handle.read(64)
    except OSError:
        return None
    if len(head) < 16:
        return None
    if head[:8] == b"\x89PNG\r\n\x1a\n" and head[12:16] == b"IHDR":
        width, height = struct.unpack(">II", head[16:24])
        return (width, height) if width and height else None
    if head[:6] in (b"GIF87a", b"GIF89a"):
        width, height = struct.unpack("<HH", head[6:10])
        return (width, height) if width and height else None
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        chunk = head[12:16]
        if chunk == b"VP8X":
            width = int.from_bytes(head[24:27], "little") + 1
            height = int.from_bytes(head[27:30], "little") + 1
            return (width, height) if width and height else None
        if chunk == b"VP8L" and head[20] == 0x2F:
            bits = int.from_bytes(head[21:25], "little")
            return (1 + (bits & 0x3FFF), 1 + ((bits >> 14) & 0x3FFF))
        if chunk == b"VP8 ":
            width = int.from_bytes(head[26:28], "little") & 0x3FFF
            height = int.from_bytes(head[28:30], "little") & 0x3FFF
            return (width, height) if width and height else None
    if head[:2] == b"\xff\xd8":
        return _jpeg_size(path)
    return None


def image_size(path: str) -> tuple[int, int]:
    size = _header_size(path)
    if size:
        return size
    # AVIF/HEIF and anything exotic: let Pillow identify it rather than
    # dropping the wallpaper. This path is rare and only pays on a cold apply.
    try:
        from PIL import Image
        with Image.open(path) as image:
            return image.width, image.height
    except Exception:
        return 0, 0


def existing(path: str) -> str:
    return path if path and Path(path).is_file() else ""


def scene_preview(scene: str) -> str:
    directory = WORKSHOP / scene
    preferred = ""
    try:
        preferred = str(json.loads((directory / "project.json").read_text(encoding="utf-8"))
                        .get("preview") or "")
    except (OSError, ValueError):
        pass
    for name in (preferred, "preview.gif", "preview.jpg", "preview.png"):
        if not name or os.path.isabs(name):
            continue
        candidate = directory / name
        if candidate.is_file():
            return str(candidate)
    return ""


def skwd_thumb(scene: str) -> str:
    """The 16:9 frame skwd captured for this scene, as a decodable JPEG.

    skwd writes WebP, and Qt's image loader here has no WebP plugin, so the
    frame is converted once into the spatial poster cache.
    """
    base = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache"))
    source = base / "skwd-wall-v2/we-thumbs" / f"{scene}.webp"
    if not source.is_file():
        return ""
    out_dir = LIVE / "spatial-posters"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"we-{scene}.jpg"
    try:
        if not out.is_file() or out.stat().st_mtime < source.stat().st_mtime:
            from PIL import Image
            with Image.open(source) as image:
                image.convert("RGB").save(out, format="JPEG", quality=92)
    except Exception:
        return ""
    return str(out) if out.is_file() else ""


def preview_matches_screen(path: str) -> bool:
    """True when the author's preview is already close to a screen shape."""
    width, height = image_size(path)
    if width <= 0 or height <= 0:
        # an animated preview is probed as a video
        width, height = ffprobe_size(path)
    if width <= 0 or height <= 0:
        return True
    aspect = width / height
    return 1.45 <= aspect <= 2.1


def emit(value: dict) -> None:
    print(json.dumps(value, separators=(",", ":")))


def main() -> int:
    path = ""
    for index, arg in enumerate(sys.argv):
        if arg == "--path" and index + 1 < len(sys.argv):
            path = sys.argv[index + 1]
    if not path:
        emit({"ok": False, "error": "no wallpaper path"})
        return 0

    entry = live_index()
    suffix = Path(path).suffix.lower()

    # A Workshop video is a real file inside the item directory; classify it
    # as a video before the scene-id check would claim it.
    if suffix in VIDEO_EXTS:
        live = entry.get(path) or {}
        if not live:
            scene = scene_id(path)
            if scene:
                live = entry.get(f"we:{scene}") or {}
        poster = existing(live.get("jpg", ""))
        if not poster:
            poster = existing(live.get("gif", ""))
        if not poster:
            # no preview was cut yet: make the depth sampler a first frame
            poster_dir = LIVE / "spatial-posters"
            poster_dir.mkdir(parents=True, exist_ok=True)
            try:
                digest = __import__("hashlib").sha1(path.encode()).hexdigest()[:16]
            except Exception:
                digest = "video"
            frame = poster_dir / f"{digest}.jpg"
            if not frame.is_file() and subprocess.run(
                    ["ffmpeg", "-v", "error", "-y", "-ss", "1", "-i", path,
                     "-frames:v", "1", "-q:v", "2", str(frame)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    check=False).returncode == 0:
                poster = str(frame)
            elif frame.is_file():
                poster = str(frame)
        width, height = ffprobe_size(path)
        emit({"ok": True, "kind": "video", "key": path, "motion": path,
              "motionKind": "video", "poster": poster,
              "width": width, "height": height})
        return 0

    scene = scene_id(path)
    if scene:
        key = f"we:{scene}"
        live = entry.get(key) or {}
        preview = scene_preview(scene)
        thumb = skwd_thumb(scene)
        motion = existing(live.get("mp4", ""))
        motion_kind = "video" if motion else ""
        if not motion:
            motion = existing(live.get("gif", ""))
            motion_kind = "gif" if motion else ""
        if not motion:
            # The author's preview is often square or a close-up, not the
            # framing the scene actually renders at. Using it as the spatial
            # source puts the depth on the wrong picture. When it does not
            # match the screen shape, fall back to the 16:9 frame skwd itself
            # captured; the scene is static there, but it is the right picture.
            use_preview = preview and preview_matches_screen(preview)
            motion = (preview if use_preview else thumb) or preview
            motion_kind = "gif" if motion and motion.lower().endswith(".gif") else "image"
        poster = existing(live.get("jpg", "")) or (thumb if motion == thumb else "") or preview
        width, height = ffprobe_size(motion) if motion_kind == "video" else image_size(motion)
        emit({"ok": True, "kind": "we", "key": key, "motion": motion,
              "motionKind": motion_kind, "poster": poster,
              "width": width, "height": height,
              "scene": scene})
        return 0

    # a still, including an animated GIF wallpaper
    motion_kind = "gif" if suffix == ".gif" else "image"
    width, height = image_size(path)
    emit({"ok": True, "kind": "image", "key": path, "motion": path,
          "motionKind": motion_kind, "poster": path,
          "width": width, "height": height})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

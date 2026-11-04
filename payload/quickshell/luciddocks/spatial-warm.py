#!/usr/bin/env python3
"""Warm the spatial cache for a folder, one wallpaper at a time.

    spatial-warm.py --model da3-mono --dir ~/Pictures/wallpapers/matugen

Runs the same depth + matte pipeline the picker/apply path uses, so a wallpaper
that has already been warmed applies without generating anything. It is meant
to run at nice 19 on AC power; Lucid stops it on battery and while a real
wallpaper is being generated.

Prints one JSON object per line so a caller can follow it.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import signal
import subprocess
import sys
import time
from pathlib import Path

# The mesh builder is a child process; make sure a pause (SIGTERM from the
# shell) takes it down too instead of leaving it running at nice 19.
_child = None


def _stop(signum, frame):
    global _child
    if _child is not None:
        try:
            _child.terminate()
            _child.wait(timeout=2)
        except Exception:
            try:
                _child.kill()
            except Exception:
                pass
    raise SystemExit(0)


signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT, _stop)

HERE = Path(__file__).resolve().parent
IMAGE_EXTS = (".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif")
STATE_VERSION = 1


def load(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_").replace(".py", ""), HERE / name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def emit(value: dict) -> None:
    print(json.dumps(value, separators=(",", ":")), flush=True)


def frames(directory: Path):
    try:
        entries = sorted(directory.iterdir())
    except OSError:
        return
    for entry in entries:
        if entry.is_file() and entry.suffix.lower() in IMAGE_EXTS:
            yield entry


def identity(path: Path) -> dict:
    stat = path.stat()
    return {
        "size": int(stat.st_size),
        "mtime_ns": int(stat.st_mtime_ns),
        "ctime_ns": int(stat.st_ctime_ns),
        "ino": int(stat.st_ino),
        "dev": int(stat.st_dev),
    }


def load_state(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if value.get("version") == STATE_VERSION and isinstance(value.get("entries"), dict):
            return value["entries"]
    except (OSError, ValueError):
        pass
    return {}


def save_state(path: Path, entries: dict, cache) -> None:
    try:
        cache.write_json(path, {"version": STATE_VERSION, "entries": entries})
    except OSError:
        pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="da3-mono")
    parser.add_argument("--dir", action="append", default=[])
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--pause", type=float, default=0.2)
    parser.add_argument("--aspect", action="append", type=float, default=[])
    parser.add_argument("--image-zoom", type=float, default=1.16)
    parser.add_argument("--mesh-tool",
                        default=str(Path.home() / ".local/bin/kos-mesh-cache"))
    args = parser.parse_args()

    queue = []
    seen = set()
    for directory in args.dir:
        for path in frames(Path(directory).expanduser()):
            key = str(path)
            if key in seen:
                continue
            seen.add(key)
            queue.append(path)

    total = len(queue)
    if total == 0:
        emit({"state": "done", "done": 0, "total": 0})
        return 0

    depth_engine = load("depth-engine.py")
    spatial_prep = load("spatial-prep.py")
    spatial_cache = load("spatial_cache.py")
    aspects = sorted({float(a) for a in args.aspect if a > 0}) or [16 / 9]
    mesh_tool = Path(args.mesh_tool)
    if not mesh_tool.is_file():
        fallback = HERE.parent / "lucidspatial3d/build/out/kos-mesh-cache"
        mesh_tool = fallback if fallback.is_file() else None
    state_path = depth_engine.cache_root() / "warm-state-v1.json"
    state = load_state(state_path)
    signature = {
        "model": args.model,
        "aspects": [round(float(a), 6) for a in aspects],
        "image_zoom": float(args.image_zoom),
    }

    done = 0
    warmed = 0
    for path in queue:
        if args.limit and warmed >= args.limit:
            break
        try:
            marker = identity(path)
            entry = state.get(str(path))
            if (entry and all(entry.get(key) == value for key, value in marker.items())
                    and all(entry.get(key) == value for key, value in signature.items())
                    and all(Path(entry.get(key) or "").is_file()
                            for key in ("depth", "background", "matte", "influence"))):
                # This wallpaper and every output the pipeline depends on are
                # unchanged. A repeat sweep is now a stat, not a second run of
                # two Python imports and a mesh cache lookup.
                warmed += 1
                done += 1
                continue

            depth = depth_engine.generate(path, "", args.model)
            if not depth.get("ok"):
                emit({"state": "skip", "path": str(path), "error": depth.get("error", "")})
                continue
            prep = spatial_prep.prepare(path, Path(depth["depth"]))
            mesh_ok = True
            # The renderer's mesh build is the next-expensive step on a slow
            # device; build it here for every screen shape.
            if mesh_tool is not None and prep.get("matte"):
                try:
                    from PIL import Image
                    with Image.open(path) as image:
                        source_aspect = image.width / max(1, image.height)
                    command = [str(mesh_tool), "--depth", depth["depth"],
                               "--matte", prep["matte"],
                               "--source-aspect", f"{source_aspect:.6f}",
                               "--image-zoom", str(args.image_zoom)]
                    for aspect in aspects:
                        command += ["--aspect", f"{aspect:.6f}"]
                    global _child
                    _child = subprocess.Popen(command, stdout=subprocess.DEVNULL,
                                              stderr=subprocess.DEVNULL)
                    _child.wait()
                    mesh_ok = _child.returncode == 0
                    _child = None
                except Exception as error:  # noqa: BLE001
                    mesh_ok = False
                    emit({"state": "mesh-error", "path": str(path), "error": str(error)})
            if mesh_ok and prep.get("ok"):
                entry = dict(marker)
                entry.update(signature)
                entry.update({
                    "depth": str(depth.get("depth") or ""),
                    "background": str(prep.get("background") or ""),
                    "matte": str(prep.get("matte") or ""),
                    "influence": str(prep.get("influence") or ""),
                })
                state[str(path)] = entry
            warmed += 1
            if not (depth.get("cached") and prep.get("cached")):
                emit({"state": "warmed", "done": warmed, "total": total, "path": str(path)})
        except Exception as error:  # noqa: BLE001 - this is a best-effort warmer
            emit({"state": "error", "path": str(path), "error": str(error)})
        done += 1
        if done % 8 == 0:
            save_state(state_path, state, spatial_cache)
        time.sleep(max(0.0, args.pause))

    save_state(state_path, state, spatial_cache)
    emit({"state": "done", "done": warmed, "total": total})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

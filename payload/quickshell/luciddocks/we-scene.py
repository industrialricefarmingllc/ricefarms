#!/usr/bin/env python3
"""Unpack a Wallpaper Engine scene and find the static picture inside it.

    we-scene.py --scene <workshop id> [--prepare-depth]
    we-scene.py --path skwd:we:<id>

RePKG (``~/.local/bin/repkg``) extracts ``scene.pkg`` into a cache directory.
The scene JSON is then inspected object by object:

  * a visible image object covering the canvas is the static background;
  * particles, text, lights, puppets and animated objects are effects that
    skwd keeps rendering on top.

With ``--prepare-depth`` the background image is sent through Lucid's depth
engine and a small sidecar is written for the patched skwd renderer:

    ~/.cache/liquid-shell/we-depth/<id>.json
    {"layer": "<object id>", "depth": "<png>", "strength": 0.022}

The renderer puts that depth map into the layer texture's alpha channel and
applies a pointer-driven UV parallax to the static image only. Everything skwd
draws after that layer (particle effects, animated objects, text) is untouched.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

CACHE = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache"))
REPKG = Path(os.environ.get("REPKG") or (Path.home() / ".local/bin/repkg"))
WORKSHOP = Path.home() / ".local/share/Steam/steamapps/workshop/content/431960"
EXTRACT = CACHE / "liquid-shell/we-scene"
DEPTH = CACHE / "liquid-shell/we-depth"
PREFS = Path.home() / ".config/quickshell/lucidprefs/prefs.json"
DEPTH_ENGINE = Path.home() / ".config/quickshell/luciddocks/depth-engine.py"
IMAGE_EXTS = (".jpg", ".jpeg", ".png", ".webp")
STRENGTH = 1.0
CONTRACT = "we-scene-v1"


def emit(value: dict) -> None:
    print(json.dumps(value, separators=(",", ":")))
    sys.stdout.flush()


def scene_id(value: str) -> str:
    value = value.strip()
    if value.startswith("skwd:we:"):
        return value[8:]
    if value.startswith("we:"):
        return value[3:]
    marker = "/431960/"
    if marker in value:
        tail = value.split(marker, 1)[1].split("/", 1)[0]
        if tail.isdigit():
            return tail
    return value if value.isdigit() else ""


def number(value, default: float = 0.0) -> float:
    try:
        return float(str(value).split()[0])
    except (TypeError, ValueError, IndexError):
        return default


def vector(value, count: int = 3, default: float = 0.0) -> list[float]:
    try:
        parts = [float(part) for part in str(value).split()]
    except (TypeError, ValueError):
        return [default] * count
    return (parts + [default] * count)[:count]


def truthy(value, default: bool = True) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    return str(value).strip().lower() not in ("", "0", "false", "no")


def load_prefs() -> dict:
    try:
        return json.loads(PREFS.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def extract(scene: str) -> Path | None:
    source = WORKSHOP / scene / "scene.pkg"
    if not source.is_file():
        return None
    target = EXTRACT / scene
    token = target / ".source"
    try:
        stamp = f"{source.stat().st_mtime_ns}|{source.stat().st_size}|{CONTRACT}"
    except OSError:
        return None
    try:
        if token.read_text(encoding="utf-8").strip() == stamp and (target / "scene.json").is_file():
            return target
    except OSError:
        pass
    if not REPKG.is_file():
        return None
    target.mkdir(parents=True, exist_ok=True)
    for old in target.iterdir():
        if old.name == ".source":
            continue
        if old.is_dir():
            shutil.rmtree(old, ignore_errors=True)
        else:
            old.unlink(missing_ok=True)
    result = subprocess.run(
        [str(REPKG), "extract", "-c", "-o", str(target), str(source)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120, check=False)
    if result.returncode != 0 or not (target / "scene.json").is_file():
        return None
    token.write_text(stamp, encoding="utf-8")
    return target


def texture_for(root: Path, model_path: str) -> str:
    """Resolve object -> model -> material -> first colour texture."""
    model = root / model_path
    try:
        model_json = json.loads(model.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    material_path = str(model_json.get("material") or "")
    if material_path == "":
        return ""
    material = root / material_path
    try:
        material_json = json.loads(material.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    names: list[str] = []
    for stage in material_json.get("passes") or []:
        for name in stage.get("textures") or []:
            if isinstance(name, str) and name != "" and name not in names:
                names.append(name)
    if not names:
        return ""
    candidates = [(root / "materials" / name) for name in names]
    found: list[Path] = []
    for base in candidates:
        for ext in IMAGE_EXTS:
            candidate = base.with_suffix(ext)
            if candidate.is_file():
                found.append(candidate)
                break
        else:
            for ext in IMAGE_EXTS:
                candidate = base.parent / (base.name + ext)
                if candidate.is_file():
                    found.append(candidate)
                    break
    # Some packages flatten the texture name into the package root.
    if not found:
        wanted = {Path(name).name + ext for name in names for ext in IMAGE_EXTS}
        found = [
            candidate
            for candidate in root.rglob("*")
            if candidate.is_file() and candidate.name in wanted
        ]
    # The first pass can carry masks as well as the colour texture. The colour
    # image is the largest file in practice.
    found.sort(key=lambda path: path.stat().st_size, reverse=True)
    return str(found[0]) if found else ""


def visible(objects: list[dict]) -> list[dict]:
    out = []
    for item in objects:
        if not truthy(item.get("visible"), True):
            continue
        out.append(item)
    return out


def object_rect(item: dict, canvas: tuple[float, float]) -> tuple[float, float]:
    size = vector(item.get("size"), 2)
    scale = vector(item.get("scale"), 2, 1.0)
    width = abs(size[0] * scale[0])
    height = abs(size[1] * scale[1])
    if width <= 0 or height <= 0:
        return (0.0, 0.0)
    return (width, height)


def dynamic_object(item: dict, texture: str) -> bool:
    for key in ("particle", "puppet", "text", "light", "sound", "animation"):
        if item.get(key) is not None:
            return True
    if texture.lower().endswith(".gif"):
        return True
    return False


def analyse(root: Path) -> dict:
    try:
        scene = json.loads((root / "scene.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return {"ok": False, "error": f"scene.json: {error}"}
    general = scene.get("general") or {}
    ortho = general.get("orthogonalprojection") or {}
    canvas = (max(1.0, number(ortho.get("width"), 1920)), max(1.0, number(ortho.get("height"), 1080)))
    objects = scene.get("objects") or []
    if not isinstance(objects, list):
        return {"ok": False, "error": "scene objects are not a list"}
    candidates = []
    effects = 0
    for item in visible(objects):
        if not isinstance(item, dict):
            continue
        model_path = str(item.get("image") or "")
        if model_path:
            texture = texture_for(root, model_path)
            width, height = object_rect(item, canvas)
            if texture and width > 0 and height > 0 and not dynamic_object(item, texture):
                candidates.append((width * height, item, texture, width, height))
            else:
                effects += 1
        else:
            effects += 1
    if not candidates:
        return {
            "ok": True, "static": False, "effects": effects > 0,
            "canvas": [round(canvas[0]), round(canvas[1])], "scene": root.name,
        }
    candidates.sort(key=lambda row: row[0], reverse=True)
    _, item, texture, width, height = candidates[0]
    # A tiny icon is not the scene's wallpaper. Demand a meaningful share of
    # the canvas; most scenes have one full-canvas background image.
    if width * height < canvas[0] * canvas[1] * 0.4:
        return {
            "ok": True, "static": False, "effects": effects > 0,
            "canvas": [round(canvas[0]), round(canvas[1])], "scene": root.name,
        }
    return {
        "ok": True,
        "static": True,
        "scene": root.name,
        "layer": str(item.get("id") if item.get("id") is not None else ""),
        "name": str(item.get("name") or ""),
        "image": texture,
        "canvas": [round(canvas[0]), round(canvas[1])],
        "width": round(width),
        "height": round(height),
        "effects": effects > 0,
        "static_layers": len(candidates),
    }


def depth_for(image: str, model: str) -> str:
    if not DEPTH_ENGINE.is_file():
        return ""
    try:
        result = subprocess.run(
            ["/usr/bin/python3", str(DEPTH_ENGINE), "--image", image, "--model", model],
            capture_output=True, text=True, timeout=120, check=False)
        data = json.loads(result.stdout or "{}")
        return str(data.get("depth") or "") if data.get("ok") else ""
    except (OSError, ValueError, subprocess.SubprocessError):
        return ""


def prepare(root: Path, info: dict) -> dict:
    sidecar = DEPTH / f"{info['scene']}.json"
    if not info.get("static"):
        sidecar.unlink(missing_ok=True)
        return info
    depth = depth_for(str(info["image"]), str(load_prefs().get("spatialDepthModel") or "da2-vits"))
    if depth == "":
        sidecar.unlink(missing_ok=True)
        info["ok"] = False
        info["error"] = "depth generation failed"
        return info
    DEPTH.mkdir(parents=True, exist_ok=True)
    payload = {
        "scene": info["scene"],
        "layer": info["layer"],
        "depth": depth,
        "strength": STRENGTH,
        "source": info["image"],
        "contract": CONTRACT,
    }
    temporary = sidecar.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    os.replace(temporary, sidecar)
    info["depth"] = depth
    info["sidecar"] = str(sidecar)
    return info


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scene", default="")
    parser.add_argument("--path", default="")
    parser.add_argument("--prepare-depth", action="store_true")
    args = parser.parse_args()
    scene = scene_id(args.scene or args.path)
    if scene == "":
        emit({"ok": False, "error": "not a scene"})
        return 0
    root = extract(scene)
    if root is None:
        # A video item or a scene that no longer unpacks must not keep using
        # an old depth sidecar from an earlier version of the item.
        (DEPTH / f"{scene}.json").unlink(missing_ok=True)
        emit({"ok": False, "scene": scene, "error": "could not unpack scene.pkg"})
        return 0
    info = analyse(root)
    if args.prepare_depth and info.get("ok"):
        info = prepare(root, info)
    emit(info)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

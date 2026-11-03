#!/usr/bin/env python3
"""Local depth map generator for Lucid's spatial wallpapers.

This is the Python half of NextKde's DepthEngine contract. It keeps the same
pinned model, preprocessing, output format and cache layout as their C++ worker
so a machine that already ran NextKde reuses the downloaded model and depth
maps. Lucid calls it for stills, video posters and Wallpaper Engine preview
frames; the QML side turns the resulting 16-bit depth PNG into pointer
parallax.

    depth-engine.py --image <path> [--progress <json-file>]

stdout is one JSON object. Errors are reported in that object rather than as a
traceback, because the QML caller keeps the normal wallpaper visible and only
needs a short message for Settings.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

MODELS = {
    # The original pinned contract: dynamic aspect, ViT-S, disparity output.
    "da2-vits": {
        "id": "depth-anything-v2-small-dynamic",
        "file": "depth_anything_v2_vits_dynamic.onnx",
        "url": (
            "https://github.com/fabio-sim/Depth-Anything-ONNX/releases/download/"
            "v2.0.0/depth_anything_v2_vits_dynamic.onnx"
        ),
        "sha256": "46c4e8eeda3a27f34701831b6a2ec7753d7b38779b215acb5633424703deed8f",
        "contract": "da2-vits-dynamic-aspect518-rgb-imagenet-cubic-refine-uint16-v1",
        "layout": "dynamic",
        "depth_to_disparity": False,
    },
    # Apple Depth Pro, int8 ONNX. Sharpest boundaries of the four; a fixed 1536
    # square and a much heavier forward pass, so it is a deliberate choice for
    # stills rather than the default.
    "depthpro": {
        "id": "depth-pro",
        "file": "depthpro_int8.onnx",
        "url": (
            "https://huggingface.co/onnx-community/DepthPro-ONNX/resolve/main/"
            "onnx/model_int8.onnx"
        ),
        "sha256": "55d0b888b8b01068cd463cd3a93a81816b496547e07e1281ea3f62e96232d6c4",
        "contract": "depthpro-1536-rgb-half-depth-disparity-refine-uint16-v1",
        "layout": "depthpro",
        "depth_to_disparity": True,
        "refine": True,
    },
    # Depth Anything 3 Mono-Large, Apache 2.0. Its export is the any-view graph
    # with a single view; the camera inputs are fed identity matrices. Weights
    # live in a sibling .onnx.data file that onnxruntime loads itself.
    "da3-mono": {
        "id": "depth-anything-3-mono-large",
        "file": "da3mono_large.onnx",
        "url": (
            "https://huggingface.co/SpatialHub/depth-anything-3-onnx/resolve/main/"
            "da3mono_large.onnx"
        ),
        "sha256": "b538e17e626a408229d0786d0cff4e8fe6007c32d11b51e177029187afbc3b17",
        "extras": [{
            "file": "da3mono_large.onnx.data",
            "url": (
                "https://huggingface.co/SpatialHub/depth-anything-3-onnx/resolve/main/"
                "da3mono_large.onnx.data"
            ),
            "sha256": "7468437fe9fa9aeb05d2dd31b53d5c8fafeafa56e275e4c5403491f8a58c8aa7",
        }],
        "contract": "da3-mono-large-504-rgb-imagenet-depth-disparity-refine-uint16-v1",
        "layout": "mono",
        "depth_to_disparity": True,
        "refine": True,
    },
    # Depth Anything 3 Base, Apache 2.0. The exported graph folds the
    # preprocessing in: uint8 RGB, fixed 518x518, depth (far = high) out. The
    # renderer wants near = high, so the map is inverted before it is stored.
    "da3-base": {
        "id": "depth-anything-3-base-518",
        "file": "da3_base_518.onnx",
        "url": (
            "https://huggingface.co/zerochocobo/DepthAnything3_ONNX/resolve/main/"
            "da3_base.onnx"
        ),
        "sha256": "a2230abae51a8a07e52196e8fedc923bdd29630e9b3cc80f085964000ed573fa",
        "contract": "da3-base-square518-rgb-uint8-disparity-refine-uint16-v1",
        "layout": "square518",
        "depth_to_disparity": True,
    },
}
DEFAULT_MODEL = os.environ.get("LUCID_DEPTH_MODEL") or "da2-vits"
MODEL_INPUT = 518
MONO_RES = 504
DEPTHPRO_RES = 1536
MAX_SOURCE_BYTES = 128 * 1024 * 1024
MAX_PIXELS = 64 * 1024 * 1024
MAX_MODEL_PIXELS = 4 * 1024 * 1024
MEAN = (0.485, 0.456, 0.406)
STDDEV = (0.229, 0.224, 0.225)


def cache_root() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "liquid-shell"


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, separators=(",", ":"))
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def progress(path: str, stage: str, received: int = 0, total: int = 0) -> None:
    if not path:
        return
    try:
        write_json(Path(path), {
            "stage": stage,
            "received": int(received),
            "total": int(total),
        })
    except OSError:
        pass


def fail(message: str, code: str = "depth-generation-failed") -> int:
    print(json.dumps({"ok": False, "error": message, "code": code}))
    return 0


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def fetch(url: str, dest: Path, digest: str, progress_file: str) -> None:
    """Download one model file, verify it and install it atomically."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    for stale in dest.parent.glob(dest.name + ".*.part"):
        stale.unlink(missing_ok=True)
    tmp = dest.with_suffix(dest.suffix + f".{os.getpid()}.part")
    request = urllib.request.Request(url, headers={"User-Agent": "lucid-depth/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response, tmp.open("wb") as out:
            total = int(response.headers.get("Content-Length") or 0)
            received = 0
            last = 0.0
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                out.write(chunk)
                received += len(chunk)
                now = time.monotonic()
                if now - last >= 0.25:
                    progress(progress_file, "downloading-model", received, total)
                    last = now
        progress(progress_file, "verifying-model", received, received)
        if sha256_file(tmp) != digest:
            tmp.unlink(missing_ok=True)
            raise RuntimeError("depth model checksum does not match the pinned contract")
        os.replace(tmp, dest)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def ensure_model(name: str, progress_file: str) -> tuple[Path, dict]:
    config = MODELS[name]
    models = cache_root() / "models"
    models.mkdir(parents=True, exist_ok=True)
    model = models / config["file"]
    if not (model.is_file() and sha256_file(model) == config["sha256"]):
        progress(progress_file, "downloading-model", 0, 0)
        fetch(config["url"], model, config["sha256"], progress_file)
    # Some exports keep their weights in a sibling .data file that the graph
    # loads itself; it has to sit next to the .onnx.
    for extra in config.get("extras", ()):
        path = models / extra["file"]
        if path.is_file() and sha256_file(path) == extra["sha256"]:
            continue
        progress(progress_file, "downloading-model", 0, 0)
        fetch(extra["url"], path, extra["sha256"], progress_file)
    return model, config


def model_size(width: int, height: int) -> tuple[int, int]:
    scale = max(518.0 / width, 518.0 / height)
    scaled_width = width * scale
    scaled_height = height * scale
    if scaled_width > 4096.0 or scaled_height > 4096.0:
        raise ValueError("image aspect ratio is outside the model range")

    def multiple_of_14(value: float) -> int:
        return max(518, round(value / 14.0) * 14)

    return multiple_of_14(scaled_width), multiple_of_14(scaled_height)


_SESSIONS = {}


def session_for(model: Path):
    """One ONNX session per model per process (batch warming reuses it)."""
    import onnxruntime as ort

    key = str(model)
    if key in _SESSIONS:
        return _SESSIONS[key]
    options = ort.SessionOptions()
    try:
        threads = int(os.environ.get("LUCID_DEPTH_THREADS") or 4)
    except ValueError:
        threads = 4
    options.intra_op_num_threads = max(1, threads)
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    session = ort.InferenceSession(key, sess_options=options, providers=["CPUExecutionProvider"])
    _SESSIONS[key] = session
    return session


def guided_refine(depth, guide, radius=8, eps=1e-4):
    """Edge-aware refinement with the photo as the guide (guided filter).

    Monocular depth is soft exactly where the image has a hard edge, which is
    what makes hair, wires and foliage smear in the parallax. Pulling the depth
    toward the image's own edges sharpens those boundaries without inventing
    geometry: the filter only redistributes values that are already there.
    """
    import numpy as np
    from scipy.ndimage import uniform_filter

    g = np.asarray(guide, dtype=np.float32)
    if g.ndim == 3:
        g = g.mean(axis=2)
    if g.max() > 1.5:
        g = g / 255.0
    p = np.asarray(depth, dtype=np.float32)
    if g.shape != p.shape:
        return p
    size = int(radius) * 2 + 1
    mean_g = uniform_filter(g, size, mode="nearest")
    mean_p = uniform_filter(p, size, mode="nearest")
    corr_gp = uniform_filter(g * p, size, mode="nearest")
    corr_gg = uniform_filter(g * g, size, mode="nearest")
    var_g = corr_gg - mean_g * mean_g
    cov_gp = corr_gp - mean_g * mean_p
    a = cov_gp / (var_g + eps)
    b = mean_p - a * mean_g
    mean_a = uniform_filter(a, size, mode="nearest")
    mean_b = uniform_filter(b, size, mode="nearest")
    return mean_a * g + mean_b


def generate(source: Path, progress_file: str, model_name: str = DEFAULT_MODEL) -> dict:
    from PIL import Image

    if model_name not in MODELS:
        raise ValueError(f"unknown depth model: {model_name}")
    config = MODELS[model_name]
    model_id = config["id"]
    model_sha = config["sha256"]
    contract = config["contract"]
    square = config["layout"] == "square518"
    mono = config["layout"] == "mono"
    depthpro = config["layout"] == "depthpro"

    if not source.is_file():
        raise FileNotFoundError("image does not exist")
    size = source.stat().st_size
    if size <= 0 or size > MAX_SOURCE_BYTES:
        raise ValueError("image is empty or too large")

    progress(progress_file, "hashing", 0, 0)
    source_hash = sha256_file(source)
    key_input = f"{source_hash}\n{model_sha}\n{contract}".encode()
    key = hashlib.sha256(key_input).hexdigest()
    directory = cache_root() / "wallpapers" / key
    depth_path = directory / "depth.png"
    metadata_path = directory / "metadata.json"

    directory.mkdir(parents=True, exist_ok=True)
    if depth_path.is_file():
        try:
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            with Image.open(depth_path) as cached:
                if (cached.mode in ("I;16", "I", "I;16B")
                        and metadata.get("model_sha256") == model_sha
                        and metadata.get("contract") == contract
                        and metadata.get("source_sha256") == source_hash):
                    return {
                        "ok": True,
                        "depth": str(depth_path),
                        "width": cached.width,
                        "height": cached.height,
                        "cached": True,
                        "model": model_id,
                        "contract": contract,
                    }
        except (OSError, ValueError):
            pass

    import numpy as np
    import onnxruntime as ort

    with Image.open(source) as opened:
        image = opened.convert("RGB")
    if image.width * image.height > MAX_PIXELS:
        raise ValueError("image pixel count is above the limit")

    progress(progress_file, "generating", 0, 0)
    if square:
        # The DA3 export is a fixed 518 square. Fit the wallpaper inside it at
        # its own aspect and pad with replicated edges, so the model sees no
        # black frame; the depth is cropped back before it is enlarged.
        scale = min(MODEL_INPUT / image.width, MODEL_INPUT / image.height)
        content_w = max(14, int(round(image.width * scale)))
        content_h = max(14, int(round(image.height * scale)))
        top = (MODEL_INPUT - content_h) // 2
        left = (MODEL_INPUT - content_w) // 2
        content = image.resize((content_w, content_h), Image.Resampling.BICUBIC)
        padded = np.pad(
            np.asarray(content, dtype=np.uint8),
            ((top, MODEL_INPUT - content_h - top),
             (left, MODEL_INPUT - content_w - left), (0, 0)),
            mode="edge")
        tensor = padded[None, ...]
        expected_out = (1, MODEL_INPUT, MODEL_INPUT)
    elif depthpro:
        # Depth Pro is a fixed 1536 square, normalised to [-1, 1]; it predicts
        # metric depth in metres (far is high), converted to disparity below.
        target = (DEPTHPRO_RES, DEPTHPRO_RES)
        resized = image.resize(target, Image.Resampling.BICUBIC)
        pixels = np.asarray(resized, dtype=np.float32) / 255.0
        pixels = (pixels - 0.5) / 0.5
        tensor = np.transpose(pixels, (2, 0, 1))[None, ...]
        expected_out = (1, DEPTHPRO_RES, DEPTHPRO_RES)
    elif mono:
        # The mono export takes any size that is a multiple of 14 and keeps the
        # image's own aspect: fit the long side to 504, then round both sides.
        scale = min(1.0, MONO_RES / max(image.width, image.height))
        target = (
            max(14, int(round(image.width * scale / 14)) * 14),
            max(14, int(round(image.height * scale / 14)) * 14),
        )
        resized = image.resize(target, Image.Resampling.BICUBIC)
        pixels = np.asarray(resized, dtype=np.float32) / 255.0
        pixels = (pixels - np.asarray(MEAN, dtype=np.float32)) / np.asarray(STDDEV, dtype=np.float32)
        tensor = np.transpose(pixels, (2, 0, 1))[None, None, ...]
        expected_out = (1, 1, target[1], target[0])
    else:
        target = model_size(image.width, image.height)
        if target[0] * target[1] > MAX_MODEL_PIXELS:
            raise ValueError("model input is above the pixel limit")
        resized = image.resize(target, Image.Resampling.BICUBIC)
        pixels = np.asarray(resized, dtype=np.float32) / 255.0
        pixels = (pixels - np.asarray(MEAN, dtype=np.float32)) / np.asarray(STDDEV, dtype=np.float32)
        tensor = np.transpose(pixels, (2, 0, 1))[None, ...]
        expected_out = (1, target[1], target[0])

    model, config = ensure_model(model_name, progress_file)
    session = session_for(model)
    inputs = session.get_inputs()
    outputs = session.get_outputs()
    if depthpro:
        feeds = {inputs[0].name: tensor}
        out_name = next((value.name for value in outputs if value.name == "predicted_depth"),
                        outputs[0].name)
    elif mono:
        names = {value.name for value in inputs}
        if not {"image", "extrinsics_in", "intrinsics_in"} <= names:
            raise RuntimeError(f"mono depth model inputs changed: {sorted(names)}")
        # A single view with no known camera: identity pose and pinhole.
        feeds = {
            "image": tensor,
            "extrinsics_in": np.eye(4, dtype=np.float32)[None, None, ...],
            "intrinsics_in": np.eye(3, dtype=np.float32)[None, None, ...],
        }
        out_name = "depth"
    else:
        if len(inputs) != 1 or len(outputs) != 1:
            raise RuntimeError("depth model does not match the pinned input/output contract")
        expected_type = "tensor(uint8)" if square else "tensor(float)"
        if inputs[0].type != expected_type:
            raise RuntimeError(f"depth model input is {inputs[0].type}, expected {expected_type}")
        feeds = {inputs[0].name: tensor}
        out_name = outputs[0].name

    result = session.run([out_name], feeds)[0]
    raw = np.asarray(result, dtype=np.float32)
    if raw.shape != expected_out:
        raise RuntimeError(f"depth model returned an unexpected shape: {raw.shape}")
    if mono:
        raw = raw[0, 0]
    elif depthpro:
        raw = raw.reshape(expected_out)
        raw = raw[0]
    else:
        raw = raw[0]
    if square:
        raw = raw[top:top + content_h, left:left + content_w]
    if config["depth_to_disparity"]:
        # DA3 reports depth (far is high); the renderer works in disparity, so
        # the near field keeps its contrast instead of being squeezed by the
        # distant sky.
        raw = 1.0 / np.maximum(raw, 1e-3)
    if config.get("refine", True):
        guide = np.asarray(content if square else resized, dtype=np.uint8)
        raw = guided_refine(raw, guide)
    if not np.isfinite(raw).all():
        raise RuntimeError("depth model returned non-finite values")
    minimum = float(raw.min())
    maximum = float(raw.max())
    if maximum <= minimum:
        raise RuntimeError("depth model returned a constant map")

    enlarged = Image.fromarray(raw, mode="F").resize(
        (image.width, image.height), Image.Resampling.BICUBIC)
    values = np.asarray(enlarged, dtype=np.float32)
    normalized = (values - minimum) / (maximum - minimum)
    depth = np.rint(np.clip(normalized, 0.0, 1.0) * 65535.0).astype(np.uint16)

    progress(progress_file, "writing", 0, 0)
    fd, tmp = tempfile.mkstemp(prefix=".depth.", dir=directory)
    os.close(fd)
    tmp_path = Path(tmp)
    try:
        Image.fromarray(depth).save(tmp_path, format="PNG", compress_level=3)
        os.replace(tmp_path, depth_path)
    finally:
        tmp_path.unlink(missing_ok=True)

    metadata = {
        "version": 1,
        "model": model_id,
        "model_sha256": model_sha,
        "contract": contract,
        "source_sha256": source_hash,
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "width": image.width,
        "height": image.height,
    }
    write_json(metadata_path, metadata)
    return {
        "ok": True,
        "depth": str(depth_path),
        "width": image.width,
        "height": image.height,
        "cached": False,
        "model": model_id,
        "contract": contract,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    parser.add_argument("--progress", default="")
    parser.add_argument("--model", default=DEFAULT_MODEL, choices=sorted(MODELS))
    args = parser.parse_args()

    # The first model download is large; serialise writers so two picker
    # actions cannot leave two half-written copies.
    lock_path = cache_root() / ".depth.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock = lock_path.open("w")
    try:
        import fcntl
        fcntl.flock(lock, fcntl.LOCK_EX)
    except (ImportError, OSError):
        pass

    try:
        result = generate(Path(args.image).expanduser(), args.progress, args.model)
    except ModuleNotFoundError as error:
        return fail(
            "Depth engine is missing a runtime package ("
            + str(error.name or "unknown") + "); install python-onnxruntime-cpu",
            "missing-depth-runtime")
    except Exception as error:  # noqa: BLE001 - the JSON is the API
        return fail(str(error))
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

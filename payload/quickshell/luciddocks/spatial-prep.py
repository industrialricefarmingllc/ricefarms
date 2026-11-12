#!/usr/bin/env python3
"""Prepare the layered spatial assets used by the full depth renderer.

Output matches NextKde's `spatial-v4` contract:

    background.png  reconstructed background with the subject filled out
    matte.png       soft foreground subject alpha
    influence.png   near-field motion map

The pinned IS-Net general-use model is used when available. If it fails, a
depth-guided fallback still produces a usable cutout. No Python runtime is
needed by NextKde; this is Lucid's CPU implementation of the same contract.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spatial_cache  # noqa: E402

MODEL_URL = "https://github.com/danielgatis/rembg/releases/download/v0.0.0/isnet-general-use.onnx"
MODEL_SHA256 = "60920e99c45464f2ba57bee2ad08c919a52bbf852739e96947fbb4358c0d964a"
MODEL_ID = "isnet-general-use"
# v17: keep frame-cropped subjects (v16 dropped any cutout that touched the
# top/side edges, so cached depth-fallback mattes for those wallpapers are
# stale and have to be rebuilt).
CONTRACT = "isnet-general-use-softmatte-solidcore-v17"
INPUT = 1024
MAX_DIMENSION = 2560


def cache_root() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "liquid-shell"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def save_png(image, path: Path) -> None:
    import tempfile

    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    os.close(fd)
    try:
        image.save(tmp, format="PNG", compress_level=3)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def write_json(path: Path, value: dict) -> None:
    import tempfile

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


def ensure_model() -> Path:
    import urllib.request

    models = cache_root() / "models"
    models.mkdir(parents=True, exist_ok=True)
    model = models / "isnet-general-use.onnx"
    if model.is_file() and spatial_cache.cached_sha256(model) == MODEL_SHA256:
        return model
    for stale in models.glob("isnet-general-use.onnx.*.part"):
        stale.unlink(missing_ok=True)
    tmp = model.with_suffix(model.suffix + f".{os.getpid()}.part")
    request = urllib.request.Request(MODEL_URL, headers={"User-Agent": "lucid-spatial/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response, tmp.open("wb") as out:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                out.write(chunk)
        if sha256_file(tmp) != MODEL_SHA256:
            raise RuntimeError("foreground model checksum does not match the pinned contract")
        os.replace(tmp, model)
        spatial_cache.store_sha256(model, MODEL_SHA256)
        return model
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def largest_component(mask, minimum_fraction: float, maximum_fraction: float,
                      allow_bottom: bool = False):
    import numpy as np
    from scipy import ndimage

    labels, count = ndimage.label(mask)
    if count == 0:
        return np.zeros_like(mask, dtype=bool)
    total = mask.size
    height = mask.shape[0]
    # One pass for every component's area instead of `labels == index` for
    # each label: a noisy fallback mask can have thousands of components and
    # the old loop was quadratic in the pixel count.
    areas = np.bincount(labels.ravel(), minlength=count + 1)
    bottom_labels = set(labels[height - 1, :].tolist())
    best = 0
    best_area = 0
    for index in range(1, count + 1):
        area = int(areas[index])
        if area < total * minimum_fraction or area > total * maximum_fraction:
            continue
        # A subject cropped by the frame is still the subject. Rejecting any
        # component that touches the top, left or right edge drops the whole
        # model cutout for portraits and close-ups (the mains then survive only
        # in the reconstructed background, so they look like they vanished).
        # Only the bottom edge is filtered, and only for callers that are
        # looking for a floating near field rather than a framed subject.
        if not allow_bottom and index in bottom_labels:
            continue
        if area > best_area:
            best, best_area = index, area
    return labels == best if best else np.zeros_like(mask, dtype=bool)


def fill_small_holes(mask, max_area_fraction: float = 0.025):
    import numpy as np
    from scipy import ndimage

    filled = ndimage.binary_fill_holes(mask)
    holes = filled & ~mask
    if not holes.any():
        return mask
    labels, count = ndimage.label(holes)
    # Same single-pass area lookup as largest_component: a hole-heavy mask
    # used to do one full `labels == index` comparison per hole.
    areas = np.bincount(labels.ravel(), minlength=count + 1)
    maximum = mask.size * max_area_fraction
    keep = areas <= maximum
    keep[0] = False
    return mask | keep[labels]


_SESSIONS = {}


def segment_session(model: Path, threads: int):
    """One IS-Net session per process, so a warm sweep does not reload it."""
    import onnxruntime as ort

    key = (str(model), threads)
    session = _SESSIONS.get(key)
    if session is not None:
        return session
    options = ort.SessionOptions()
    options.intra_op_num_threads = max(1, threads)
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    session = ort.InferenceSession(str(model), sess_options=options,
                                   providers=["CPUExecutionProvider"])
    _SESSIONS[key] = session
    return session


def segment(photo):
    """Return (soft 0..1 alpha, used_model)."""
    import numpy as np
    from PIL import Image
    from scipy import ndimage

    alpha = None
    used_model = False
    try:
        model = ensure_model()
        try:
            threads = int(os.environ.get("LUCID_PREP_THREADS")
                          or os.environ.get("LUCID_DEPTH_THREADS") or 4)
        except ValueError:
            threads = 4
        session = segment_session(model, threads)
        input_info = session.get_inputs()[0]
        output_info = session.get_outputs()[0]
        if (input_info.name != "input_image" or output_info.name != "output_image"
                or input_info.shape != [1, 3, INPUT, INPUT]
                or output_info.shape != [1, 1, INPUT, INPUT]):
            raise RuntimeError("foreground model contract mismatch")

        square = photo.resize((INPUT, INPUT), Image.Resampling.BOX)
        values = np.asarray(square, dtype=np.float32) / 255.0
        values = (values - 0.5) / 1.0
        tensor = np.transpose(values, (2, 0, 1))[None, ...]
        raw = np.asarray(session.run([output_info.name], {input_info.name: tensor})[0],
                         dtype=np.float32)[0, 0]
        minimum, maximum = float(raw.min()), float(raw.max())
        if not np.isfinite(minimum) or not np.isfinite(maximum) or maximum - minimum < 1e-5:
            raise RuntimeError("foreground model returned no range")
        normalized = (raw - minimum) * (255.0 / (maximum - minimum))
        model_alpha = np.clip(np.asarray(Image.fromarray(normalized.astype(np.float32))
            .resize((photo.width, photo.height), Image.Resampling.BICUBIC)), 0, 255)
        proposed = model_alpha > 64
        # Close-up wallpapers put the subject well past the old 60% cap; a
        # near-full-frame matte is still a usable cutout, only a mask that
        # covers the whole picture has no background left to separate.
        proposed = largest_component(proposed, 0.005, 0.92, allow_bottom=True)
        if proposed.any():
            alpha = model_alpha.astype(np.float32) / 255.0
            alpha = np.where(ndimage.binary_dilation(proposed, iterations=8), alpha, 0.0)
            used_model = True
    except Exception:
        alpha = None

    return alpha, used_model


def depth_mask(photo, depth):
    import numpy as np
    from scipy import ndimage

    height, width = depth.shape
    high = depth > 0.55
    high[int(height * 0.78):, :] = False
    high[:, :int(width * 0.12)] = False
    high[:, int(width * 0.88):] = False
    mask = largest_component(high, 0.004, 0.60, allow_bottom=True)
    if mask.any():
        mask = ndimage.binary_closing(mask, iterations=6)
        mask = fill_small_holes(mask)
        return mask

    broad = depth > 0.30
    mask = largest_component(broad, 0.015, 0.55)
    if mask.any():
        mask = ndimage.binary_closing(mask, iterations=4)
        mask = fill_small_holes(mask)
    return mask


def extend_background(photo, subject):
    import numpy as np
    from scipy import ndimage

    height, width = subject.shape
    radius = max(12, int(round(min(width, height) * 0.012)))
    # One EDT to the subject is enough for the fill band; 31 rounds of binary
    # dilation were the slowest part of preparation.
    distance_to_subject = ndimage.distance_transform_edt(~subject)
    hidden = distance_to_subject <= radius
    distance, indices = ndimage.distance_transform_edt(
        hidden, return_distances=True, return_indices=True)
    yy, xx = np.indices((height, width))
    nearest_y = indices[0]
    nearest_x = indices[1]
    reflected_y = 2 * nearest_y - yy
    reflected_x = 2 * nearest_x - xx
    reflected_ok = ((reflected_y >= 0) & (reflected_y < height)
                    & (reflected_x >= 0) & (reflected_x < width)
                    & ~hidden)
    fill_y = np.where(reflected_ok, reflected_y, nearest_y)
    fill_x = np.where(reflected_ok, reflected_x, nearest_x)
    filled = photo.copy()
    filled[hidden] = photo[fill_y[hidden], fill_x[hidden]]

    softened = ndimage.gaussian_filter(filled, sigma=(2.0, 2.0, 0))
    mask = ndimage.gaussian_filter(hidden.astype(np.float32), sigma=1.4)
    mask = mask[..., None]
    blended = softened * mask + photo.astype(np.float32) * (1.0 - mask)
    return np.clip(blended, 0, 255).astype(np.uint8)


def hand_influence(depth, subject):
    import numpy as np
    from scipy import ndimage

    near = (depth > 0.82) & subject
    near = largest_component(near, 0.001, 0.30)
    if not near.any():
        return np.zeros(depth.shape, dtype=np.uint8)
    near = ndimage.maximum_filter(near, size=101)
    near = ndimage.gaussian_filter(near.astype(np.float32), sigma=25.0)
    return np.clip(near * 255.0, 0, 255).astype(np.uint8)


def prepare(image_path: Path, depth_path: Path) -> dict:
    if not image_path.is_file() or not depth_path.is_file():
        raise FileNotFoundError("image or depth map is missing")

    # The stat index makes a cache hit independent of the source size: no
    # 4K decode, no numpy/scipy import, no hash of the whole wallpaper.
    source_hash, source_width, source_height = spatial_cache.source_info(
        image_path, with_size=True)
    if source_width <= 0 or source_height <= 0:
        from PIL import Image
        with Image.open(image_path) as image:
            source_width, source_height = image.width, image.height
    scale = min(1.0, MAX_DIMENSION / max(source_width, source_height))
    width = max(1, round(source_width * scale))
    height = max(1, round(source_height * scale))

    # The matte and the reconstructed background depend only on the picture,
    # not on which depth model produced depth.png. Share them by source hash so
    # switching models does not re-run IS-Net; only the influence map, which
    # uses depth, stays per model.
    shared_dir = cache_root() / "wallpapers" / source_hash / "spatial-v4"
    model_dir = depth_path.parent / "spatial-v4"
    background_path = shared_dir / "background.png"
    matte_path = shared_dir / "matte.png"
    influence_path = model_dir / "influence.png"
    shared_meta = shared_dir / "metadata.json"
    model_meta = model_dir / "metadata.json"

    def valid(meta_path: Path, paths: list[Path]) -> dict | None:
        try:
            metadata = json.loads(meta_path.read_text(encoding="utf-8"))
            if (metadata.get("contract") != CONTRACT
                    or metadata.get("width") != width
                    or metadata.get("height") != height):
                return None
            for path in paths:
                if spatial_cache.png_size(path) != (width, height):
                    return None
            return metadata
        except (OSError, ValueError):
            return None

    shared_metadata = valid(shared_meta, [background_path, matte_path])
    influence_metadata = valid(model_meta, [influence_path])
    if shared_metadata is not None and influence_metadata is not None:
        return {
            "ok": True,
            "background": str(background_path),
            "matte": str(matte_path),
            "influence": str(influence_path),
            "width": width,
            "height": height,
            "segmentation": str(shared_metadata.get("segmentation") or "cached"),
            "contract": CONTRACT,
            "cached": True,
        }

    # Cold path only: the cache above already returned for a fully prepared
    # wallpaper, so the expensive decoders and numpy/scipy imports stay here.
    from PIL import Image
    import numpy as np

    source = Image.open(image_path).convert("RGB")
    with Image.open(depth_path) as opened_depth:
        depth_image = opened_depth.convert("I")
    if (source.width, source.height) != (width, height):
        source = source.resize((width, height), Image.Resampling.LANCZOS)
        depth_image = depth_image.resize((width, height), Image.Resampling.LANCZOS)

    photo = np.asarray(source, dtype=np.uint8)
    depth = np.asarray(depth_image, dtype=np.float32) / 65535.0

    if shared_metadata is not None:
        # Reuse the cutout and the background; only the depth-dependent
        # influence map may still be missing for this model.
        with Image.open(matte_path) as opened_matte:
            alpha = np.asarray(opened_matte.convert("L"), dtype=np.float32) / 255.0
        subject = alpha > (32.0 / 255.0)
        used_model = str(shared_metadata.get("segmentation") or "") == MODEL_ID
    else:
        alpha, used_model = segment(source)
        subject = None
        if alpha is not None:
            subject = alpha > (32.0 / 255.0)
            subject = largest_component(subject, 0.005, 0.92, allow_bottom=True)
        if subject is None or not subject.any():
            subject = depth_mask(photo, depth)
            alpha = None
            used_model = False
        if not subject.any():
            raise RuntimeError("no separable foreground was found")

        subject = fill_small_holes(subject)
        if alpha is None:
            from scipy import ndimage
            core = ndimage.binary_erosion(subject, iterations=1)
            alpha = ndimage.gaussian_filter(core.astype(np.float32), sigma=0.9)
        else:
            from scipy import ndimage
            alpha = ndimage.gaussian_filter(np.clip(alpha, 0, 1), sigma=0.7)
            alpha = np.where(subject, alpha, 0.0)
        # IS-Net keeps a low-confidence alpha across reflective, glassy and
        # low-contrast surfaces, which the 3D pass shows as see-through
        # patches on the subject. Make the interior solid.
        from scipy import ndimage as _nd
        core = _nd.binary_erosion(subject, iterations=max(2, int(round(min(width, height) * 0.004))))
        if core.any():
            alpha = np.where(core, 1.0, alpha)

        background = extend_background(photo, subject)
        shared_dir.mkdir(parents=True, exist_ok=True)
        save_png(Image.fromarray(background, mode="RGB"), background_path)
        save_png(Image.fromarray(np.clip(alpha * 255.0, 0, 255).astype(np.uint8), mode="L"), matte_path)
        write_json(shared_meta, {
            "contract": CONTRACT,
            "width": width,
            "height": height,
            "segmentation": MODEL_ID if used_model else "depth-fallback",
            "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })

    if influence_metadata is None:
        influence = hand_influence(depth, subject)
        model_dir.mkdir(parents=True, exist_ok=True)
        save_png(Image.fromarray(influence, mode="L"), influence_path)
        write_json(model_meta, {
            "contract": CONTRACT,
            "width": width,
            "height": height,
            "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })

    return {
        "ok": True,
        "background": str(background_path),
        "matte": str(matte_path),
        "influence": str(influence_path),
        "width": width,
        "height": height,
        "segmentation": MODEL_ID if used_model else "depth-fallback",
        "contract": CONTRACT,
    }


def main() -> int:
    values = sys.argv[1:]
    image = ""
    depth = ""
    index = 0
    while index < len(values):
        flag = values[index]
        if flag in ("-h", "--help"):
            print("usage: spatial-prep.py --image PATH --depth PATH")
            return 0
        if flag in ("--image", "--depth") and index + 1 < len(values):
            if flag == "--image":
                image = values[index + 1]
            else:
                depth = values[index + 1]
            index += 2
            continue
        print(json.dumps({"ok": False, "error": "unknown argument: " + flag}))
        return 0
    if image == "" or depth == "":
        print(json.dumps({"ok": False, "error": "--image and --depth are required"}))
        return 0
    try:
        result = prepare(Path(image), Path(depth))
    except Exception as error:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": str(error)}))
        return 0
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

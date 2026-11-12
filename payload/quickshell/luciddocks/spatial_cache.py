#!/usr/bin/env python3
"""Shared cache helpers for the spatial wallpaper pipeline.

Hashing a 4K wallpaper or a multi-gigabyte ONNX file on every cache hit is more
expensive than reading the cache. The helpers here keep a small, atomically
rewritten index of (path, size, mtime, ctime, inode) -> content hash, so a
second run can validate an entry with one stat() instead of reading the file.

The index is only a fast path: if the stat identity is missing or changed, the
file is hashed as before. Deleting the index is always safe.
"""

from __future__ import annotations

import hashlib
import json
import os
import struct
from pathlib import Path

INDEX_VERSION = 1
INDEX_LIMIT = 2048
# Model files are hashed once and then validated by stat identity, exactly like
# wallpapers. A cold depth/prep run used to read the whole 99 MB / 178 MB model
# (and seconds for the 1 GB exports) on every process start.
FILE_INDEX = "file-index-v1.json"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def cache_root() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "liquid-shell"


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


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _read_index(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(value, dict) and value.get("version") == INDEX_VERSION:
            entries = value.get("entries")
            if isinstance(entries, dict):
                return entries
    except (OSError, ValueError):
        pass
    return {}


def _stat_key(path: Path) -> dict | None:
    try:
        stat = path.stat()
    except OSError:
        return None
    return {
        "size": int(stat.st_size),
        "mtime_ns": int(stat.st_mtime_ns),
        "ctime_ns": int(stat.st_ctime_ns),
        "ino": int(stat.st_ino),
        "dev": int(stat.st_dev),
    }


def _matches(entry: dict, identity: dict) -> bool:
    for key, value in identity.items():
        if entry.get(key) != value:
            return False
    return True


def source_info(path: Path, with_size: bool = False) -> tuple[str, int, int]:
    """Return (sha256, width, height) for *path*.

    With ``with_size`` false, width and height are 0 unless they were already
    stored by an earlier caller. The stat identity makes a hit O(1) for files
    that have not been replaced; any change falls back to the real hash.
    """
    path = Path(path)
    identity = _stat_key(path)
    index_path = cache_root() / "source-index-v1.json"
    entries = _read_index(index_path)
    key = str(path.resolve())
    entry = entries.get(key)
    fresh = bool(identity and entry and _matches(entry, identity))

    digest = entry.get("sha256") if fresh else ""
    if not digest:
        digest = sha256_file(path)

    width = int(entry.get("width") or 0) if fresh else 0
    height = int(entry.get("height") or 0) if fresh else 0
    if with_size and (width <= 0 or height <= 0):
        from PIL import Image
        with Image.open(path) as image:
            width, height = image.width, image.height

    changed = not fresh or entry.get("sha256") != digest
    if changed or (with_size and (entry.get("width") != width
                                  or entry.get("height") != height)):
        updated = dict(entry) if entry else {}
        if identity:
            updated.update(identity)
        updated["sha256"] = digest
        if width > 0 and height > 0:
            updated["width"] = width
            updated["height"] = height
        entries[key] = updated
        if len(entries) > INDEX_LIMIT:
            for stale in list(entries)[:len(entries) - INDEX_LIMIT]:
                entries.pop(stale, None)
        write_json(index_path, {"version": INDEX_VERSION, "entries": entries})
    return digest, width, height


def _write_file_index(path: Path, entries: dict) -> None:
    if len(entries) > INDEX_LIMIT:
        for stale in list(entries)[:len(entries) - INDEX_LIMIT]:
            entries.pop(stale, None)
    try:
        write_json(path, {"version": INDEX_VERSION, "entries": entries})
    except OSError:
        pass


def store_sha256(path: Path, digest: str) -> None:
    """Remember a hash that the caller already computed and verified."""
    path = Path(path)
    identity = _stat_key(path)
    if not identity:
        return
    index_path = cache_root() / FILE_INDEX
    entries = _read_index(index_path)
    key = str(path.resolve())
    entry = dict(entries.get(key) or {})
    entry.update(identity)
    entry["sha256"] = str(digest)
    entries[key] = entry
    _write_file_index(index_path, entries)


def cached_sha256(path: Path, digest: str | None = None) -> str:
    """SHA-256 of *path*, validated by stat identity when possible.

    If ``digest`` is supplied it is trusted as already computed (the download
    path verifies the temp file before installing it).
    """
    path = Path(path)
    identity = _stat_key(path)
    index_path = cache_root() / FILE_INDEX
    entries = _read_index(index_path)
    key = str(path.resolve())
    entry = entries.get(key)
    if identity and entry and _matches(entry, identity) and entry.get("sha256"):
        return str(entry["sha256"])

    value = str(digest) if digest is not None else sha256_file(path)
    updated = dict(entry) if entry else {}
    if identity:
        updated.update(identity)
    updated["sha256"] = value
    entries[key] = updated
    _write_file_index(index_path, entries)
    return value


def png_ihdr(path: Path) -> tuple[int, int, int, int] | None:
    """Read PNG width, height, bit depth and colour type without decoding."""
    try:
        with open(path, "rb") as handle:
            header = handle.read(33)
    except OSError:
        return None
    if len(header) < 33 or header[:8] != PNG_MAGIC or header[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", header[16:24])
    if width <= 0 or height <= 0:
        return None
    return int(width), int(height), int(header[24]), int(header[25])


def png_size(path: Path) -> tuple[int, int] | None:
    """Read PNG dimensions from the IHDR header without decoding pixels."""
    info = png_ihdr(path)
    return (info[0], info[1]) if info else None

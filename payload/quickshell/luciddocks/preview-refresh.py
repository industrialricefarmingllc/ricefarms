#!/usr/bin/env python3
"""Re-encode Lucid's animated wallpaper card previews at a higher frame rate.

The picker's moving cards play a short GIF cut from the 10s live-preview
recording. This rewrites those GIFs from their source recording without
recapturing the scene:

    preview-refresh.py [--fps 30] [--workers 4] [--force]

Only files inside ~/.cache/lucid/live-previews are touched. Entries whose GIF
is already at the target rate are skipped, so a rerun is cheap.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

HOME = Path.home()
LIVE = Path(os.environ.get("XDG_CACHE_HOME") or (HOME / ".cache")) / "lucid/live-previews"
INDEX = LIVE / "index.json"
PRINT_LOCK = __import__("threading").Lock()


def load_index() -> dict:
    try:
        return json.loads(INDEX.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def gif_fps(path: Path) -> float:
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=avg_frame_rate",
             "-of", "default=nw=1:nk=1", str(path)],
            capture_output=True, text=True, timeout=15, check=False)
        text = result.stdout.strip()
        if "/" in text:
            num, den = text.split("/", 1)
            return float(num) / max(1.0, float(den))
        return float(text or 0)
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0.0


def encode(source: Path, target: Path, fps: int, seconds: float, width: int) -> bool:
    temporary = target.with_name(f".{target.name}.{os.getpid()}.tmp.gif")
    graph = (
        f"fps={fps},scale={width}:-2:flags=lanczos,split[a][b];"
        "[a]palettegen=max_colors=256:stats_mode=diff[p];"
        "[b][p]paletteuse=dither=sierra2_4a"
    )
    try:
        result = subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-t", f"{seconds:g}", "-i", str(source),
             "-vf", graph, str(temporary)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=180, check=False)
        if result.returncode != 0 or not temporary.is_file() or temporary.stat().st_size < 4096:
            temporary.unlink(missing_ok=True)
            return False
        os.replace(temporary, target)
        return True
    except (OSError, subprocess.SubprocessError):
        temporary.unlink(missing_ok=True)
        return False


def jobs() -> list[tuple[str, Path, Path]]:
    index = load_index()
    out: dict[Path, tuple[str, Path]] = {}
    for key, entry in index.items():
        gif = Path(str(entry.get("gif") or ""))
        mp4 = Path(str(entry.get("mp4") or ""))
        if gif.parent != LIVE or not gif.is_file():
            continue
        if not mp4.is_file():
            sibling = LIVE / (gif.stem + ".mp4")
            if sibling.is_file():
                mp4 = sibling
            else:
                # No recording survives: rebuild from the GIF itself. This
                # only changes its timing to 30fps; it cannot add detail.
                mp4 = gif
        out[gif] = (key, mp4)
    # GIFs left by an older index that still have a sibling recording.
    for gif in LIVE.glob("*.gif"):
        if gif in out:
            continue
        sibling = LIVE / (gif.stem + ".mp4")
        out[gif] = (gif.stem, sibling if sibling.is_file() else gif)
    return [(key, source, gif) for gif, (key, source) in out.items()]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--duration", type=float, default=3.0)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()

    try:
        os.nice(19)
    except OSError:
        pass

    all_jobs = jobs()
    if args.limit > 0:
        all_jobs = all_jobs[:args.limit]
    if not args.force:
        all_jobs = [
            (key, source, gif) for key, source, gif in all_jobs
            if gif_fps(gif) + 0.5 < args.fps
        ]
    total = len(all_jobs)
    print(f"re-encoding {total} preview(s) at {args.fps}fps with {args.workers} worker(s)", flush=True)
    if total == 0:
        return 0

    started = time.time()
    done = 0
    failed = 0

    def run(job):
        key, source, gif = job
        before = gif.stat().st_size if gif.is_file() else 0
        ok = encode(source, gif, args.fps, args.duration, args.width)
        after = gif.stat().st_size if gif.is_file() else 0
        return key, ok, before, after

    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
        futures = [pool.submit(run, job) for job in all_jobs]
        for future in as_completed(futures):
            key, ok, before, after = future.result()
            done += 1
            if not ok:
                failed += 1
            with PRINT_LOCK:
                state = "ok" if ok else "FAILED"
                delta = (after - before) / (1024 * 1024) if ok else 0
                print(
                    f"[{done}/{total}] {state} {key} {before/1048576:.1f} -> {after/1048576:.1f} MiB "
                    f"({delta:+.1f})",
                    flush=True)

    elapsed = time.time() - started
    print(f"done in {elapsed/60:.1f} min; {total - failed}/{total} rewritten", flush=True)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())

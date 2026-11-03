#!/usr/bin/env python3
"""Stream the compositor cursor position as `x y` lines at 30 Hz.

A background layer surface with an empty input region never sees pointer
motion, and giving it a real input region would steal clicks from the desktop.
Hyprland's IPC socket is the least invasive way to keep parallax moving while
the pointer is over a widget, a window or empty desktop.
"""

from __future__ import annotations

import json
import os
import socket
import sys
import time

RUNTIME = os.environ.get("XDG_RUNTIME_DIR") or ""
SIGNATURE = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") or ""


def socket_path() -> str:
    path = os.path.join(RUNTIME, "hypr", SIGNATURE, ".socket.sock")
    if SIGNATURE and os.path.isdir(os.path.dirname(path)):
        return path
    root = os.path.join(RUNTIME, "hypr")
    try:
        candidates = [entry.path for entry in os.scandir(root) if entry.is_dir()]
        candidates.sort(key=lambda item: os.stat(item).st_mtime, reverse=True)
        for candidate in candidates:
            socket = os.path.join(candidate, ".socket.sock")
            if os.path.exists(socket):
                return socket
    except OSError:
        pass
    return path


PATH = socket_path()


def position() -> tuple[int, int] | None:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(0.25)
    try:
        sock.connect(PATH)
        sock.sendall(b"j/cursorpos")
        data = bytearray()
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data.extend(chunk)
        value = json.loads(data.decode("utf-8", "replace"))
        return int(value["x"]), int(value["y"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    finally:
        sock.close()


def main() -> int:
    if not PATH or not os.path.exists(os.path.dirname(PATH)):
        return 1

    last = None
    while True:
        now = position()
        if now is not None and now != last:
            last = now
            sys.stdout.write(f"{now[0]} {now[1]}\n")
            sys.stdout.flush()
        time.sleep(1.0 / 30.0)


if __name__ == "__main__":
    raise SystemExit(main())

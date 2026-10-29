#!/usr/bin/env python3
"""Stream window rects per monitor for lucid-overlay.

Hyprland 0.56 posts no geometry events at all (movewindow / movewindowv2 are
gone from the IPC), so a window being dragged, resized or re-tiled can only be
followed by asking. Asking with `hyprctl clients -j` costs ~8ms of CPU per
call, which is far too much at any useful rate; the command socket answers the
same query in ~0.15ms, so this keeps its own connection loop instead.

Output is one JSON line per *change*, per monitor:

    [{"m":"eDP-1","w":10,"s":"","r":[[x,y,w,h,flag],...]}]

  m     monitor name
  w     active workspace id
  s     visible special workspace name ("" when none)
  r     window rects in screen-local logical px
  flag  1 when the window is on that special workspace, else 0

Rects only: the overlay draws a screen-fixed texture clipped to them, so
nothing else about a window matters. The poll slows down when nothing moves
and snaps back to full rate on the first change, so a drag is caught within
one idle tick.

Measured on this machine (eDP-1, 3 windows): ~0.6ms per tick, so 20Hz idle is
~1.2% of a core and 40Hz while something is moving is ~2.5%.
"""
import json
import os
import socket
import sys
import time

IDLE_HZ = 20
ACTIVE_HZ = 40
HOT_FOR = 0.75
HEARTBEAT = 2.0
MONITOR_EVERY = 0.0          # every tick: the active workspace is what tells
                             # a switch to an empty workspace apart
SHELL_CLASSES = {"org.quickshell"}


def socket_path():
    base = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid()), "hypr")
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return ""
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    found = [n for n in names if os.path.exists(os.path.join(base, n, ".socket.sock"))]
    for n in found:
        if sig and n.startswith(sig):
            return os.path.join(base, n, ".socket.sock")
    return os.path.join(base, found[0], ".socket.sock") if found else ""


def ask(path, command):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(path)
        s.sendall(command.encode())
        chunks = []
        while True:
            b = s.recv(65536)
            if not b:
                break
            chunks.append(b)
        return b"".join(chunks)
    finally:
        s.close()


def monitor_frames(monitors):
    """monitor name -> (id, x, y, logical w, h, active ws, special id, special name)"""
    out = []
    for m in monitors:
        special = m.get("specialWorkspace") or {}
        out.append((
            m.get("name", ""),
            m.get("id"),
            m.get("x", 0),
            m.get("y", 0),
            m.get("width", 0) / (m.get("scale") or 1),
            m.get("height", 0) / (m.get("scale") or 1),
            (m.get("activeWorkspace") or {}).get("id"),
            special.get("id") or 0,
            special.get("name") or "",
        ))
    return out


def frame_line(frames, clients):
    monitors = []
    for name, mid, mx, my, lw, lh, active, special_id, special_name in frames:
        rects = []
        for c in clients:
            if c["monitor"] != mid:
                continue
            if c["hidden"] or c["fullscreen"]:
                continue
            if c["class"] in SHELL_CLASSES:
                continue
            ws = c["workspace"]["id"]
            on_special = bool(special_id) and ws == special_id
            if not on_special and ws != active:
                continue
            at = c["at"]
            size = c["size"]
            x, y = at[0] - mx, at[1] - my
            w, h = size[0], size[1]
            if w < 1 or h < 1 or x + w < 1 or y + h < 1 or x > lw - 1 or y > lh - 1:
                continue
            rects.append("[%d,%d,%d,%d,%d]" % (int(x), int(y), int(w), int(h), 1 if on_special else 0))
        monitors.append('{"m":"%s","w":%s,"s":"%s","r":[%s]}'
                         % (name, -1 if active is None else active, special_name, ",".join(rects)))
    return "[" + ",".join(monitors) + "]"


def main():
    path = socket_path()
    if not path:
        sys.stderr.write("hypr-rects: no Hyprland command socket\n")
        return 1
    frames = []
    frames_at = 0.0
    last = None
    sent_at = 0.0
    hot_until = 0.0
    while True:
        try:
            now = time.monotonic()
            if MONITOR_EVERY <= 0 or now - frames_at > MONITOR_EVERY:
                frames = monitor_frames(json.loads(ask(path, "j/monitors")))
                frames_at = now
            line = frame_line(frames, json.loads(ask(path, "j/clients")))
        except Exception as e:                                    # compositor busy or gone
            sys.stderr.write("hypr-rects: %s\n" % e)
            time.sleep(0.5)
            path = socket_path() or path
            frames_at = 0.0
            continue
        now = time.monotonic()
        if line != last:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
            if last is not None:
                hot_until = now + HOT_FOR
            last = line
            sent_at = now
        elif now - sent_at > HEARTBEAT:
            sys.stdout.write(line + "\n")                          # keep the reader alive
            sys.stdout.flush()
            sent_at = now
        time.sleep(1.0 / (ACTIVE_HZ if now < hot_until else IDLE_HZ))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)

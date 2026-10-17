#!/usr/bin/env python3
# Evented half of the launch morph (see services/Morph.qml).
#
# Polling hyprctl for a mapped window costs a process spawn per tick and
# still detects up to a tick late. This holds the compositor's event socket
# open and announces every new window the millisecond it maps, with its
# geometry bundled (one socket1 query per event, ~milliseconds):
#
#   stdout:  OPEN <addr> <class> <title> <x> <y> <w> <h> <wsId> <wsActive> <monId>
#   stderr:  diagnostics only
#
# The overlay covers the window from that first tick (an opaque stand-in
# the morph flies into), so no compositor-side hiding is needed at all -
# and none is attempted: per-window opacity overrides were proven dead
# (accepted with ok, zero visual effect).
#
# If this dies for any reason (compositor restart, missing python) the QML
# side notices the exit and falls back to hyprctl polling - nothing depends
# on this living.
import json
import os
import select
import socket
import sys
import time


def sock(name):
    rt = os.environ.get("XDG_RUNTIME_DIR", "/run/user/1000")
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    if not sig:
        print("morph-events: no HYPRLAND_INSTANCE_SIGNATURE", file=sys.stderr)
        return None
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(os.path.join(rt, "hypr", sig, name))
    except OSError as e:
        print(f"morph-events: cannot open {name}: {e}", file=sys.stderr)
        return None
    return s


def query(cmd):
    # One-shot command socket (the server answers one request per
    # connection, like hyprctl's own invocations).
    rt = os.environ.get("XDG_RUNTIME_DIR", "/run/user/1000")
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(os.path.join(rt, "hypr", sig, ".socket.sock"))
        s.sendall((cmd + "\n").encode())
        s.settimeout(2.0)
        out = b""
        while True:
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            out += chunk
        return out.decode("utf-8", "replace")
    except OSError as e:
        print(f"morph-events: query {cmd} failed: {e}", file=sys.stderr)
        return ""
    finally:
        try:
            s.close()
        except OSError:
            pass


def clean(s):
    return " ".join((s or "").split())


def describe(addr):
    # Geometry + placement for one address, straight after its open event.
    # The event can precede the IPC state by a hair; missing means "fetch
    # again on the QML side", never a guess.
    try:
        clients = json.loads(query("clients -j") or "null")
        monitors = json.loads(query("monitors -j") or "null")
    except ValueError:
        return None
    if not isinstance(clients, list):
        return None
    hit = None
    for c in clients:
        if str(c.get("address", "")) == addr:
            hit = c
            break
    if hit is None:
        return None
    at = hit.get("at") or [0, 0]
    size = hit.get("size") or [0, 0]
    ws = hit.get("workspace") or {}
    wsid = ws.get("id", -1) if isinstance(ws, dict) else ws
    monid = hit.get("monitor", -1)
    active = 0
    if isinstance(monitors, list):
        for m in monitors:
            if m.get("id") == monid:
                aw = m.get("activeWorkspace") or {}
                if (aw.get("id", -2) if isinstance(aw, dict) else aw) == wsid:
                    active = 1
                break
    return (at[0], at[1], size[0], size[1], wsid, active, monid)


def main():
    s2 = sock(".socket2.sock")
    if s2 is None:
        return 1
    # addr -> deadline (monotonic): recently opened windows get their
    # geometry re-reported at streaming cadence so the overlay's cover
    # tracks retile motion instead of chasing it in fetch steps. Two
    # seconds covers any open animation; afterwards the QML settle logic
    # owns the (by then stationary) rect.
    # Seed the focused workspace so flights pin to the launch desktop
    # from the first spawn (see Morph.activeWs).
    try:
        aw0 = json.loads(query("activeworkspace -j") or "null")
        if isinstance(aw0, dict) and "id" in aw0:
            print(f"WS {aw0['id']}", flush=True)
    except ValueError:
        pass
    tracked = {}
    buf = b""
    while True:
        try:
            r, _, _ = select.select([s2], [], [], 0.03)
        except (OSError, ValueError) as e:
            print(f"morph-events: select failed: {e}", file=sys.stderr)
            return 1
        now = time.monotonic()
        if not r:
            # Quiet tick: re-describe whatever is still settling.
            for addr in [a for a, dl in tracked.items() if dl >= now]:
                geo = describe(addr)
                if geo is None:
                    continue
                x, y, w, h, wsid, active, monid = geo
                print(f"GEOM {addr} {x} {y} {w} {h} {wsid} {active} {monid}", flush=True)
            for a in [a for a, dl in tracked.items() if dl < now]:
                del tracked[a]
            continue
        try:
            chunk = s2.recv(65536)
        except OSError as e:
            print(f"morph-events: socket2 read failed: {e}", file=sys.stderr)
            return 1
        if not chunk:
            print("morph-events: socket2 closed", file=sys.stderr)
            return 1
        buf += chunk
        while b"\n" in buf:
            raw, buf = buf.split(b"\n", 1)
            try:
                line = raw.decode("utf-8", "replace")
            except Exception:
                continue
            if line.startswith("workspace>>") or line.startswith("workspacev2>>") or line.startswith("focusedmon>>") or line.startswith("moveworkspace>>") or line.startswith("movewindow>>"):
                try:
                    aw = json.loads(query("activeworkspace -j") or "null")
                    if isinstance(aw, dict) and "id" in aw:
                        print(f"WS {aw['id']}", flush=True)
                except ValueError:
                    pass
                continue
            if not line.startswith("openwindow>>"):
                continue
            # openwindow>>ADDR,WORKSPACE,CLASS,TITLE (title may hold commas)
            parts = line[len("openwindow>>"):].split(",", 3)
            if len(parts) < 3:
                continue
            addr = parts[0].strip()
            if addr and not addr.startswith("0x"):
                addr = "0x" + addr
            cls = clean(parts[2]) if len(parts) > 2 else ""
            title = clean(parts[3]) if len(parts) > 3 else ""
            if not addr:
                continue
            geo = describe(addr)
            if geo is None:
                print(f"OPEN {addr} {cls} {title} 0 0 0 0 -1 0 -1", flush=True)
            else:
                x, y, w, h, wsid, active, monid = geo
                print(f"OPEN {addr} {cls} {title} {x} {y} {w} {h} {wsid} {active} {monid}", flush=True)
                tracked[addr] = time.monotonic() + 2.0


if __name__ == "__main__":
    sys.exit(main())

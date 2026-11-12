#!/usr/bin/env python3
# Ramp a group of mpv processes over five seconds.
#
# usage: ambience-fade.py in <socket:volume>...
#        ambience-fade.py out <socket:volume>...
#
# Each player has its own target volume. "in" sets it from 0 to that target in
# equal steps. "out" subtracts equal steps from whatever volume it currently
# has, then asks it to quit, so a fade-out started mid fade-in still moves
# smoothly downward.

import json
import socket
import sys
import time

mode = sys.argv[1]
specs = sys.argv[2:]

players = []
for spec in specs:
    path, _, target = spec.rpartition(":")
    if path == "" or target == "":
        continue
    try:
        target = float(target)
    except ValueError:
        continue
    players.append([path, target, None])

for player in players:
    path, target, conn = player
    for _ in range(10):
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(path)
            player[2] = sock
            break
        except OSError:
            time.sleep(0.05)

conns = [p for p in players if p[2] is not None]
if not conns:
    sys.exit(0)


def current_volume(conn):
    # a duck or a row drag can leave a player somewhere other than the volume
    # it was started with, so fade out from what it is really playing at,
    # otherwise the last step can stop well above silence.
    try:
        conn.settimeout(1.0)
        conn.sendall(b'{"command":["get_property","volume"]}\n')
        buf = b""
        while b"\n" not in buf:
            chunk = conn.recv(4096)
            if not chunk:
                return None
            buf += chunk
        line = buf.split(b"\n", 1)[0]
        data = json.loads(line.decode())
        value = data.get("data")
        if isinstance(value, (int, float)):
            return float(value)
    except (OSError, ValueError):
        pass
    finally:
        try:
            conn.settimeout(None)
        except OSError:
            pass
    return None


starts = {}
if mode == "out":
    for path, target, conn in conns:
        level = current_volume(conn)
        starts[conn] = target if level is None else level

steps = 50
delay = 0.1

for i in range(1, steps + 1):
    for path, target, conn in conns:
        if mode == "in":
            cmd = {"command": ["set_property", "volume", round(target * i / steps, 2)]}
        else:
            start = starts.get(conn, target)
            cmd = {"command": ["set_property", "volume", round(start * (1 - i / steps), 2)]}
        try:
            conn.sendall((json.dumps(cmd) + "\n").encode())
        except OSError:
            pass
    time.sleep(delay)

if mode == "out":
    for path, target, conn in conns:
        try:
            conn.sendall(b'{"command":["quit"]}\n')
        except OSError:
            pass

for path, target, conn in conns:
    try:
        conn.close()
    except OSError:
        pass

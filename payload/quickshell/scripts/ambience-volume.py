#!/usr/bin/env python3
# Live per-track volume and sound-mode control for one ambience group.
#
# usage: ambience-volume.py <cache-dir> <group> [gain]
#
# Reads lines from stdin:
#   <index> v <volume>   set that track's stored volume
#   <index> f <filter>   set its mpv audio filter graph, or "-" for dry
#   g <gain>             set the automatic overall gain
#   q <index>            mute and quit that player, and forget it
#
# The stored volumes are what the widget draws. The gain is the separate
# duck/solo layer: mpv is always given stored volume times gain, so the widget
# never has to change a row when the score ducks under other audio.
#
# Volumes are re-applied once a second. Filters are only re-sent when they
# change or after a reconnect: a streaming player hands its socket to a looping
# mpv when the first pass ends, and the last mode has to follow it there.

import json
import os
import select
import socket
import sys

cache = sys.argv[1]
group = sys.argv[2]
try:
    gain = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
except ValueError:
    gain = 1.0
gain = max(0.0, min(4.0, gain))

last_volume = {}
last_filter = {}
applied_filter = {}
conns = {}


def connect(index):
    sock = conns.get(index)
    if sock is not None:
        return sock
    path = os.path.join(cache, "ambience-%s-%d.sock" % (group, index))
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(path)
        conns[index] = sock
        applied_filter[index] = None
        return sock
    except OSError:
        return None


def send(index, command):
    sock = connect(index)
    if sock is None:
        return False
    try:
        sock.sendall((json.dumps(command) + "\n").encode())
        # mpv answers every command. This helper never reads them, so a busy
        # drag or a run through the modes would eventually fill the socket and
        # wedge both controls. Drop the replies after each send.
        sock.setblocking(False)
        try:
            while sock.recv(65536):
                pass
        except BlockingIOError:
            pass
        finally:
            sock.setblocking(True)
        return True
    except OSError:
        try:
            sock.close()
        except OSError:
            pass
        conns.pop(index, None)
        applied_filter[index] = None
        return False


def set_volume(index, volume):
    send(index, {"command": ["set_property", "volume", volume]})


def apply_volume(index):
    base = last_volume.get(index)
    if base is None:
        return
    set_volume(index, round(base * gain, 2))


def apply_all_volumes():
    for index in list(last_volume):
        apply_volume(index)


def quit_player(index):
    sock = connect(index)
    if sock is not None:
        try:
            sock.sendall(b'{"command":["set_property","volume",0]}\n')
            sock.sendall(b'{"command":["quit"]}\n')
            # mpv discards a quit that is still in flight when the client
            # closes at once; wait for its reply or the socket to end.
            sock.settimeout(0.5)
            try:
                while True:
                    data = sock.recv(65536)
                    if not data:
                        break
            except (socket.timeout, OSError):
                pass
        except OSError:
            pass
    last_volume.pop(index, None)
    last_filter.pop(index, None)
    applied_filter.pop(index, None)
    conns.pop(index, None)


def set_filter(index, value):
    if applied_filter.get(index) == value:
        return
    af = "" if value == "-" else "lavfi=[%s]" % value
    if send(index, {"command": ["set_property", "af", af]}):
        applied_filter[index] = value


while True:
    readable, _, _ = select.select([sys.stdin], [], [], 1.0)
    if readable:
        line = sys.stdin.readline()
        if not line:
            break
        parts = line.split(maxsplit=2)
        if len(parts) < 2:
            continue
        if parts[0] == "g":
            try:
                gain = max(0.0, min(4.0, float(parts[1])))
            except ValueError:
                continue
            apply_all_volumes()
            continue
        if parts[0] == "q":
            try:
                index = int(parts[1])
            except ValueError:
                continue
            if index >= 0:
                quit_player(index)
            continue
        try:
            index = int(parts[0])
        except ValueError:
            continue
        if index < 0:
            continue
        kind = parts[1]
        value = parts[2].strip() if len(parts) > 2 else ""

        if kind == "v":
            try:
                volume = float(value)
            except ValueError:
                continue
            last_volume[index] = volume
            apply_volume(index)
        elif kind == "f":
            value = value if value != "" else "-"
            last_filter[index] = value
            set_filter(index, value)
    else:
        apply_all_volumes()
        for index, value in list(last_filter.items()):
            set_filter(index, value)

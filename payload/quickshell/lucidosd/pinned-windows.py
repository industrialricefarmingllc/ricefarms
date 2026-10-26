#!/usr/bin/env python3
# the pinned windows' geometry for PinnedWindows.qml, one json line whenever it
# changes. hyprland says nothing when a window moves, so this polls its request
# socket, from a process of its own: dialled from the shell's gui thread, a
# reading that stalls holds hyprland for 5 s. a line on stdin asks for a reading
# now; stdin closing (the shell gone) ends it
import json
import os
import select
import socket
import sys

SOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid()), "hypr",
                    os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", ""), ".socket.sock")
INTERVAL = 0.12


def clients():
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(1.0)
        s.connect(SOCK)
        s.sendall(b"j/clients")
        chunks = []
        while True:
            b = s.recv(65536)
            if not b:
                break
            chunks.append(b)
    return json.loads(b"".join(chunks))


def main():
    last_geo, held, last_line = {}, {}, None
    while True:
        try:
            cs = clients()
        except (OSError, ValueError):
            cs = None
        if isinstance(cs, list):
            out, geo, still = [], {}, {}
            for c in cs:
                if not c.get("pinned") or c.get("mapped") is False or c.get("hidden"):
                    continue
                a = str(c.get("address", "")).removeprefix("0x")
                at, size = c.get("at") or [0, 0], c.get("size") or [0, 0]
                g = (at[0], at[1], size[0], size[1])
                geo[a] = g
                # a window counts as settled once it held still for two readings;
                # one seen for the first time is settled straight away
                still[a] = held.get(a, 0) + 1 if last_geo.get(a) == g else (2 if a not in last_geo else 0)
                out.append({"address": a, "x": g[0], "y": g[1], "w": g[2], "h": g[3],
                            "monitor": c.get("monitor", -1), "fullscreen": (c.get("fullscreen") or 0) > 0,
                            "settled": still[a] >= 2})
            last_geo, held = geo, still
            line = json.dumps(sorted(out, key=lambda w: w["address"]), separators=(",", ":"))
            if line != last_line:
                try:
                    sys.stdout.write(line + "\n")
                    sys.stdout.flush()
                except BrokenPipeError:
                    return
                last_line = line
        ready, _, _ = select.select([0], [], [], INTERVAL)
        if ready and not os.read(0, 4096):
            return


if __name__ == "__main__":
    main()

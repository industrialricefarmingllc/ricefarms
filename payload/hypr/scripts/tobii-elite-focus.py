#!/usr/bin/env python3
"""tobii-elite-focus.py — Tobii Eye Tracker 5 awake ONLY while Elite Dangerous is focused.

Reacts to Hyprland socket2 activewindow events (no polling), so the
subscription that keeps the sensor awake is dropped within milliseconds of
defocus. What remains after that is the driver's own hardcoded ~3s idle
linger ("tracker off: nothing has asked for it for 3s"), which has no config
key (see `tobii games set boguskey 1` for the full key list).

Falls back to 0.2s polling if the Hyprland socket is unavailable.
Single-instance via lockfile. Match overridable: MATCH_CLASS=kitty ...
"""

import fcntl
import json
import os
import signal
import socket
import subprocess
import sys
import time

MATCH_CLASS = os.environ.get("MATCH_CLASS", "steam_app_359320")
RUNTIME = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "tobii-elite-focus")
LOCK = os.path.join(RUNTIME, "lock")
SUBPID = os.path.join(RUNTIME, "sub.pid")
SUBHUB = os.path.join(RUNTIME, "sub.hubpid")
LOG = os.path.join(RUNTIME, "watch.log")
SIG = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
SOCK2 = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "hypr", SIG, ".socket2.sock"
)


def find_socket():
    """Resolve the live (socket path, instance signature).

    Survives compositor restarts and a missing HYPRLAND_INSTANCE_SIGNATURE
    (e.g. under the systemd user service, which starts before Hyprland).
    Returns ("", "") when the compositor is not up yet.
    """
    if SIG and os.path.exists(SOCK2):
        return SOCK2, SIG
    import glob as _glob

    base = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "hypr")
    cands = sorted(
        _glob.glob(os.path.join(base, "*", ".socket2.sock")),
        key=lambda p: os.path.getmtime(p),
    )
    if not cands:
        return "", ""
    return cands[-1], cands[-1].split(os.sep)[-2]


def use_signature(sig):
    """Make child hyprctl calls target this instance."""
    if sig and os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") != sig:
        os.environ["HYPRLAND_INSTANCE_SIGNATURE"] = sig


def log(msg):
    ts = time.strftime("%H:%M:%S") + ".%03d" % (int(time.time() * 1000) % 1000)
    with open(LOG, "a") as f:
        f.write(f"{ts} {msg}\n")


def hub_pid():
    try:
        out = subprocess.run(
            ["pidof", "tobii-gtk"], capture_output=True, text=True
        ).stdout.strip()
        return out.split()[0] if out else ""
    except Exception:
        return ""


def sub_alive():
    try:
        with open(SUBPID) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return pid
    except Exception:
        return 0


def focused_class():
    try:
        out = subprocess.run(
            ["hyprctl", "activewindow", "-j"], capture_output=True, text=True
        ).stdout
        return json.loads(out).get("class", "") if out.strip() else ""
    except Exception:
        return ""


class Gate:
    def __init__(self):
        self.sub = None  # subprocess.Popen or None

    def start_sub(self):
        hub = hub_pid()
        if not hub:
            return
        self.sub = subprocess.Popen(
            ["tobii", "game", "--", "sleep", "1000000"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,  # own pgid so stop kills wrapper+sleep together
        )
        with open(SUBPID, "w") as f:
            f.write(str(self.sub.pid))
        with open(SUBHUB, "w") as f:
            f.write(hub)
        log(f"focus gained -> subscription pid {self.sub.pid} (hub {hub}), sensor waking")

    def stop_sub(self, why="focus lost"):
        pid = self.sub.pid if self.sub else 0
        if self.sub and self.sub.poll() is None:
            try:
                os.killpg(pid, signal.SIGTERM)  # wrapper + its sleep child
            except Exception:
                pass
            try:
                self.sub.wait(timeout=2)
            except Exception:
                try:
                    os.killpg(pid, signal.SIGKILL)
                except Exception:
                    pass
            log(f"{why} -> killed subscription pid {pid}, sensor sleeping (driver linger ~3s)")
        elif pid:
            log(f"{why} -> subscription pid {pid} already gone")
        self.sub = None
        for p in (SUBPID, SUBHUB):
            try:
                os.remove(p)
            except OSError:
                pass

    def sync(self, elite_focused):
        hub = hub_pid()
        want = bool(elite_focused and hub)
        alive = self.sub is not None and self.sub.poll() is None
        try:
            with open(SUBHUB) as f:
                same_hub = f.read().strip() == hub and bool(hub)
        except OSError:
            same_hub = False
        if want and (not alive or not same_hub):
            if alive:
                self.stop_sub("hub changed")
            self.start_sub()
        elif not want and alive:
            self.stop_sub("focus lost" if not elite_focused else "hub gone")


def run(gate):
    """One loop for both worlds: event stream when the compositor is up,
    polling while it is not — rechecking every cycle so neither mode
    sticks forever (e.g. service started before Hyprland)."""
    gate.sync(focused_class() == MATCH_CLASS)
    last_sync = time.time()
    backoff = 1
    while True:
        sock, sig = find_socket()
        use_signature(sig)
        if not sock:
            gate.sync(focused_class() == MATCH_CLASS)
            time.sleep(0.5)
            continue
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(6)
            s.connect(sock)
            log("event stream connected")
            backoff = 1
            buf = b""
            while True:
                try:
                    chunk = s.recv(4096)
                except socket.timeout:
                    chunk = b""
                if not chunk:
                    raise ConnectionError("socket closed")
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        ev, payload = line.decode().split(">>", 1)
                    except ValueError:
                        continue
                    if ev == "activewindow":
                        cls = payload.split(",", 1)[0]
                        gate.sync(cls == MATCH_CLASS)
                    elif ev == "activewindowv2":
                        gate.sync(focused_class() == MATCH_CLASS)
                if time.time() - last_sync > 5:
                    gate.sync(focused_class() == MATCH_CLASS)
                    last_sync = time.time()
        except Exception as e:
            log(f"event stream broken ({e}), retrying in {backoff}s")
            time.sleep(backoff)
            backoff = min(backoff * 2, 10)


def main():
    os.makedirs(RUNTIME, exist_ok=True)
    lockf = open(LOCK, "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(0)
    gate = Gate()

    def bye(*a):
        gate.stop_sub("watcher exiting")
        sys.exit(0)

    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)
    log(f"watcher started (match class: {MATCH_CLASS}, event-driven)")
    run(gate)


if __name__ == "__main__":
    main()

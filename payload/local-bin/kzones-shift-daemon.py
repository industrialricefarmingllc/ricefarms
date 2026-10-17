#!/usr/bin/env python3
"""
KZones Shift daemon - monitors Shift keys via raw evdev and writes shiftPressed to kwinrc
Requires Shift to be held to show KZones overlay (when requireShift=true)
"""
import os, struct, select, glob, time, errno, sys, subprocess

SHIFT_CODES = {42, 54}  # KEY_LEFTSHIFT, KEY_RIGHTSHIFT
EV_KEY = 0x01
STATE_FILE = "/tmp/kzones_shift"  # also keep for debugging

def find_plasma_bus():
    # Find plasmashell environ to get DBUS_SESSION_BUS_ADDRESS
    import glob as g
    for proc in g.glob("/proc/[0-9]*/environ"):
        try:
            with open(proc, 'rb') as f:
                data = f.read()
            if b'plasmashell' in data or b'PLASMA' in data:
                # Check if contains DBUS
                if b'DBUS_SESSION_BUS_ADDRESS' in data:
                    parts = data.split(b'\x00')
                    for p in parts:
                        if p.startswith(b'DBUS_SESSION_BUS_ADDRESS='):
                            return p.split(b'=',1)[1].decode()
        except: pass
    # Fallback try reading from known pid
    try:
        with open(f"/proc/{os.popen('pgrep -x plasmashell').read().strip()}/environ", 'rb') as f:
            data=f.read()
            for p in data.split(b'\x00'):
                if p.startswith(b'DBUS_SESSION_BUS_ADDRESS='):
                    return p.split(b'=',1)[1].decode()
    except: pass
    return None

def write_state(pressed):
    # Write to /tmp/kzones_shift for debugging and also to kwinrc via kwriteconfig
    # atomic write to /tmp
    try:
        tmp = STATE_FILE + ".tmp"
        with open(tmp, 'w') as f:
            f.write("1" if pressed else "0")
            f.flush()
            os.fsync(f.fileno())
        os.rename(tmp, STATE_FILE)
    except Exception as e:
        print(f"write_state file err: {e}", file=sys.stderr)
    # Write to kwinrc via kwriteconfig6
    try:
        val = "true" if pressed else "false"
        # Try with plasma bus env to ensure notification? But kwriteconfig doesn't need dbus, just file
        subprocess.run(["kwriteconfig6","--file","kwinrc","--group","Script-kzones","--key","shiftPressed", val], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Also set requireShift true if not already
        # Trigger KWin reconfigure via plasma bus
        bus = find_plasma_bus()
        if bus:
            env = os.environ.copy()
            env["DBUS_SESSION_BUS_ADDRESS"] = bus
            # Find XDG_RUNTIME_DIR for bus
            env["XDG_RUNTIME_DIR"] = f"/run/user/{os.getuid()}"
            subprocess.run(["qdbus6","org.kde.KWin","/KWin","reconfigure"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            # fallback without bus
            subprocess.run(["qdbus6","org.kde.KWin","/KWin","reconfigure"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        print(f"write_state kwinrc err: {e}", file=sys.stderr)

def find_keyboard_devices():
    devices = []
    try:
        with open('/proc/bus/input/devices') as f:
            content = f.read()
        blocks = content.split('\n\n')
        for b in blocks:
            if 'Handlers=' not in b:
                continue
            if 'kbd' not in b:
                continue
            for line in b.split('\n'):
                if 'Handlers=' in line:
                    import re
                    for m in re.finditer(r'event(\d+)', line):
                        ev = m.group()
                        path = f"/dev/input/{ev}"
                        if os.path.exists(path):
                            devices.append(path)
    except Exception as e:
        print(f"find error {e}", file=sys.stderr)
    if not devices:
        devices = glob.glob("/dev/input/event*")
    return sorted(set(devices))

def main():
    devices = find_keyboard_devices()
    print(f"[kzones-shift] monitoring {devices}", file=sys.stderr)
    fds = {}
    key_state = {}
    global_pressed = False
    # Initial state
    write_state(False)
    poll_fds = []
    for path in devices:
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            fds[fd] = path
            poll_fds.append(fd)
        except Exception as e:
            print(f"[kzones-shift] failed to open {path}: {e}", file=sys.stderr)
    if not poll_fds:
        print("[kzones-shift] no devices opened, exiting", file=sys.stderr)
        sys.exit(1)
    print(f"[kzones-shift] opened {len(poll_fds)} devices", file=sys.stderr)
    try:
        while True:
            r, _, _ = select.select(poll_fds, [], [], 0.5)
            for fd in r:
                try:
                    data = os.read(fd, 24*64)
                    if not data:
                        continue
                    for offset in range(0, len(data), 24):
                        chunk = data[offset:offset+24]
                        if len(chunk) < 24:
                            break
                        try:
                            t, c, v = struct.unpack_from('<HHi', chunk, 16)
                        except:
                            continue
                        if t != EV_KEY:
                            continue
                        if c not in SHIFT_CODES:
                            continue
                        if v == 1:
                            key_state[(fd,c)] = True
                        elif v == 0:
                            key_state[(fd,c)] = False
                        new_global = any(key_state.values())
                        if new_global != global_pressed:
                            global_pressed = new_global
                            write_state(global_pressed)
                            print(f"[kzones-shift] shift {'pressed' if global_pressed else 'released'} (code {c} val {v} from {fds[fd]})", file=sys.stderr)
                except OSError as e:
                    if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                        continue
                    elif e.errno == errno.ENODEV:
                        try: os.close(fd)
                        except: pass
                        if fd in poll_fds: poll_fds.remove(fd)
                        if fd in fds: del fds[fd]
                    else:
                        print(f"[kzones-shift] read err {e} on {fds.get(fd,'unknown')}", file=sys.stderr)
                except Exception as e:
                    print(f"[kzones-shift] loop err {e}", file=sys.stderr)
    except KeyboardInterrupt:
        pass
    finally:
        for fd in list(fds.keys()):
            try: os.close(fd)
            except: pass

if __name__ == "__main__":
    main()

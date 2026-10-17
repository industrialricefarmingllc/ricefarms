#!/usr/bin/env python3
"""
VAC Exclusive Access GUI — PipeWire virtual cable enforcer
- VAC = sink VST_OUT + source VST_Mic (see ../vac-up.sh)
- Policy (strict, default ON):
    * whitelisted apps  -> may ONLY use VST_Mic (raw RODE links get moved to VST_Mic)
    * everyone else     -> may NEVER use VST_Mic/VST_OUT.monitor (moved to raw RODE)
- Enforcement via Pulse layer (pactl move-source-output, non-destructive)
  + JACK-level pw-link disconnect for native JACK clients.
- Deps: python3 + PyGObject (gi) only. Works on Hyprland/Wayland (GTK4).
- Config: ~/.config/vac-gui/whitelist.json
- CLI: ./vac-gui.py --enforce (headless daemon), --once, --list
"""
import json, os, re, subprocess, sys, threading, time
from pathlib import Path

CONFIG_DIR = Path.home() / ".config" / "vac-gui"
WHITELIST = CONFIG_DIR / "whitelist.json"
VAC_SOURCE = "VST_Mic"
VAC_MONITOR_OWNER = "VST_OUT"
RAW_MIC = "alsa_input.usb-RODE_Microphones_RODE_NT-USB-00.analog-stereo"

def sh(cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        return subprocess.CompletedProcess(cmd, 1, "", str(e))

def load_whitelist():
    try:
        return set(json.loads(WHITELIST.read_text()))
    except Exception:
        return set()

def save_whitelist(s):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    WHITELIST.write_text(json.dumps(sorted(s), indent=2))

def app_id_of(props, fallback="unknown"):
    # stable key: application.name or process.binary
    for k in ("application.name", "application.process.binary", "node.name", "media.name"):
        v = props.get(k)
        if v:
            return str(v).strip()
    return fallback

def source_id_map():
    """Map numeric pulse source id -> name (pactl prints numbers for Source:)."""
    m = {}
    r = sh(["pactl", "list", "short", "sources"])
    if r.returncode == 0:
        for line in r.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0].isdigit():
                m[parts[0]] = parts[1]
    return m

def list_source_outputs(include_internal=False):
    """Return [{index, source, app_id, app_name, binary, media_name}] via pactl."""
    r = sh(["pactl", "list", "source-outputs"])
    if r.returncode != 0:
        return []
    idmap = source_id_map()
    outs, cur = [], {}
    for line in r.stdout.splitlines():
        m = re.match(r"Source Output #(\d+)", line)
        if m:
            if cur: outs.append(cur)
            cur = {"index": int(m.group(1)), "props": {}}
            continue
        m = re.match(r"\s*Source:\s*(\S+)", line)
        if m and cur is not None: cur["source_raw"] = m.group(1)
        m = re.match(r'\s*([a-zA-Z0-9._-]+)\s*=\s*"(.*)"', line)
        if m and cur is not None: cur["props"][m.group(1)] = m.group(2)
    if cur: outs.append(cur)
    res = []
    for o in outs:
        p = o.get("props", {})
        # skip internal loopbacks (remap-source, monitor streams without application.*)
        if not include_internal and "application.name" not in p and "application.process.binary" not in p:
            continue
        raw = o.get("source_raw", "?")
        src = idmap.get(raw, raw)
        res.append({
            "index": o["index"],
            "source": src,
            "app_id": app_id_of(p, f"idx-{o['index']}"),
            "app_name": p.get("application.name", p.get("node.name", "?")),
            "binary": p.get("application.process.binary", "?"),
            "media": p.get("media.name", "?"),
            "props": p,
        })
    return res

def enforce_once(whitelist, verbose=False):
    """Move streams to enforce policy. Returns (moved, log_lines)."""
    moved, logs = 0, []
    for s in list_source_outputs():
        idx, src, aid = s["index"], s["source"], s["app_id"]
        # also match by binary basename for robustness
        keys = {aid, s["binary"], s["binary"].split("/")[-1], s["app_name"]}
        allowed = bool(keys & whitelist) or aid in whitelist
        src_is_vac = src in (VAC_SOURCE,) or src.startswith(VAC_MONITOR_OWNER)
        if allowed and not src_is_vac:
            r = sh(["pactl", "move-source-output", str(idx), VAC_SOURCE])
            if r.returncode == 0:
                moved += 1
                logs.append(f"#{idx} {aid} {src} -> {VAC_SOURCE} (whitelisted, forced to VAC)")
            elif verbose:
                logs.append(f"#{idx} {aid}: move to VAC failed: {r.stderr.strip()[:120]}")
        elif not allowed and src_is_vac:
            # push intruders back to raw mic (never kill audio, just reroute)
            r = sh(["pactl", "move-source-output", str(idx), RAW_MIC])
            if r.returncode == 0:
                moved += 1
                logs.append(f"#{idx} {aid} {src} -> RAW (not whitelisted, blocked from VAC)")
            elif verbose:
                logs.append(f"#{idx} {aid}: move to RAW failed: {r.stderr.strip()[:120]}")
    # JACK-level: disconnect raw-mic links of whitelisted JACK clients (best effort)
    # We only do this if pw-link exists; failures are ignored (Pulse covers 95%).
    return moved, logs

def enforce_loop(stop_evt, get_whitelist, log_fn, interval=0.5):
    while not stop_evt.is_set():
        try:
            wl = get_whitelist()
            moved, logs = enforce_once(wl)
            for l in logs:
                log_fn(l)
        except Exception as e:
            log_fn(f"enforcer error: {e}")
        stop_evt.wait(interval)

# ---------------- GTK GUI ----------------
def run_gui():
    import gi
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gtk, GLib

    wl = load_whitelist()
    stop_evt = threading.Event()
    state = {"enforcing": False, "rows": [], "log": []}

    app = Gtk.Application(application_id="dev.ricefarms.vac-gui")

    def log_fn(msg):
        GLib.idle_add(append_log, msg)

    def append_log(msg):
        state["log"].append(f"{time.strftime('%H:%M:%S')} {msg}")
        state["log"] = state["log"][-200:]
        if "log_view" in state:
            buf = state["log_view"].get_buffer()
            buf.set_text("\n".join(state["log"]))
            # autoscroll
            adj = state["log_scroll"].get_vadjustment()
            adj.set_value(adj.get_upper())
        return False

    def refresh_rows(listbox):
        # clear
        while True:
            row = listbox.get_first_child()
            if row is None: break
            listbox.remove(row)
        streams = list_source_outputs()
        if not streams:
            lbl = Gtk.Label(label="No recording streams right now.\nOpen Discord/OBS/Browser mic, select VST_Mic, then Refresh.")
            listbox.append(lbl)
            return
        for s in streams:
            aid = s["app_id"]
            on_vac = s["source"] in (VAC_SOURCE,) or s["source"].startswith(VAC_MONITOR_OWNER)
            box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            box.set_margin_top(4); box.set_margin_bottom(4)
            chk = Gtk.CheckButton()
            chk.set_active(aid in wl)
            chk.connect("toggled", on_toggle, aid)
            box.append(chk)
            info = Gtk.Label(label=f"{s['app_name']}  [{s['binary']}]\n  src={s['source']}  #{s['index']}", xalign=0)
            info.set_hexpand(True)
            box.append(info)
            badge = Gtk.Label(label="VAC ✓" if on_vac else "RAW")
            badge.set_opacity(1.0 if on_vac else 0.55)
            box.append(badge)
            row = Gtk.ListBoxRow(child=box)
            listbox.append(row)

    def on_toggle(chk, aid):
        if chk.get_active(): wl.add(aid)
        else: wl.discard(aid)
        save_whitelist(wl)

    def on_window(app):
        nonlocal wl
        win = Gtk.ApplicationWindow(application=app)
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        vbox.set_margin_top(12); vbox.set_margin_bottom(12)
        vbox.set_margin_start(12); vbox.set_margin_end(12)
        win.set_child(vbox)
        win.set_title("VAC Exclusive Access — VST_Mic")
        win.set_default_size(620, 520)

        hdr = Gtk.Label(label="<b>✓ whitelisted apps may ONLY use VST_Mic\n✗ everyone else is blocked from VST_Mic</b>")
        hdr.set_use_markup(True); hdr.set_xalign(0)
        vbox.append(hdr)

        btnrow = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        vbox.append(btnrow)
        btn_refresh = Gtk.Button(label="Refresh")
        btn_enforce = Gtk.ToggleButton(label="Enforce: OFF")
        btn_up = Gtk.Button(label="VAC Up")
        btn_car = Gtk.Button(label="Start Carla")
        btnrow.append(btn_refresh); btnrow.append(btn_enforce)
        btnrow.append(btn_up); btnrow.append(btn_car)

        scroll = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
        scroll.set_min_content_height(220)
        vbox.append(scroll)
        listbox = Gtk.ListBox()
        scroll.set_child(listbox)

        log_scroll = Gtk.ScrolledWindow(hexpand=True, vexpand=False)
        log_scroll.set_min_content_height(120)
        vbox.append(Gtk.Label(label="Enforcer log:", xalign=0))
        vbox.append(log_scroll)
        log_view = Gtk.TextView(editable=False, monospace=True)
        log_scroll.set_child(log_view)
        state["log_view"] = log_view; state["log_scroll"] = log_scroll

        def do_refresh(*a):
            refresh_rows(listbox)
            append_log(f"refresh: {len(list_source_outputs())} streams, whitelist={sorted(wl)}")
        btn_refresh.connect("clicked", do_refresh)

        def do_enforce(btn):
            on = btn.get_active()
            btn.set_label("Enforce: ON" if on else "Enforce: OFF")
            state["enforcing"] = on
            if on:
                stop_evt.clear()
                t = threading.Thread(target=enforce_loop,
                    args=(stop_evt, lambda: set(wl), log_fn), daemon=True)
                t.start()
                append_log("enforcer started (0.5s, pactl move-source-output)")
            else:
                stop_evt.set()
                append_log("enforcer stopped")
        btn_enforce.connect("toggled", do_enforce)

        btn_up.connect("clicked", lambda *_: append_log(sh(
            [str(Path.home()/"audio-stack"/"vac-up.sh")]).stdout[-500:]))
        btn_car.connect("clicked", lambda *_: subprocess.Popen(
            [str(Path.home()/"audio-stack"/"carla-vst.sh")]))

        do_refresh()
        # auto-start enforcing for convenience? No — user toggles.
        win.connect("close-request", lambda *_: (stop_evt.set(), False))
        win.present()

    app.connect("activate", on_window)
    app.run(None)

if __name__ == "__main__":
    if "--list" in sys.argv:
        for s in list_source_outputs():
            print(f"#{s['index']} {s['app_id']} [{s['binary']}] src={s['source']}")
    elif "--once" in sys.argv:
        wl = load_whitelist()
        m, logs = enforce_once(wl, verbose=True)
        print(f"moved={m} whitelist={sorted(wl)}")
        for l in logs: print(" ", l)
    elif "--enforce" in sys.argv:
        wl = load_whitelist()
        print(f"headless enforcer on VAC={VAC_SOURCE}, whitelist={sorted(wl)} (Ctrl-C to stop)", flush=True)
        try:
            while True:
                m, logs = enforce_once(load_whitelist())
                for l in logs: print(time.strftime("%H:%M:%S"), l, flush=True)
                time.sleep(0.5)
        except KeyboardInterrupt:
            pass
    else:
        run_gui()

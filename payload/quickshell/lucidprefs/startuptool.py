#!/usr/bin/env python3
"""What Settings > Startup reads and changes outside Lucid's own data file.

Modes, each printing one JSON object:
  list             every entry in ~/.config/autostart and the system's
                   autostart folders, whether it is on, whether it is meant
                   for this desktop, and whether the session starts them
  set <id> on|off  turns one entry on or off the way the spec says: a copy in
                   ~/.config/autostart with Hidden=true hides a system entry,
                   and taking that copy away shows it again
  config           the apps modules/autostart.lua starts and the variables
                   modules/env.lua sets, and what this machine has that the
                   page's suggestions go by
  take '<json>'    comments out lines of those two files, [{file, line, text,
                   moved}], each only if it still reads as the page saw it

Only the user's autostart folder and those two files are written; the
system's entries are never touched, and a line is commented out, not deleted.
"""

import glob
import json
import os
import re
import shutil
import subprocess
import sys

HOME = os.path.expanduser("~")
CONFIG_HOME = os.environ.get("XDG_CONFIG_HOME") or f"{HOME}/.config"
USER_DIR = f"{CONFIG_HOME}/autostart"
# a copy Settings made only to hide a system entry; turning it back on deletes it
MARK = "X-Lucid-Hidden-Copy"
HYPR = f"{CONFIG_HOME}/hypr/modules"
FILES = {"autostart": f"{HYPR}/autostart.lua", "env": f"{HYPR}/env.lua"}
# what a line becomes when the page takes it over, or drops a second start
MOVED = "-- moved to Lucid Settings > Startup: "
DROPPED = "-- taken out by Lucid Settings > Startup, it started twice: "

# the variables Settings > Environment writes into env.lua
ENVIRONMENT_PAGE = {"XCURSOR_THEME", "XCURSOR_SIZE", "QS_ICON_THEME", "QT_QPA_PLATFORMTHEME"}
# what Lucid's own autostart.lua starts: the wallpaper daemon, and the cursor
# plugin and the shell through the locals that hold their scripts
LUCID_PROGRAMS = {"awww-daemon", "swww-daemon", "quickshell", "qs"}
LUCID_LOCALS = re.compile(r"\.\.\s*(cursor|launcher)\b")

# one call on one line with one plain string, the shape the page can move
STRING = r"""("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')"""
EXEC_SIMPLE = re.compile(r"^\s*hl\.exec_cmd\(\s*" + STRING + r"\s*\)\s*;?\s*(--.*)?$")
ENV_SIMPLE = re.compile(r"^\s*hl\.env\(\s*" + STRING + r"\s*,\s*" + STRING + r"\s*(,\s*(true|false)\s*)?\)\s*;?\s*(--.*)?$")


def system_dirs():
    dirs = os.environ.get("XDG_CONFIG_DIRS") or "/etc/xdg"
    return [f"{d}/autostart" for d in dirs.split(":") if d]


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


# the [Desktop Entry] group as key -> value, unlocalised keys only
def entry(text):
    out, inside = {}, False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("["):
            inside = s == "[Desktop Entry]"
            continue
        if not inside or not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        k = k.strip()
        if "[" not in k:
            out.setdefault(k, v.strip())
    return out


def truthy(v):
    return str(v).strip().lower() == "true"


def split_list(v):
    return [x for x in (v or "").split(";") if x]


def desktops():
    return [d for d in (os.environ.get("XDG_CURRENT_DESKTOP") or "Hyprland").split(":") if d]


# whether the entry is meant for this desktop, and if not why
def applies(e):
    mine = [d.lower() for d in desktops()]
    only = split_list(e.get("OnlyShowIn"))
    if only and not any(d.lower() in mine for d in only):
        return False, "only " + ", ".join(only)
    nots = split_list(e.get("NotShowIn"))
    if any(d.lower() in mine for d in nots):
        return False, "not for " + ", ".join(nots)
    # systemd runs these through a unit of its own, not from this entry
    if truthy(e.get("X-systemd-skip")):
        return False, "systemd starts it itself"
    return True, ""


# the program an Exec line runs, without env and field codes
def program(e):
    words = [w for w in (e.get("Exec") or "").split() if not w.startswith("%")]
    while words and (words[0] == "env" or "=" in words[0]):
        words.pop(0)
    return words[0] if words else ""


def installed(e):
    probe = e.get("TryExec") or program(e)
    if not probe:
        return True
    if "/" in probe:
        return os.access(probe, os.X_OK)
    return shutil.which(probe) is not None


def target_state():
    try:
        r = subprocess.run(["systemctl", "--user", "is-active", "xdg-desktop-autostart.target"],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() or "unknown"
    except Exception:
        return "unknown"


def files():
    """id -> {user, system}: the user's copy wins, the first system dir wins"""
    found = {}
    for d in system_dirs():
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            if n.endswith(".desktop"):
                found.setdefault(n[:-8], {}).setdefault("system", f"{d}/{n}")
    try:
        names = sorted(os.listdir(USER_DIR))
    except OSError:
        names = []
    for n in names:
        if n.endswith(".desktop"):
            found.setdefault(n[:-8], {})["user"] = f"{USER_DIR}/{n}"
    return found


def listing():
    out = []
    for id_, where in sorted(files().items()):
        path = where.get("user") or where.get("system")
        text = read(path)
        if text is None:
            continue
        e = entry(text)
        if e.get("Type", "Application") != "Application":
            continue
        ok, why = applies(e)
        out.append({
            "id": id_,
            "name": e.get("Name") or id_,
            "comment": e.get("Comment", ""),
            "icon": e.get("Icon", ""),
            "exec": e.get("Exec", ""),
            "program": os.path.basename(program(e)),
            "enabled": not truthy(e.get("Hidden")) and e.get("X-GNOME-Autostart-enabled", "true").lower() != "false",
            "applies": ok,
            "reason": why,
            "installed": installed(e),
            "system": "system" in where,
            "user": "user" in where,
            "copy": truthy(e.get(MARK)),
        })
    return {"ok": True, "target": target_state(), "desktops": desktops(), "entries": out}


# the text with key=value set in [Desktop Entry], or the key removed for None
def with_key(text, key, value):
    lines = text.splitlines()
    start = next((i for i, l in enumerate(lines) if l.strip() == "[Desktop Entry]"), None)
    if start is None:
        lines = ["[Desktop Entry]"] + lines
        start = 0
    end = next((i for i in range(start + 1, len(lines)) if lines[i].strip().startswith("[")), len(lines))
    hit = [i for i in range(start + 1, end) if lines[i].split("=", 1)[0].strip() == key]
    for i in reversed(hit[1:]):
        del lines[i]
    if hit:
        if value is None:
            del lines[hit[0]]
        else:
            lines[hit[0]] = f"{key}={value}"
    elif value is not None:
        # after the last key of the group, so trailing blank lines stay put
        at = end
        while at > start + 1 and not lines[at - 1].strip():
            at -= 1
        lines.insert(at, f"{key}={value}")
    return "\n".join(lines) + "\n"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".lucid-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def set_entry(id_, on):
    if not id_ or "/" in id_ or id_.startswith("."):
        return {"ok": False, "error": "bad id"}
    where = files().get(id_)
    if not where:
        return {"ok": False, "error": f"no autostart entry {id_}"}
    user = where.get("user")
    if on:
        if user:
            text = read(user) or ""
            e = entry(text)
            if truthy(e.get(MARK)) and where.get("system"):
                os.remove(user)
            else:
                text = with_key(text, "Hidden", None)
                if e.get("X-GNOME-Autostart-enabled", "").lower() == "false":
                    text = with_key(text, "X-GNOME-Autostart-enabled", "true")
                write(user, text)
    else:
        if user:
            write(user, with_key(read(user) or "", "Hidden", "true"))
        else:
            text = read(where["system"]) or ""
            text = with_key(with_key(text, "Hidden", "true"), MARK, "true")
            write(f"{USER_DIR}/{id_}.desktop", text)
    # systemd's generator turns the entries into units: read them again so a
    # session manager running now sees the change
    try:
        subprocess.run(["systemctl", "--user", "daemon-reload"], capture_output=True, timeout=20)
    except Exception:
        pass
    return {"ok": True}


def lua_string(tok):
    body = tok[1:-1]
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), body)


def shell_program(cmd):
    words = cmd.replace("'", " ").replace('"', " ").split()
    i = 0
    while i < len(words) and (words[i] in ("exec", "env", "command", "-v") or "=" in words[i] or words[i].startswith("-")):
        i += 1
    # "command -v x >/dev/null && exec x" runs x
    if i < len(words) and "&&" in words:
        tail = words[words.index("&&") + 1:]
        if tail:
            return shell_program(" ".join(tail))
    return os.path.basename(words[i]) if i < len(words) else ""


def config_lines():
    apps, env = [], []
    for kind, path in FILES.items():
        text = read(path)
        if text is None:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            code = line.strip()
            if not code or code.startswith("--"):
                continue
            if kind == "autostart" and "hl.exec_cmd" in code:
                m = EXEC_SIMPLE.match(line)
                cmd = lua_string(m.group(1)) if m else ""
                prog = shell_program(cmd) if m else ""
                own = prog in LUCID_PROGRAMS or bool(LUCID_LOCALS.search(code))
                apps.append({"file": kind, "path": path, "line": n, "text": line,
                             "cmd": cmd or code, "program": prog, "simple": bool(m), "lucid": own})
            elif kind == "env" and "hl.env" in code:
                m = ENV_SIMPLE.match(line)
                name = lua_string(m.group(1)) if m else ""
                env.append({"file": kind, "path": path, "line": n, "text": line,
                            "name": name or code, "value": lua_string(m.group(2)) if m else "",
                            "simple": bool(m), "lucid": name in ENVIRONMENT_PAGE})
    return apps, env


def gpu_vendors():
    names = {"0x10de": "nvidia", "0x8086": "intel", "0x1002": "amd"}
    out = set()
    for card in glob.glob("/sys/class/drm/card[0-9]*/device/vendor"):
        v = (read(card) or "").strip()
        out.add(names.get(v, v))
    return sorted(out)


def hyprctl_json(*args):
    try:
        r = subprocess.run(["hyprctl", "-j", *args], capture_output=True, text=True, timeout=5)
        return json.loads(r.stdout or "null")
    except Exception:
        return None


def facts():
    zero = hyprctl_json("getoption", "xwayland:force_zero_scaling") or {}
    mons = hyprctl_json("monitors") or []
    return {
        "gpus": gpu_vendors(),
        "libvaNvidia": os.path.exists("/usr/lib/dri/nvidia_drv_video.so"),
        "java": shutil.which("java") is not None or os.path.isdir("/usr/lib/jvm"),
        "zeroScaling": bool(zero.get("bool") or zero.get("int")),
        "maxScale": max([float(m.get("scale") or 1) for m in mons] or [1]),
    }


def config():
    apps, env = config_lines()
    return {"ok": True, "apps": apps, "env": env, "facts": facts()}


def take(items):
    done, failed = [], []
    by_file = {}
    for it in items:
        by_file.setdefault(it.get("file"), []).append(it)
    for kind, its in by_file.items():
        path = FILES.get(kind)
        text = read(path) if path else None
        if text is None:
            failed += its
            continue
        lines = text.splitlines()
        for it in its:
            i = int(it.get("line", 0)) - 1
            # the file changed since the page read it: leave it be
            if i < 0 or i >= len(lines) or lines[i] != it.get("text"):
                failed.append(it)
                continue
            indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
            lines[i] = indent + (MOVED if it.get("moved", True) else DROPPED) + lines[i].strip()
            done.append(it)
        if any(d.get("file") == kind for d in done):
            write(path, "\n".join(lines) + ("\n" if text.endswith("\n") else ""))
    return {"ok": not failed, "done": done, "failed": failed}


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "list":
        json.dump(listing(), sys.stdout)
    elif cmd == "set" and len(sys.argv) == 4 and sys.argv[3] in ("on", "off"):
        json.dump(set_entry(sys.argv[2], sys.argv[3] == "on"), sys.stdout)
    elif cmd == "config":
        json.dump(config(), sys.stdout)
    elif cmd == "take" and len(sys.argv) == 3:
        try:
            items = json.loads(sys.argv[2])
        except json.JSONDecodeError as e:
            json.dump({"ok": False, "error": f"bad json: {e}"}, sys.stdout)
            sys.stdout.write("\n")
            return 1
        json.dump(take(items if isinstance(items, list) else []), sys.stdout)
    else:
        json.dump({"ok": False, "error": "usage: startuptool.py list | set <id> on|off | config | take '<json>'"}, sys.stdout)
        sys.stdout.write("\n")
        return 1
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

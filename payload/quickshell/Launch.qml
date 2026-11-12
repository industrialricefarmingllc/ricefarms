pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs

// One door for every app launch, so the launch placeholder is not only for
// apps picked in the launcher.
//
// QML callers use launch()/runArgv(). Launches that start outside the shell
// (Hyprland binds, the `$` run mode's external siblings, scripts) drop a
// request in $XDG_RUNTIME_DIR/lucid-launch and raise quickshell:launch; the
// shell claims it here and starts it through the same ghost. The helper
// (`scripts/lucid-launch`) falls back to a plain detached exec if the shell
// never claims the request, so a dead or reloading shell can never swallow a
// launch.
//
// The ghost can only hold one tile at a time. Requests wait for it, but a
// request that has waited too long is started directly instead of leaving the
// app behind a queue.
Singleton {
    id: root

    // the LaunchGhost pool Dock.qml registers on completion. Each ghost holds
    // one tile, so a burst of launches takes one each instead of serializing
    // behind a single state machine.
    property var ghosts: []

    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
    readonly property string requestDir: root.runtimeDir + "/lucid-launch"
    readonly property string helper: Qt.resolvedUrl("scripts/launch-detached.sh").toString().replace("file://", "")
    // a URL opens in the default browser; these let a placeholder match a new
    // window even when the browser process is already running and carries no
    // fresh launch token
    readonly property var browserClasses: ["helium", "zen", "zen-browser", "firefox", "librewolf", "chromium", "brave-browser", "google-chrome", "vivaldi", "opera", "qutebrowser", "floorp"]
    // a launch that cannot get a tile by then is started without one
    readonly property int waitMs: 2000

    // [{ info, at }], oldest first
    property var queue: []
    property var seenRuns: ({})
    property bool pollAgain: false
    // window address -> the ghost that matched it. A burst of the same app
    // produces several windows with the same class; without this a ghost whose
    // token failed would class-match another launch's window.
    property var claimed: ({})

    // ---- helpers ---------------------------------------------------------

    function shQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    function argvLine(argv) {
        return (argv || []).map(root.shQuote).join(" ");
    }

    function token() {
        return "lucid-" + Date.now() + "-" + Math.floor(Math.random() * 1e9);
    }

    function focusedScreen() {
        return Monitors.focusedScreen || (Quickshell.screens.length > 0 ? Quickshell.screens[0] : null);
    }

    function addGhost(g) {
        if (!g || root.ghosts.indexOf(g) >= 0)
            return;
        root.ghosts = root.ghosts.concat([g]);
        root.pump();
    }

    function removeGhost(g) {
        root.ghosts = root.ghosts.filter((x) => {
            return x !== g;
        });
    }

    function availableGhost() {
        for (var i = 0; i < root.ghosts.length; i++) {
            if (root.ghosts[i] && root.ghosts[i].available)
                return root.ghosts[i];
        }
        return null;
    }

    // launches still looking for their first window. With more than one, the
    // class match is ambiguous (a burst of the same app), so only the launch
    // token may claim a window.
    function waitingCount() {
        var n = 0;
        for (var i = 0; i < root.ghosts.length; i++) {
            var p = root.ghosts[i] ? root.ghosts[i].phase : "idle";
            if (p === "preparing" || p === "waiting")
                n++;
        }
        return n;
    }

    // tokens of launches that are still on screen. A window carrying one of
    // these belongs to that launch. A window carrying any other token comes
    // from a long-lived app process (Nautilus, Steam, …) whose old launch
    // token has no relation to the window that just opened; it must be
    // class-matched like a tokenless window.
    function activeTokens() {
        var out = [];
        for (var i = 0; i < root.ghosts.length; i++) {
            var g = root.ghosts[i];
            if (g && g.token !== "" && g.phase !== "idle")
                out.push(g.token);
        }
        return out.join(" ");
    }

    // the held tiles and ghost surfaces are real toplevels, but they are not
    // windows the user can use. Keep them out of the launcher's window rows,
    // the window switcher and the running-apps list.
    function isGhostWindow(o) {
        if (!o || String(o.class || "") !== "org.quickshell")
            return false;
        var title = String(o.title || "");
        return title.indexOf("lucid-launch-placeholder") === 0
            || title.indexOf("lucid-launch-ghost") === 0
            || title.indexOf("Launching ") === 0;
    }

    function classesMatch(cls, want) {
        if (!cls || !want)
            return false;
        var c = String(cls).toLowerCase();
        var w = String(want).toLowerCase();
        if (c === w)
            return true;
        var cn = c.replace(/[-_. ]/g, "");
        var wn = w.replace(/[-_. ]/g, "");
        if (cn === wn)
            return true;
        if (c.endsWith("." + w) || w.endsWith("." + c))
            return true;
        var cf = c.split(/[-_.]/)[0];
        var wf = w.split(/[-_.]/)[0];
        return cf.length >= 3 && cf === wf;
    }

    // the browser window a link should go to, best first: focused, then the
    // current workspace, then the most recently used
    function browserWindow(classes) {
        Hyprland.refreshToplevels();
        var focus = Hyprland.activeToplevel && Hyprland.activeToplevel.lastIpcObject
            ? String(Hyprland.activeToplevel.lastIpcObject.address || "") : "";
        var ws = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1;
        var best = null;
        var bestScore = -1;
        var list = Hyprland.toplevels.values;
        for (var i = 0; i < list.length; i++) {
            var o = list[i].lastIpcObject;
            if (!o || !o.address || !o.class || root.isGhostWindow(o))
                continue;

            var hit = false;
            for (var j = 0; j < classes.length; j++) {
                if (root.classesMatch(o.class, classes[j])) {
                    hit = true;
                    break;
                }
            }
            if (!hit)
                continue;

            var score = 0;
            if (o.address === focus)
                score += 1000;
            if (o.workspace && Number(o.workspace.id) === Number(ws))
                score += 500;
            var fh = Number(o.focusHistoryID);
            if (isFinite(fh))
                score += Math.max(0, 200 - fh);
            if (score > bestScore) {
                bestScore = score;
                best = o;
            }
        }
        return best;
    }

    property string focusAddress: ""

    function focusWindow(addr) {
        if (!addr)
            return;
        root.focusAddress = addr;
        focusHold.restart();
    }

    Timer {
        id: focusHold

        interval: 120
        onTriggered: {
            if (root.focusAddress !== "")
                Hyprland.dispatch("hl.dsp.focus({ window = \"address:" + root.focusAddress + "\" })");
        }
    }

    function claimWindow(addr, ghost) {
        if (!addr)
            return;
        var m = Object.assign({}, root.claimed);
        m[addr] = ghost;
        root.claimed = m;
    }

    function windowOwner(addr) {
        return root.claimed[addr] || null;
    }

    function isClaimed(addr, ghost) {
        var owner = root.windowOwner(addr);
        return owner !== null && owner !== ghost;
    }

    function releaseWindow(addr) {
        if (!addr || root.claimed[addr] === undefined)
            return;
        var m = Object.assign({}, root.claimed);
        delete m[addr];
        root.claimed = m;
    }

    // the launcher tells the overlays where it lives before an icon is picked
    function prepare(screen) {
        for (var i = 0; i < root.ghosts.length; i++) {
            if (root.ghosts[i] && root.ghosts[i].phase === "idle" && !root.ghosts[i].warming)
                root.ghosts[i].prepare(screen);
        }
    }

    function setTrace(on) {
        for (var i = 0; i < root.ghosts.length; i++) {
            if (root.ghosts[i])
                root.ghosts[i].trace = on;
        }
    }

    function ghostStatus(g) {
        return {
            "slot": g.slot,
            "ready": g.ready,
            "phase": g.phase,
            "placeholder": g.placeholderAddr,
            "parked": g.placeholderParked,
            "moveMs": g.moveAnimMs,
            "target": g.targetWs,
            "overlayScreen": g.overlayScreen ? g.overlayScreen.name : "",
            "overlayWs": g.overlayWorkspace,
            "warming": g.warming,
            "shown": g.launchWorkspaceShown,
            "ghostPlaced": g.ghostPlaced,
            "pin": {
                "on": g.pinning,
                "ws": g.pinWs,
                "class": g.pinClass
            },
            "stats": g.stats
        };
    }

    function status() {
        var out = [];
        for (var i = 0; i < root.ghosts.length; i++)
            out.push(root.ghostStatus(root.ghosts[i]));
        return JSON.stringify({
            "count": out.length,
            "waiting": root.waitingCount(),
            "ghosts": out
        });
    }

    function screenAt(x, y) {
        for (var i = 0; i < Quickshell.screens.length; i++) {
            var s = Quickshell.screens[i];
            if (x >= s.x && x < s.x + s.width && y >= s.y && y < s.y + s.height)
                return s;
        }
        return null;
    }

    // the middle of the window the user is in, in global coordinates
    function activeRect() {
        Hyprland.refreshToplevels();
        var t = Hyprland.activeToplevel;
        var o = t && t.lastIpcObject ? t.lastIpcObject : null;
        if (!o || !o.at || !o.size)
            return null;

        var n = Math.max(24, Theme.dp(56));
        return {
            "x": o.at[0] + o.size[0] / 2 - n / 2,
            "y": o.at[1] + o.size[1] / 2 - n / 2,
            "width": n,
            "height": n
        };
    }

    function centerRect(screen) {
        var s = screen || root.focusedScreen();
        var n = Math.max(24, Theme.dp(56));
        if (!s)
            return {
                "x": 0,
                "y": 0,
                "width": n,
                "height": n
            };
        return {
            "x": s.x + s.width / 2 - n / 2,
            "y": s.y + s.height / 2 - n / 2,
            "width": n,
            "height": n
        };
    }

    // Where the placeholder grows from. The launcher has a real icon rect; a
    // launch from a bind or a script grows out of the middle of the window the
    // user is in, or the focused display when nothing is open. A rect is
    // authoritative for the output: a keybind can fire while the pointer is on
    // another display, and the icon must still grow out of the window the user
    // is in.
    function resolveOrigin(rect, preferredScreen) {
        var focused = preferredScreen || root.focusedScreen();
        var r = rect || null;
        var screen = null;

        if (r) {
            // an explicit icon rect (launcher card, desktop icon) names its
            // own output
            screen = root.screenAt(r.x + r.width / 2, r.y + r.height / 2);
        } else {
            // no icon to grow from: use the window the user is in, but only
            // when it is on the focused output. Otherwise a keybind fired
            // while another display is focused would seed on the window's
            // display instead.
            var a = root.activeRect();
            var activeScreen = a ? root.screenAt(a.x + a.width / 2, a.y + a.height / 2) : null;
            if (a && activeScreen === focused) {
                r = a;
                screen = activeScreen;
            }
        }

        if (!screen)
            screen = focused;
        if (!r)
            r = root.centerRect(screen);

        return {
            "rect": r,
            "screen": screen
        };
    }

    function windowRect(screen) {
        return root.resolveOrigin(null, screen).rect;
    }

    function iconSource(name) {
        if (!name || name === "")
            return Quickshell.iconPath("application-x-executable", true);
        if (String(name).indexOf("/") >= 0 || String(name).indexOf("file://") === 0)
            return String(name);

        var p = Quickshell.iconPath(String(name), true);
        return p !== "" ? p : Quickshell.iconPath("application-x-executable", true);
    }

    function titleFor(command, title) {
        if (title && title !== "")
            return String(title);

        var first = String(command || "").trim().split(/\s+/)[0] || "";
        first = first.replace(/^['"]|['"]$/g, "");
        var slash = first.lastIndexOf("/");
        return slash >= 0 ? first.substring(slash + 1) : (first || "Application");
    }

    // ---- the app database, for deciding whether a typed command has a UI ----

    readonly property var guiCommands: {
        var set = {};
        var wrappers = {
            "env": true, "sh": true, "bash": true, "zsh": true, "fish": true,
            "flatpak": true, "snap": true, "systemd-run": true, "gtk-launch": true,
            "dbus-run-session": true, "python": true, "python3": true, "wine": true
        };
        var entries = DesktopEntries.applications.values;
        for (var i = 0; i < entries.length; i++) {
            var argv = entries[i].command || [];
            for (var j = 0; j < argv.length; j++) {
                var a = String(argv[j]);
                if (a === "" || a.charAt(0) === "-")
                    continue;
                if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(a))
                    continue;
                if (wrappers[a] === true)
                    continue;
                set[a] = true;
                var slash = a.lastIndexOf("/");
                if (slash >= 0)
                    set[a.substring(slash + 1)] = true;
                break;
            }
        }
        return set;
    }

    function looksLikeGui(command) {
        var words = String(command || "").trim().split(/\s+/);
        var wrappers = {
            "env": true, "sh": true, "bash": true, "zsh": true, "fish": true,
            "flatpak": true, "snap": true, "systemd-run": true, "gtk-launch": true,
            "dbus-run-session": true, "python": true, "python3": true, "wine": true
        };
        for (var i = 0; i < words.length; i++) {
            var w = words[i].replace(/^['"]|['"]$/g, "");
            if (w === "" || /^[A-Za-z_][A-Za-z0-9_]*=/.test(w) || w.charAt(0) === "-")
                continue;
            if (w === "flatpak" || w === "snap")
                return true;
            if (wrappers[w] === true)
                continue;
            var slash = w.lastIndexOf("/");
            var bin = slash >= 0 ? w.substring(slash + 1) : w;
            return root.guiCommands[bin] === true;
        }
        return false;
    }

    // ---- public ----------------------------------------------------------

    // info: { title, icon, iconRect, rect, wmClass, base, screen, workspace,
    //         timeoutMs, strict }
    function launch(command, opts) {
        if (!command)
            return false;

        opts = opts || {};
        var origin = root.resolveOrigin(opts.rect || opts.iconRect || null, opts.screen || null);
        var info = {
            "command": String(command),
            "title": root.titleFor(command, opts.title),
            "iconSource": root.iconSource(opts.icon),
            "iconRect": origin.rect,
            "wmClass": opts.wmClass || "",
            "wmClasses": opts.wmClasses || [],
            "base": opts.base || "",
            "screen": origin.screen,
            "workspace": opts.workspace || "",
            "timeoutMs": opts.timeoutMs > 0 ? Number(opts.timeoutMs) : 10000,
            "rehome": opts.rehome !== false,
            "pin": opts.pin !== false
        };

        if (opts.strict === true && !root.availableGhost())
            return false;

        root.queue = root.queue.concat([{
            "info": info,
            "at": Date.now()
        }]);
        root.pump();
        return true;
    }

    function runArgv(argv, opts) {
        if (!argv || argv.length === 0)
            return false;
        return root.launch(root.argvLine(argv), opts);
    }

    // a link opened from anywhere: hold a tile for the browser that follows,
    // with a short timeout because a browser already running may just add a
    // tab instead of mapping a new window.
    function openUrl(url, opts) {
        if (!url)
            return false;

        opts = opts || {};
        var command = opts.command || ("xdg-open " + root.shQuote(String(url)));
        var classes = opts.wmClasses && opts.wmClasses.length > 0 ? opts.wmClasses : root.browserClasses;
        var existing = opts.focusExisting === false ? null : root.browserWindow(classes);

        // the browser is already open: hand it the URL and raise its window,
        // exactly like an app launcher press on a running app. No tile is held
        // for a window that already exists.
        if (existing) {
            root.execNow({ "command": command });
            root.focusWindow(existing.address);
            return true;
        }

        return root.launch(command, {
            "title": opts.title || "Browser",
            "icon": opts.icon || "web-browser",
            "rect": opts.rect || null,
            "screen": opts.screen || null,
            "wmClass": opts.wmClass || "",
            "wmClasses": classes,
            "timeoutMs": opts.timeoutMs > 0 ? opts.timeoutMs : 2500,
            // a browser already on another workspace keeps its place; the
            // placeholder fades there instead of dragging the window over
            "rehome": false,
            "pin": false
        });
    }

    // ---- the queue -------------------------------------------------------

    function pump() {
        if (root.queue.length === 0)
            return;

        while (root.queue.length > 0) {
            var item = root.queue[0];
            var g = root.availableGhost();
            if (g && g.prepareAndLaunch(item.info)) {
                root.queue = root.queue.slice(1);
                // a burst fills every free ghost in this pass; the loop is
                // the queue's drain, not just one launch per wake-up
                continue;
            }

            // no ghost, or it has been busy too long: start it plainly rather
            // than hold the app behind another launch
            if (Date.now() - item.at >= root.waitMs) {
                root.queue = root.queue.slice(1);
                root.execNow(item.info);
                continue;
            }
            break;
        }

        if (root.queue.length > 0 && !retry.running)
            retry.restart();
    }

    function execNow(info) {
        if (!info || !info.command)
            return;
        Quickshell.execDetached([root.helper, info.token || root.token(), info.command]);
    }

    Timer {
        id: retry

        // a ghost returning to idle is noticed here, so a burst queues for
        // milliseconds rather than waiting on a signal per pool member
        interval: 30
        repeat: false
        onTriggered: root.pump()
    }

    // ---- launches from outside the shell ---------------------------------

    function pollRequests() {
        if (requestPoll.running) {
            // a launch that landed while the last listing was in flight: look
            // again once it finishes instead of losing its wake-up
            root.pollAgain = true;
            return;
        }
        requestPoll.running = true;
    }

    function decode(v) {
        if (v === undefined || v === "")
            return "";
        try {
            return decodeURIComponent(String(v));
        } catch (e) {
            return String(v);
        }
    }

    function parseMeta(text) {
        var out = {};
        var lines = String(text || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
            var at = lines[i].indexOf("=");
            if (at <= 0)
                continue;
            out[lines[i].substring(0, at)] = lines[i].substring(at + 1);
        }
        return out;
    }

    function handleRequests(text) {
        var out = String(text || "");
        var at = 0;
        while (true) {
            var head = out.indexOf("@@LUCID ", at);
            if (head < 0)
                break;
            var headEnd = out.indexOf("\n", head);
            if (headEnd < 0)
                break;
            var runPath = out.substring(head + 8, headEnd);
            var end = out.indexOf("\n@@LUCID-END@@", headEnd);
            if (end < 0)
                break;
            var body = out.substring(headEnd + 1, end);
            var split = body.indexOf("\n@@CMD\n");
            if (split < 0) {
                at = end + 14;
                continue;
            }

            var meta = root.parseMeta(body.substring(0, split));
            var command = body.substring(split + 7);
            at = end + 14;

            if (root.seenRuns[runPath] === true)
                continue;
            root.seenRuns[runPath] = true;

            var rect = null;
            var r = String(meta.rect || "").split(",");
            if (r.length === 4) {
                var x = Number(r[0]), y = Number(r[1]), w = Number(r[2]), h = Number(r[3]);
                if (isFinite(x) && isFinite(y) && isFinite(w) && isFinite(h) && w > 0 && h > 0)
                    rect = { "x": x, "y": y, "width": w, "height": h };
            }

            var origin = root.resolveOrigin(rect, null);
            var info = {
                "command": command,
                "title": root.titleFor(command, root.decode(meta.title)),
                "iconSource": root.iconSource(root.decode(meta.icon)),
                "iconRect": origin.rect,
                "wmClass": root.decode(meta.class),
                "base": root.decode(meta.base),
                "screen": origin.screen,
                "workspace": root.decode(meta.workspace),
                "timeoutMs": Number(meta.timeout) > 0 ? Number(meta.timeout) : 10000,
                "token": root.decode(meta.token)
            };

            Quickshell.execDetached(["rm", "-f", runPath, runPath.replace(/\.claimed$/, ".cmd")]);
            root.queue = root.queue.concat([{
                "info": info,
                "at": Date.now()
            }]);
        }
        root.pump();
    }

    Process {
        id: requestPoll

        // claim each .req by moving it out of the way first, so the helper sees
        // it as accepted and exits
        command: ["sh", "-c",
            "d=\"$1\"; " +
            "for f in \"$d\"/*.req; do " +
            "  [ -e \"$f\" ] || continue; " +
            "  r=\"${f%.req}.claimed\"; " +
            "  mv \"$f\" \"$r\" 2>/dev/null || continue; " +
            "  printf '@@LUCID %s\\n' \"$r\"; " +
            "  cat \"$r\"; " +
            "  printf '@@CMD\\n'; " +
            "  cat \"${r%.claimed}.cmd\"; " +
            "  printf '\\n@@LUCID-END@@\\n'; " +
            "done",
            "sh", root.requestDir]

        stdout: StdioCollector {
            onStreamFinished: root.handleRequests(this.text)
        }

        onExited: {
            if (root.pollAgain) {
                root.pollAgain = false;
                root.pollRequests();
            }
        }
    }

    // a request left by a shell that died before claiming it is picked up
    // once here; after startup the global shortcut is the only wake-up
    Component.onCompleted: root.pollRequests()
}

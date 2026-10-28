import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs
import qs.lucidui

// A launcher launch, given the feedback an Android launch gets: the picked
// icon swells into the tile the app will occupy, holds that tile with the m3
// expressive loading indicator while the app starts, and hands the tile to the
// app the moment its first window maps.
//
// The tile is really held. An invisible (borderless, shadowless) Quickshell
// window sits parked in a workspace of its own; a launch moves it into the
// current workspace, so Hyprland's tiling puts it exactly where the app would
// have gone. The app then opens beside it and the placeholder leaves, which
// makes the app expand into the held tile. Nothing about the final geometry is
// predicted.
//
// The morph itself is drawn by a full-screen overlay layer, so it can start at
// the icon in the picker and travel outside the launcher's surface.
Item {
    id: root

    visible: false
    width: 0
    height: 0

    readonly property string parkWorkspace: "special:lucid-launch"
    readonly property string stableTitle: "lucid-launch-placeholder"
    readonly property int launchTimeoutMs: 10000
    readonly property real windowRadius: Math.max(0, Math.round(HyprConfig.num("decoration.rounding", 8)))

    property bool trace: Quickshell.env("LUCID_LAUNCH_TRACE") === "1"

    property string placeholderAddr: ""
    property bool placeholderParked: false
    property bool ready: false
    property var overlayScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null

    property var req: null
    property var tile: null
    property string token: ""
    property string targetWs: ""
    property string phase: "idle"
    property bool surfaceShown: false
    property bool appMatched: false
    property string appAddr: ""
    property var known: ({})
    property var candidates: []
    property var stats: ({})

    // ---- trace -----------------------------------------------------------
    function traceLog(msg) {
        if (!root.trace)
            return;

        console.log("lucid-launch " + Date.now() + " " + msg);
    }

    function stamp(key, value) {
        root.stats[key] = value;
        root.stats["at_" + key] = Date.now();
        root.traceLog(key + " " + JSON.stringify(value));
    }

    // ---- hyprland dispatches --------------------------------------------
    // Hyprland drops an idle command socket after about a second, and
    // Quickshell's Hyprland.dispatch waits its own event loop (measured ~100ms
    // late). A serialized hyprctl dispatch is ~10ms and needs no reconnection.
    Process {
        id: dispatchProc

        property var pending: []
        property string current: ""
        command: []

        function push(expr) {
            dispatchProc.pending.push(expr);
            dispatchProc.pump();
        }

        function pump() {
            if (dispatchProc.running || dispatchProc.pending.length === 0)
                return;

            dispatchProc.current = dispatchProc.pending.shift();
            dispatchProc.command = ["hyprctl", "dispatch", dispatchProc.current];
            dispatchProc.running = true;
        }

        onExited: dispatchProc.pump()
    }

    function send(line) {
        var expr = line;
        if (expr.indexOf("dispatch ") === 0)
            expr = expr.substring(9);
        dispatchProc.push(expr);
    }

    // ---- the rules that make the placeholder invisible and parked --------
    // Kept runtime-added: the window itself is always mapped, so these only
    // have to hold for the one map after the shell (re)loads.
    readonly property string ruleCode: "hl.window_rule({ name = \"lucid-launch-placeholder\", match = { title = \"^lucid-launch-placeholder$\" }, workspace = \"" + root.parkWorkspace + "\", border_size = 0, rounding = 0, no_shadow = true, no_blur = true, no_anim = true, no_initial_focus = true })"

    Process {
        id: ruleProc

        command: ["hyprctl", "eval", root.ruleCode]

        onExited: (code) => {
            root.traceLog("rules " + code);
            if (!placeholder.visible)
                placeholder.visible = true;
            ruleFallback.stop();
        }
    }

    Timer {
        id: ruleFallback

        interval: 900
        running: true
        onTriggered: if (!placeholder.visible) placeholder.visible = true
    }

    function installRules() {
        if (ruleProc.running)
            return;
        ruleProc.running = true;
    }

    // ---- the tile, held by a real window --------------------------------
    FloatingWindow {
        id: placeholder

        title: root.stableTitle
        color: "transparent"
        implicitWidth: 480
        implicitHeight: 320
        visible: false

        LaunchGhostSurface {
            id: surface

            anchors.fill: parent
            iconSource: root.req ? root.req.iconSource : ""
            appName: root.req ? root.req.title : ""
            radius: root.windowRadius
            indicator: root.surfaceShown
            opacity: root.surfaceShown ? 1 : 0

            Behavior on opacity {
                NumberAnimation {
                    duration: Theme.durDefaultEffects
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveEffects
                }
            }
        }
    }

    // ---- the morph -------------------------------------------------------
    PanelWindow {
        id: overlay

        screen: root.overlayScreen
        visible: true
        color: "transparent"
        exclusiveZone: -1
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "lucid-launch-ghost"
        mask: Region {}

        anchors {
            top: true
            left: true
            right: true
            bottom: true
        }

        property bool active: false
        property bool landed: false
        property bool fadingOut: false
        property real contentOpacity: 0
        property real morphT: 0
        property real effectsT: 0
        property string iconSource: ""
        property string iconLabel: ""

        property real fromX: 0
        property real fromY: 0
        property real fromW: 0
        property real fromH: 0
        property real toX: 0
        property real toY: 0
        property real toW: 0
        property real toH: 0

        readonly property real ox: overlay.screen ? overlay.screen.x : 0
        readonly property real oy: overlay.screen ? overlay.screen.y : 0

        // interpolated with one overshooting spatial value so the shape keeps
        // its aspect while it springs past the tile and settles back
        readonly property real shapeX: overlay.fromX + (overlay.toX - overlay.fromX) * overlay.morphT
        readonly property real shapeY: overlay.fromY + (overlay.toY - overlay.fromY) * overlay.morphT
        readonly property real shapeW: Math.max(0, overlay.fromW + (overlay.toW - overlay.fromW) * overlay.morphT)
        readonly property real shapeH: Math.max(0, overlay.fromH + (overlay.toH - overlay.fromH) * overlay.morphT)
        readonly property real shapeRadius: Math.max(0, Math.min(overlay.shapeW, overlay.shapeH) / 2 * (1 - overlay.effectsT) + root.windowRadius * overlay.effectsT)
        readonly property real iconFromSize: Math.min(overlay.fromW, overlay.fromH) * 0.82
        readonly property real iconToSize: surface.edgeFor(overlay.toW, overlay.toH)
        readonly property real iconSize: overlay.iconFromSize + (overlay.iconToSize - overlay.iconFromSize) * overlay.effectsT
        readonly property real iconX: overlay.fromX + overlay.fromW / 2 + (overlay.toX + overlay.toW / 2 - (overlay.fromX + overlay.fromW / 2)) * overlay.morphT - overlay.iconSize / 2
        readonly property real iconY: overlay.fromY + overlay.fromH / 2 + (overlay.toY + surface.centerYFor(overlay.toH) - (overlay.fromY + overlay.fromH / 2)) * overlay.morphT - overlay.iconSize / 2
        readonly property color fill: root.mix(Theme.accentContainer, Theme.bgTile, overlay.effectsT)
        readonly property color edge: Theme.alpha(Theme.text, 0.07 * overlay.effectsT)

        function seed(rect, source, screen) {
            if (screen && overlay.screen !== screen)
                overlay.screen = screen;

            fadeAnim.stop();
            morphAnim.stop();
            effectsAnim.stop();

            overlay.active = true;
            overlay.landed = false;
            overlay.fadingOut = false;
            overlay.morphT = 0;
            overlay.effectsT = 0;
            overlay.contentOpacity = 0;

            overlay.fromX = rect.x - overlay.ox;
            overlay.fromY = rect.y - overlay.oy;
            overlay.fromW = Math.max(1, rect.width);
            overlay.fromH = Math.max(1, rect.height);
            overlay.toX = overlay.fromX;
            overlay.toY = overlay.fromY;
            overlay.toW = overlay.fromW;
            overlay.toH = overlay.fromH;
            overlay.iconSource = source;
            overlay.iconLabel = root.req && root.req.title ? String(root.req.title).charAt(0).toUpperCase() : "?";

            seedFade.restart();
        }

        function morphTo(rect) {
            overlay.toX = rect.x - overlay.ox;
            overlay.toY = rect.y - overlay.oy;
            overlay.toW = Math.max(1, rect.width);
            overlay.toH = Math.max(1, rect.height);
            morphAnim.restart();
            effectsAnim.restart();
            root.traceLog("morph-start " + JSON.stringify([overlay.toX, overlay.toY, overlay.toW, overlay.toH]));
        }

        function fadeOut() {
            if (!overlay.active || overlay.fadingOut)
                return;

            overlay.fadingOut = true;
            morphAnim.stop();
            effectsAnim.stop();
            fadeAnim.restart();
        }

        function reset() {
            overlay.active = false;
            overlay.landed = false;
            overlay.fadingOut = false;
            overlay.contentOpacity = 0;
            overlay.morphT = 0;
            overlay.effectsT = 0;
            overlay.fromW = 0;
            overlay.fromH = 0;
            overlay.toW = 0;
            overlay.toH = 0;
        }

        Item {
            anchors.fill: parent
            opacity: overlay.contentOpacity
            visible: overlay.active

            // a plain rounded rect, not the squircle shader: this one animates
            // its size every frame, and the corner difference at window radius
            // is invisible under the 200ms handoff to the settled surface
            Rectangle {
                x: overlay.shapeX
                y: overlay.shapeY
                width: overlay.shapeW
                height: overlay.shapeH
                radius: overlay.shapeRadius
                color: overlay.fill
                border.width: 1
                border.color: overlay.edge
            }

            Image {
                x: overlay.iconX
                y: overlay.iconY
                width: Math.max(1, overlay.iconSize)
                height: width
                source: overlay.iconSource
                fillMode: Image.PreserveAspectFit
                asynchronous: false
                cache: true
                smooth: true
                mipmap: true
                visible: overlay.iconSource !== ""
            }

            Text {
                x: overlay.iconX
                y: overlay.iconY
                width: Math.max(1, overlay.iconSize)
                height: width
                visible: overlay.iconSource === ""
                text: overlay.iconLabel
                color: Theme.accent
                font.family: Theme.fontFamily
                font.pixelSize: Math.max(12, Math.round(overlay.iconSize * 0.5))
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }

        NumberAnimation {
            id: seedFade

            target: overlay
            property: "contentOpacity"
            from: 0
            to: 1
            duration: Theme.ms(90)
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.curveEffects
        }

        NumberAnimation {
            id: morphAnim

            target: overlay
            property: "morphT"
            from: 0
            to: 1
            duration: Theme.durDefaultSpatial
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.curveDefaultSpatial

            onFinished: {
                if (!overlay.fadingOut && root.phase !== "idle") {
                    overlay.landed = true;
                    root.onLanded();
                }
            }
        }

        NumberAnimation {
            id: effectsAnim

            target: overlay
            property: "effectsT"
            from: 0
            to: 1
            duration: Theme.durDefaultSpatial
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.curveEffects
        }

        NumberAnimation {
            id: fadeAnim

            target: overlay
            property: "contentOpacity"
            to: 0
            duration: Theme.durDefaultEffects
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.curveEffects

            onFinished: {
                overlay.active = false;
                overlay.fadingOut = false;
                overlay.landed = false;
            }
        }
    }

    function mix(a, b, t) {
        t = Math.max(0, Math.min(1, t));
        return Qt.rgba(a.r * (1 - t) + b.r * t, a.g * (1 - t) + b.g * t, a.b * (1 - t) + b.b * t, a.a * (1 - t) + b.a * t);
    }

    // the expanding shape has landed on the tile: hand the visual to the real
    // placeholder window (which has been holding the tile all along) and let
    // the overlay fade, matching pixel for pixel
    function onLanded() {
        if (root.phase === "idle" || root.phase === "done" || root.phase === "")
            return;

        root.traceLog("morph-done");
        root.stats.landed = Date.now();
        root.surfaceShown = true;
        overlay.fadeOut();
    }

    // ---- public ----------------------------------------------------------
    readonly property bool available: root.ready && root.phase === "idle" && root.placeholderAddr !== ""

    // the launcher tells the overlay where it lives before an icon is picked,
    // so the layer surface has already moved when the seed is needed
    function prepare(screen) {
        if (screen && root.overlayScreen !== screen && root.phase === "idle")
            root.overlayScreen = screen;
    }

    // info: { command, title, iconSource, iconRect, wmClass, base, screen }
    function launch(info) {
        if (root.phase !== "idle" || !root.ready || !info || !info.command || !info.iconRect)
            return false;

        root.req = info;
        root.token = "lucid-" + Date.now() + "-" + Math.floor(Math.random() * 1e9);
        root.tile = null;
        root.phase = "preparing";
        root.targetWs = root.launchWorkspace();
        root.surfaceShown = false;
        root.appMatched = false;
        root.appAddr = "";
        root.candidates = [];
        root.stats = {
            "started": Date.now(),
            "screen": (info.screen ? info.screen.name : ""),
            "icon": [Math.round(info.iconRect.x), Math.round(info.iconRect.y), Math.round(info.iconRect.width), Math.round(info.iconRect.height)],
            "token": root.token
        };

        if (info.screen && overlay.screen !== info.screen)
            root.overlayScreen = info.screen;

        // same frame as the press: the icon becomes a seed on the overlay
        overlay.seed(info.iconRect, info.iconSource, info.screen);
        root.traceLog("launch " + JSON.stringify(root.stats));

        // the placeholder is already mapped in its own workspace; a fresh
        // client list gives its current address (a reload can remap it), and
        // moving it into this workspace is what makes Hyprland put it in the
        // app's tile
        root.placeholderParked = false;
        placeholder.title = "Launching " + info.title;
        root.lookupPlaceholder();
        return true;
    }

    // a launch can follow a hot reload, when the native placeholder window's
    // address is not the one the QML object last saw. ask the compositor
    // directly rather than trusting a cached address or remapping the window
    Process {
        id: placeholderLookup

        command: ["hyprctl", "clients", "-j"]

        stdout: StdioCollector {
            onStreamFinished: {
                var addr = "";
                try {
                    var list = JSON.parse(this.text);
                    for (var i = 0; i < list.length; i++) {
                        var c = list[i];
                        var t = String(c.title || "");
                        if (String(c.class || "") === "org.quickshell" && (t === root.stableTitle || t.indexOf("Launching ") === 0)) {
                            addr = String(c.address || "");
                            break;
                        }
                    }
                } catch (e) {
                    root.traceLog("lookup " + e);
                }
                root.beginLaunch(addr);
            }
        }
    }

    function lookupPlaceholder() {
        if (!placeholderLookup.running)
            placeholderLookup.running = true;
    }

    function beginLaunch(addr) {
        if (root.phase !== "preparing")
            return;

        if (addr === "") {
            root.placeholderAddr = "";
            root.traceLog("no-placeholder");
            overlay.fadeOut();
            root.launchApp();
            return;
        }

        root.placeholderAddr = addr;
        root.send("dispatch hl.dsp.window.move({ workspace = \"" + root.targetWs + "\", window = \"address:" + root.placeholderAddr + "\", follow = true })");
        root.stats.unpark = Date.now();
        root.traceLog("unpark " + addr + " to " + root.targetWs);
        tilePoll.restart();
    }

    function launchWorkspace() {
        var fw = Hyprland.focusedWorkspace;
        return fw && fw.name ? String(fw.name) : "1";
    }

    // read the tile the placeholder landed in. Hyprland owns the answer, so
    // nothing here has to reimplement dwindle.
    function readTile() {
        Hyprland.refreshToplevels();
        var t = Hyprland.toplevels.values;
        for (var i = 0; i < t.length; i++) {
            var o = t[i].lastIpcObject;
            if (!o || o.address !== root.placeholderAddr || !o.at || !o.size)
                continue;

            var ws = o.workspace ? String(o.workspace.name || "") : "";
            if (ws !== root.targetWs)
                return null;

            return {
                "x": o.at[0],
                "y": o.at[1],
                "width": o.size[0],
                "height": o.size[1]
            };
        }
        return null;
    }

    Timer {
        id: tilePoll

        interval: 8
        repeat: true
        running: false
        property int tries: 0

        onTriggered: {
            var r = root.readTile();
            if (r) {
                stop();
                root.tile = r;
                root.stamp("tile", [r.x, r.y, r.width, r.height]);
                overlay.morphTo(r);
                root.launchApp();
                return;
            }

            if (++tries > 60) {
                // the placeholder is not coming; still run the app rather than
                // swallow the press
                stop();
                root.traceLog("tile-timeout");
                root.launchApp();
            }
        }
    }

    function launchApp() {
        if (root.phase !== "preparing")
            return;

        root.phase = "waiting";
        root.known = ({});
        Hyprland.refreshToplevels();
        var t = Hyprland.toplevels.values;
        for (var i = 0; i < t.length; i++) {
            var o = t[i].lastIpcObject;
            if (o && o.address && o.address !== root.placeholderAddr)
                root.known[o.address] = true;
        }

        root.stats.exec = Date.now();
        root.traceLog("exec " + root.req.command);
        Quickshell.execDetached(["env", "LUCID_LAUNCH_TOKEN=" + root.token, "sh", "-c", root.req.command]);
        timeout.restart();
        regainFocus.restart();
    }

    // the launcher holds an exclusive keyboard grab while it closes. On some
    // compositor paths releasing it lands focus back on the window that was
    // focused before the launcher, not on the placeholder that just arrived;
    // taking it once more after the close keeps the app's split on the tile.
    Timer {
        id: regainFocus

        interval: 190
        onTriggered: {
            if (root.phase === "waiting" && root.placeholderAddr !== "" && root.placeholderAlive())
                root.send("dispatch hl.dsp.focus({ window = \"address:" + root.placeholderAddr + "\" })");
        }
    }

    Timer {
        id: timeout

        interval: root.launchTimeoutMs
        onTriggered: {
            root.traceLog("timeout");
            root.finish(false);
        }
    }

    // ---- the app window --------------------------------------------------
    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event.name === "configreloaded") {
                root.installRules();
                return;
            }

            if (event.name === "closewindow") {
                var closed = "0x" + String(event.data).split(",")[0];
                if (closed === root.placeholderAddr) {
                    root.placeholderAddr = "";
                    root.ready = false;
                    root.traceLog("placeholder closed");
                }
                return;
            }

            if (event.name === "openwindow") {
                var parts = String(event.data).split(",");
                var addr = "0x" + parts[0];
                var ws = parts[1] || "";
                var cls = parts[2] || "";
                var title = parts.length > 3 ? parts.slice(3).join(",") : "";

                if (title === root.stableTitle && root.placeholderAddr !== addr) {
                    root.placeholderAddr = addr;
                    root.parkPlaceholder();
                    return;
                }

                // the compositor handed the old placeholder's address to a
                // new app window; forget it before any park can target it
                if (addr === root.placeholderAddr) {
                    root.placeholderAddr = "";
                    root.ready = false;
                    delete root.known[addr];
                }

                if (root.phase !== "waiting" || addr === root.placeholderAddr || root.known[addr] === true)
                    return;

                root.known[addr] = true;
                root.traceLog("open " + addr + " " + ws + " " + cls + " " + title);

                if (root.classMatches(cls)) {
                    root.matchWindow(addr, cls, ws);
                    return;
                }

                // the env token is the exact answer for apps whose class says
                // nothing useful (and for anything that renames its app_id)
                if (root.checkToken(addr, cls, ws))
                    return;

                root.candidates.push({"addr": addr, "cls": cls, "ws": ws});
                fallback.restart();
                return;
            }

            if (event.name === "movewindow" || event.name === "movewindowv2") {
                if (root.phase === "preparing" && root.placeholderAddr !== "") {
                    var moved = "0x" + String(event.data).split(",")[0];
                    if (moved === root.placeholderAddr) {
                        var r = root.readTile();
                        if (r && !root.tile) {
                            root.tile = r;
                            root.stamp("tile", [r.x, r.y, r.width, r.height]);
                            overlay.morphTo(r);
                            root.launchApp();
                        }
                    }
                }
            }
        }
    }

    function classMatches(cls) {
        if (!cls || !root.req)
            return false;

        var c = String(cls).toLowerCase();
        var wants = [];
        if (root.req.wmClass)
            wants.push(String(root.req.wmClass).toLowerCase());
        if (root.req.base)
            wants.push(String(root.req.base).toLowerCase());
        for (var i = 0; i < wants.length; i++) {
            var w = wants[i];
            if (w === "")
                continue;

            if (c === w)
                return true;

            var cn = c.replace(/[-_. ]/g, "");
            var wn = w.replace(/[-_. ]/g, "");
            if (cn === wn)
                return true;

            if (c.endsWith("." + w) || w.endsWith("." + c))
                return true;

            // zen-browser against zen, org.gnome.Nautilus against nautilus
            var cf = c.split(/[-_.]/)[0];
            var wf = w.split(/[-_.]/)[0];
            if (cf.length >= 3 && cf === wf)
                return true;
        }
        return false;
    }

    function pidOf(addr) {
        Hyprland.refreshToplevels();
        var t = Hyprland.toplevels.values;
        for (var i = 0; i < t.length; i++) {
            var o = t[i].lastIpcObject;
            if (o && o.address === addr)
                return o.pid || 0;
        }
        return 0;
    }

    Process {
        id: tokenProbe

        property string addr: ""
        property string cls: ""
        property string ws: ""

        onExited: (code) => {
            if (code === 0 && root.phase === "waiting")
                root.matchWindow(tokenProbe.addr, tokenProbe.cls, tokenProbe.ws);
        }
    }

    function checkToken(addr, cls, ws) {
        var pid = root.pidOf(addr);
        if (!pid)
            return false;

        tokenProbe.addr = addr;
        tokenProbe.cls = cls;
        tokenProbe.ws = ws;
        tokenProbe.command = ["sh", "-c", "grep -qaF \"$1\" /proc/$2/environ 2>/dev/null", "sh", "LUCID_LAUNCH_TOKEN=" + root.token, String(pid)];
        tokenProbe.running = true;
        return true;
    }

    Timer {
        id: fallback

        interval: 1300
        onTriggered: {
            if (root.phase !== "waiting" || root.candidates.length === 0)
                return;

            var c = root.candidates[0];
            root.traceLog("fallback " + c.addr);
            root.matchWindow(c.addr, c.cls, c.ws);
        }
    }

    function matchWindow(addr, cls, ws) {
        if (root.phase !== "waiting")
            return;

        root.appMatched = true;
        root.appAddr = addr;
        root.stamp("opened", [cls, ws, addr]);
        root.traceLog("matched " + addr + " " + cls);
        root.send("dispatch hl.dsp.focus({ window = \"address:" + addr + "\" })");
        root.finish(true);
    }

    // ---- hand the tile over ---------------------------------------------
    function finish(matched) {
        if (root.phase === "done" || root.phase === "idle")
            return;

        root.phase = "done";
        timeout.stop();
        fallback.stop();
        tilePoll.stop();
        regainFocus.stop();

        // the app is already tiled beside the placeholder; taking the
        // placeholder away lets dwindle give the app the whole held tile
        if (root.placeholderAddr !== "" && root.placeholderAddr !== root.appAddr) {
            root.send("dispatch hl.dsp.window.move({ workspace = \"" + root.parkWorkspace + "\", window = \"address:" + root.placeholderAddr + "\", follow = false })");
            root.placeholderParked = true;
            root.stamp("parked", matched);
        } else {
            root.placeholderAddr = "";
            root.placeholderParked = false;
        }

        root.surfaceShown = false;
        overlay.fadeOut();

        if (matched && root.appAddr !== "")
            appRectTimer.restart();
        else
            resetTimer.restart();
    }

    Timer {
        id: appRectTimer

        interval: 180
        onTriggered: {
            Hyprland.refreshToplevels();
            var t = Hyprland.toplevels.values;
            for (var i = 0; i < t.length; i++) {
                var o = t[i].lastIpcObject;
                if (o && o.address === root.appAddr) {
                    root.stats.appFinal = [o.at[0], o.at[1], o.size[0], o.size[1]];
                    root.traceLog("app-final " + JSON.stringify(root.stats.appFinal));
                    break;
                }
            }
            resetTimer.restart();
        }
    }

    Timer {
        id: resetTimer

        interval: 420
        onTriggered: {
            root.phase = "idle";
            root.req = null;
            root.appMatched = false;
            root.appAddr = "";
            root.tile = null;
            root.surfaceShown = false;
            root.placeholderParked = true;
            placeholder.title = root.stableTitle;
            overlay.reset();
            root.traceLog("idle");
        }
    }

    // ---- startup ---------------------------------------------------------
    function findPlaceholder(park) {
        Hyprland.refreshToplevels();
        var t = Hyprland.toplevels.values;
        for (var i = 0; i < t.length; i++) {
            var o = t[i].lastIpcObject;
            if (o && o.title === root.stableTitle && o.address) {
                if (root.placeholderAddr !== o.address) {
                    root.placeholderAddr = o.address;
                    root.traceLog("placeholder " + o.address + " " + (o.workspace ? o.workspace.name : ""));
                    if (park !== false)
                        root.parkPlaceholder();
                }
                return true;
            }
        }
        return false;
    }

    // the QML tree can be reloaded while the native window stays mapped, so
    // the address is checked from the live client list, not kept on trust.
    // Class is part of the check: Hyprland reuses addresses, and an app that
    // inherited the old placeholder's address must never be moved or parked.
    function placeholderAlive() {
        if (root.placeholderAddr === "")
            return false;

        Hyprland.refreshToplevels();
        var t = Hyprland.toplevels.values;
        for (var i = 0; i < t.length; i++) {
            var o = t[i].lastIpcObject;
            if (o && o.address === root.placeholderAddr && o.class === "org.quickshell")
                return true;
        }
        return false;
    }

    function parkPlaceholder() {
        if (root.placeholderAddr === "")
            return;
        root.send("dispatch hl.dsp.window.move({ workspace = \"" + root.parkWorkspace + "\", window = \"address:" + root.placeholderAddr + "\", follow = false })");
        root.placeholderParked = true;
        readyTimer.restart();
    }

    Timer {
        id: readyTimer

        interval: 120
        onTriggered: {
            if (root.placeholderAddr !== "" && !dispatchProc.running && dispatchProc.pending.length === 0) {
                root.ready = true;
                root.traceLog("ready");
            } else {
                restart();
            }
        }
    }

    Timer {
        interval: 150
        running: true
        repeat: false
        onTriggered: root.findPlaceholder()
    }

    Timer {
        interval: 600
        running: true
        repeat: false
        onTriggered: if (!root.findPlaceholder()) findAgain.start()
    }

    Timer {
        id: findAgain

        interval: 500
        repeat: true
        onTriggered: if (root.findPlaceholder()) stop()
    }

    // If the native placeholder window is ever really gone (not just remapped
    // under a new address), bring it back. The backing window, not the cached
    // address, is the test: Hyprland reuses addresses and the QML object can
    // survive a reload, so an address mismatch must not remap a live window.
    Timer {
        interval: 5000
        running: true
        repeat: true
        onTriggered: {
            if (root.phase !== "idle")
                return;

            // cheap refresher: this also repairs a stale address after a hot
            // reload, without touching a window that is still mapped
            if (root.findPlaceholder())
                return;

            if (!placeholder.visible || placeholder.backingWindowVisible)
                return;

            placeholder.visible = false;
            Qt.callLater(function() {
                placeholder.visible = true;
                findAgain.start();
            });
        }
    }

    Component.onCompleted: {
        root.overlayScreen = Monitors.focusedScreen || (Quickshell.screens.length > 0 ? Quickshell.screens[0] : null);
        root.installRules();
    }

    IpcHandler {
        target: "launchghost"

        function trace(on: bool): string {
            root.trace = on;
            return "trace " + on;
        }

        function status(): string {
            return JSON.stringify({
                "ready": root.ready,
                "phase": root.phase,
                "placeholder": root.placeholderAddr,
                "parked": root.placeholderParked,
                "stats": root.stats
            });
        }
    }
}

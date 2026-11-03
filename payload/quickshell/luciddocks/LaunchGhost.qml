import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs
import qs.lucidui
import "../squircle"

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
// the icon in the picker and travel outside the launcher's surface. Once it
// lands, a floating toplevel on the launch workspace takes over: it covers the
// app's temporary split beside the parked placeholder, but unlike a layer it
// is rendered inside the workspace, so Hyprland's own workspace animations
// move it exactly like the app windows. When the app has grown into the tile
// it is cut away by an m3 expressive circular iris that opens from the tile's
// centre and reveals the window underneath.
//
// Apps that start in steps (steam, discord, …) keep producing windows after
// the first one is matched. A short-lived pin follows the launch token (and
// the matched class) for those windows and moves each one to the launch
// workspace, so the whole chain lands together.
Item {
    id: root

    visible: false
    width: 0
    height: 0

    readonly property string parkWorkspace: "special:lucid-launch"
    readonly property string parkName: root.parkWorkspace.replace("special:", "")
    readonly property string stableTitle: "lucid-launch-placeholder"
    // The held tile is drawn by a workspace-bound floating window, not by the
    // layer overlay: Hyprland renders it inside the workspace, so its own
    // workspace slide/fade applies without reimplementing any of it.
    readonly property string ghostTitle: "lucid-launch-ghost"
    // a function dispatch, so it only puts the parking workspace away when it
    // is really on screen and is a no-op otherwise
    readonly property string hideParkDispatch: "function() local s = hl.get_active_special_workspace() if not s or s.name ~= \"" + root.parkWorkspace + "\" then return end hl.dispatch(hl.dsp.workspace.toggle_special(\"" + root.parkName + "\")) end"
    readonly property int launchTimeoutMs: 10000
    // The compositor's own corner geometry, not decoration:rounding as written:
    // CWindow::rounding() multiplies that by rounding_power / 2 to keep the
    // perceived roundness constant, so this is the radius the real windows
    // actually draw. Same exponent the shell uses for its own squircles.
    readonly property real windowRadius: Math.max(0, HyprConfig.num("decoration.rounding", 8) * HyprConfig.num("decoration.rounding_power", 2) / 2)
    readonly property real windowSmoothing: Prefs.squircleF
    // fast spatial is the right shape but 1/3 quick for a full-tile iris
    readonly property int irisMs: Math.round(Theme.durFastSpatial * 4 / 3) + 100
    // fast out, long settle: the rim leaves at speed and eases into the tile
    readonly property var irisCurve: [0.05, 0.7, 0.1, 1, 1, 1]

    // A layer surface is per-output, not per-workspace: the ghost has to be
    // hidden by hand when the launch workspace scrolls away, or it floats over
    // every workspace you visit while the app is starting.
    readonly property var overlayMonitor: Hyprland.monitorFor(root.overlayScreen)
    readonly property string overlayWorkspace: {
        var m = root.overlayMonitor;
        return m && m.activeWorkspace ? String(m.activeWorkspace.name || "") : "";
    }
    readonly property bool launchWorkspaceShown: root.targetWs === "" || root.overlayWorkspace === "" || root.overlayWorkspace === root.targetWs

    // the settled tile's icon geometry, shared by the overlay and the (now
    // invisible) placeholder surface
    function tileEdge(w, h) {
        return Math.max(Theme.dp(32), Math.min(Theme.dp(88), Math.round(Math.min(w, h) * 0.28)));
    }

    function tileCenterY(h) {
        return Math.round(h * 0.43);
    }

    property bool trace: Quickshell.env("LUCID_LAUNCH_TRACE") === "1"

    property string placeholderAddr: ""
    property bool placeholderParked: false
    property string ghostAddr: ""
    property bool ghostParked: true
    // true only once the ghost has really been placed on the tile; until then
    // the overlay keeps the visual (so a failed dispatcher call cannot blank
    // the launch)
    property bool ghostPlaced: false
    property int ghostChecks: 0
    // the placeholder's tile can be stale if the bar/layer layout was not in
    // force when it was parked; adopt the app's real rect when it is close
    property bool tileAdopted: false
    readonly property bool useGhost: root.ghostAddr !== ""
    property bool ready: false
    property var overlayScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    // hyprctl clients reports the *target* geometry, not the animated one, so
    // the app's rect reaches the tile the instant the placeholder is parked
    // while the window is still growing into it for this long. The iris waits
    // for the real motion to finish (speed is deciseconds in Hyprland).
    property int moveAnimMs: 420

    property var req: null
    property var tile: null
    property string token: ""
    property string targetWs: ""
    property string phase: "idle"
    property bool appMatched: false
    property bool wsReasserted: false
    property string appAddr: ""

    // Multi-step apps (steam, discord, …) open a chain of helper/updater
    // windows before the real one. They carry the launch token in their
    // environment (or at least the same class), so a short-lived pin keeps the
    // whole chain on the workspace the launch was made on.
    readonly property int pinWindowMs: 60000
    property bool pinning: false
    property string pinWs: ""
    property string pinToken: ""
    property string pinClass: ""
    property var pinned: ({})
    property var pinRetry: []
    readonly property int pinRetryMs: 70
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
    // The title stays fixed for the whole life of the window: a title-based
    // rule is re-evaluated when the title changes, so renaming it to
    // "Launching …" mid-launch dropped the rule and handed the transparent
    // reservation window the compositor's default border, shadow and blur.
    // The alternation also repairs a window left with the old title by a
    // previous build.
    readonly property string ruleCode: "hl.window_rule({ name = \"lucid-launch-placeholder\", match = { title = \"^(lucid-launch-placeholder|Launching )\" }, workspace = \"" + root.parkWorkspace + "\", border_size = 0, no_border = true, rounding = 0, no_rounding = true, no_shadow = true, no_blur = true, no_anim = true, no_initial_focus = true })"
        + "; hl.window_rule({ name = \"lucid-launch-ghost\", match = { title = \"^lucid-launch-ghost$\" }, workspace = \"" + root.parkWorkspace + "\", float = true, border_size = 0, no_border = true, rounding = 0, no_rounding = true, no_shadow = true, no_blur = true, no_anim = true, no_initial_focus = true, no_focus = true })"

    Process {
        id: ruleProc

        command: ["hyprctl", "eval", root.ruleCode]

        onExited: (code) => {
            root.traceLog("rules " + code);
            if (!placeholder.visible)
                placeholder.visible = true;
            if (!ghost.visible)
                ghost.visible = true;
            ruleFallback.stop();
        }
    }

    Timer {
        id: ruleFallback

        interval: 900
        running: true
        onTriggered: {
            if (!placeholder.visible)
                placeholder.visible = true;
            if (!ghost.visible)
                ghost.visible = true;
        }
    }

    function installRules() {
        if (ruleProc.running)
            return;
        ruleProc.running = true;
    }

    // ---- how long a tile move really takes ------------------------------
    function findAnimation(node, name) {
        if (!node || typeof node !== "object")
            return null;

        if (Array.isArray(node)) {
            for (var i = 0; i < node.length; i++) {
                var found = root.findAnimation(node[i], name);
                if (found)
                    return found;
            }
            return null;
        }

        if (node.name === name)
            return node;

        for (var key in node) {
            var nested = root.findAnimation(node[key], name);
            if (nested)
                return nested;
        }
        return null;
    }

    Process {
        id: animProbe

        command: ["hyprctl", "animations", "-j"]

        stdout: StdioCollector {
            onStreamFinished: {
                var ms = 0;
                try {
                    var leaf = root.findAnimation(JSON.parse(this.text), "windowsMove");
                    // speed is deciseconds, so 4.0 is 400 ms
                    if (leaf && leaf.enabled && HyprConfig.bool("animations.enabled", true)) {
                        var speed = Number(leaf.speed);
                        if (isFinite(speed) && speed > 0)
                            ms = Math.round(speed * 100);
                    }
                } catch (e) {
                    root.traceLog("animations " + e);
                }
                root.moveAnimMs = ms;
                root.traceLog("windowsMove " + ms);
            }
        }
    }

    function probeAnimations() {
        if (!animProbe.running)
            animProbe.running = true;
    }

    // ---- the tile, held by a real window --------------------------------
    // The window is only the reservation: it has no pixels of its own. The
    // floating ghost below draws the tile on the workspace.
    FloatingWindow {
        id: placeholder

        title: root.stableTitle
        color: "transparent"
        implicitWidth: 480
        implicitHeight: 320
        visible: false
    }

    // ---- the visible tile, on the workspace -----------------------------
    // A floating toplevel rather than a layer surface: Hyprland renders it
    // inside the workspace, so every configured workspace animation (slide,
    // fade, …) applies to it exactly as it does to the app windows. It sits
    // above the tiled reservation and therefore hides the app's temporary
    // split until the iris.
    FloatingWindow {
        id: ghost

        title: root.ghostTitle
        color: "transparent"
        screen: root.overlayScreen
        implicitWidth: 480
        implicitHeight: 320
        visible: false
        mask: Region {}

        property bool surfaceShown: false
        property bool revealing: false
        property real revealRadius: 0
        readonly property real revealSoftStop: revealRadius > 1 ? (revealRadius - 1) / revealRadius : 0
        readonly property real revealMax: Math.hypot(width / 2, height / 2) + 2

        Item {
            id: ghostContent

            anchors.fill: parent
            // the remaining ring fades as the iris grows, so the handover is a
            // dissolve as well as a cut
            opacity: ghost.surfaceShown ? (ghost.revealing ? Math.max(0, 1 - ghost.revealRadius / Math.max(1, ghost.revealMax)) : 1) : 0
            layer.enabled: ghost.revealing
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: ghostMask
            }

            LaunchGhostSurface {
                anchors.fill: parent
                iconSource: root.req ? root.req.iconSource : ""
                appName: root.req ? root.req.title : ""
                radius: root.windowRadius
                indicator: root.phase === "waiting" || root.phase === "done"
                // reach full coverage before the ghost's opacity fade makes it
                // invisible
                revealProgress: ghost.revealing ? Math.min(1, (ghost.revealRadius / Math.max(1, ghost.revealMax)) / 0.6) : 0
            }
        }

        // White outside the iris, transparent inside it: the hole is where
        // the real window shows through.
        Item {
            id: ghostMask

            anchors.fill: parent
            visible: false
            layer.enabled: ghost.surfaceShown

            Shape {
                anchors.fill: parent
                ShapePath {
                    fillGradient: RadialGradient {
                        centerX: ghost.width / 2
                        centerY: ghost.height / 2
                        centerRadius: Math.max(1, ghost.revealRadius)
                        focalX: ghost.width / 2
                        focalY: ghost.height / 2
                        spread: ShapeGradient.PadSpread

                        GradientStop {
                            position: 0
                            color: "transparent"
                        }

                        GradientStop {
                            position: ghost.revealSoftStop
                            color: "transparent"
                        }

                        GradientStop {
                            position: 1
                            color: "white"
                        }
                    }

                    startX: 0
                    startY: 0

                    PathLine {
                        x: ghost.width
                        y: 0
                    }

                    PathLine {
                        x: ghost.width
                        y: ghost.height
                    }

                    PathLine {
                        x: 0
                        y: ghost.height
                    }

                    PathLine {
                        x: 0
                        y: 0
                    }
                }
            }
        }

        function revealOut() {
            if (!ghost.surfaceShown || ghost.revealing)
                return;

            ghost.revealing = true;
            ghost.revealRadius = 0;
            ghostRevealAnim.restart();
            revealGuard.restart();
            root.traceLog("ghost-iris-start " + ghost.revealMax);
        }

        function finishReveal() {
            ghostRevealAnim.stop();
            ghost.surfaceShown = false;
            ghost.revealing = false;
            ghost.revealRadius = 0;
        }

        NumberAnimation {
            id: ghostRevealAnim

            target: ghost
            property: "revealRadius"
            from: 0
            to: ghost.revealMax
            duration: root.irisMs
            easing.type: Easing.Bezier
            easing.bezierCurve: root.irisCurve

            onFinished: {
                ghost.finishReveal();
                root.afterReveal();
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
        property bool revealing: false
        property real contentOpacity: 0
        property real morphT: 0
        property real effectsT: 0
        property real revealRadius: 0
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
        readonly property real iconToSize: root.tileEdge(overlay.toW, overlay.toH)
        readonly property real iconSize: overlay.iconFromSize + (overlay.iconToSize - overlay.iconFromSize) * overlay.effectsT
        readonly property real iconX: overlay.fromX + overlay.fromW / 2 + (overlay.toX + overlay.toW / 2 - (overlay.fromX + overlay.fromW / 2)) * overlay.morphT - overlay.iconSize / 2
        readonly property real iconY: overlay.fromY + overlay.fromH / 2 + (overlay.toY + root.tileCenterY(overlay.toH) - (overlay.fromY + overlay.fromH / 2)) * overlay.morphT - overlay.iconSize / 2
        readonly property color fill: root.mix(Theme.accentContainer, Theme.bgTile, overlay.effectsT)
        readonly property color edge: Theme.alpha(Theme.text, 0.07 * overlay.effectsT)

        // The iris is a hole, not a disc: the ghost is kept outside the circle,
        // so a circle opening at the tile's centre uncovers the app. centre and
        // radius are in overlay pixels; the mask's soft stop keeps the rim to
        // about one pixel like the wallpaper iris.
        readonly property real revealCx: overlay.toX + overlay.toW / 2
        readonly property real revealCy: overlay.toY + overlay.toH / 2
        readonly property real revealMax: Math.hypot(overlay.toW / 2, overlay.toH / 2) + 2
        readonly property real revealSoftStop: overlay.revealRadius > 1 ? (overlay.revealRadius - 1) / overlay.revealRadius : 0

        function seed(rect, source, screen) {
            if (screen && overlay.screen !== screen)
                overlay.screen = screen;

            fadeAnim.stop();
            revealAnim.stop();
            morphAnim.stop();
            effectsAnim.stop();

            overlay.active = true;
            overlay.landed = false;
            overlay.fadingOut = false;
            overlay.revealing = false;
            overlay.revealRadius = 0;
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
            overlay.revealing = false;
            overlay.revealRadius = 0;
            revealAnim.stop();
            morphAnim.stop();
            effectsAnim.stop();
            fadeAnim.restart();
        }

        // The app has finished growing into the held tile. Keep the ghost where
        // it is and open a circle from the tile's centre; the hole is the only
        // place the real window shows through, so the handover has no edge to
        // cross-fade and no moment where the window is beside the tile.
        function snapLanded() {
            morphAnim.stop();
            effectsAnim.stop();
            overlay.morphT = 1;
            overlay.effectsT = 1;
            overlay.landed = true;
        }

        function revealOut() {
            if (!overlay.active || overlay.fadingOut || overlay.revealing)
                return;

            // a very fast app can land before the morph has finished; snap the
            // shape to the tile so the iris is cut from the right rectangle
            overlay.snapLanded();
            overlay.revealing = true;
            overlay.revealRadius = 0;
            revealAnim.restart();
            revealGuard.restart();
            root.traceLog("iris-start " + overlay.revealMax);
        }

        function finishReveal() {
            revealAnim.stop();
            overlay.active = false;
            overlay.landed = false;
            overlay.revealing = false;
            overlay.revealRadius = 0;
            overlay.contentOpacity = 0;
        }

        function reset() {
            fadeAnim.stop();
            revealAnim.stop();
            morphAnim.stop();
            effectsAnim.stop();
            overlay.active = false;
            overlay.landed = false;
            overlay.fadingOut = false;
            overlay.revealing = false;
            overlay.revealRadius = 0;
            overlay.contentOpacity = 0;
            overlay.morphT = 0;
            overlay.effectsT = 0;
            overlay.fromW = 0;
            overlay.fromH = 0;
            overlay.toW = 0;
            overlay.toH = 0;
        }

        Item {
            id: content

            anchors.fill: parent
            opacity: overlay.contentOpacity * (overlay.revealing ? Math.max(0, 1 - overlay.revealRadius / Math.max(1, overlay.revealMax)) : 1)
            visible: overlay.active && root.launchWorkspaceShown

            // the iris only exists for the handover; keeping the layer off
            // otherwise means no full-screen FBO while the tile is just held
            layer.enabled: overlay.revealing
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: revealMask
            }

            // the same squircle the compositor draws for real windows: the
            // seed is a circle (smoothing 0 is the exact circle SDF) while the
            // shape is icon-sized, and the corner exponent morphs with the
            // radius so the held tile already has the window's own curve
            SquircleRect {
                x: overlay.shapeX
                y: overlay.shapeY
                width: overlay.shapeW
                height: overlay.shapeH
                radius: overlay.shapeRadius
                smoothing: root.windowSmoothing * overlay.effectsT
                fillColor: overlay.fill
                borderColor: overlay.edge
                borderWidth: 1
            }

            Image {
                z: 1
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
                z: 1
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

            LoadingIndicator {
                id: overlayHalo

                readonly property real base: Math.max(Theme.dp(72), root.tileEdge(overlay.toW, overlay.toH) * 1.8)
                readonly property real full: Math.hypot(overlay.toW, overlay.toH) / (0.84 * overlayHalo.fit) * 1.02
                readonly property real p: overlay.revealing ? Math.min(1, (overlay.revealRadius / Math.max(1, overlay.revealMax)) / 0.6) : 0
                readonly property real centerY: root.tileCenterY(overlay.toH)

                width: base + (full - base) * overlayHalo.p
                height: width
                x: overlay.toX + (overlay.toW - width) / 2
                y: overlay.toY + centerY + (overlay.toH / 2 - centerY) * overlayHalo.p - height / 2
                z: 0.5
                // freeze the sequence for the iris so it becomes a clean disc
                running: (root.phase === "waiting" || root.phase === "done") && overlayHalo.p <= 0.001
                circleMorph: overlayHalo.p
                contained: false
                color: Theme.accent
                visible: (root.phase === "waiting" || root.phase === "done") && overlay.effectsT >= 0.999 && !root.ghostPlaced
            }
        }

        // White outside the iris, transparent inside it. MultiEffect reads the
        // alpha, so the ghost survives everywhere except the opening circle.
        Item {
            id: revealMask

            anchors.fill: parent
            visible: false
            // warm for the whole launch: the mask is a texture source, and
            // enabling it only when the iris starts can sample an empty layer
            // for one frame (which reads as the whole tile vanishing at once)
            layer.enabled: overlay.active

            Shape {
                anchors.fill: parent
                ShapePath {
                    fillGradient: RadialGradient {
                        centerX: overlay.revealCx
                        centerY: overlay.revealCy
                        centerRadius: Math.max(1, overlay.revealRadius)
                        focalX: overlay.revealCx
                        focalY: overlay.revealCy
                        spread: ShapeGradient.PadSpread

                        GradientStop {
                            position: 0
                            color: "transparent"
                        }

                        GradientStop {
                            position: overlay.revealSoftStop
                            color: "transparent"
                        }

                        GradientStop {
                            position: 1
                            color: "white"
                        }
                    }

                    startX: 0
                    startY: 0

                    PathLine {
                        x: overlay.width
                        y: 0
                    }

                    PathLine {
                        x: overlay.width
                        y: overlay.height
                    }

                    PathLine {
                        x: 0
                        y: overlay.height
                    }

                    PathLine {
                        x: 0
                        y: 0
                    }
                }
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

        // same fast-out rim as the workspace-bound ghost; the extra curve
        // values are the spring fallback used by this theme
        NumberAnimation {
            id: revealAnim

            target: overlay
            property: "revealRadius"
            from: 0
            to: overlay.revealMax
            duration: root.irisMs
            easing.type: Easing.Bezier
            easing.bezierCurve: root.irisCurve

            onFinished: {
                // hide the content first: dropping the layer mask while the
                // ghost is still visible would flash the whole tile back
                overlay.finishReveal();
                root.afterReveal();
            }
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

    // the expanding shape has landed on the tile. Hand the pixels to the
    // workspace-bound ghost so the rest of the wait uses Hyprland's own
    // workspace animations; the overlay only ever has to cover the morph.
    function onLanded() {
        if (root.phase === "idle" || root.phase === "")
            return;

        root.traceLog("morph-done");
        root.stats.landed = Date.now();
        root.ghostChecks = 0;
        root.tryGhostHandoff();
    }

    // the IPC client list can lag the move dispatches by a frame or two, so
    // verify placement over a few frames before committing to the ghost
    function tryGhostHandoff() {
        if (!root.useGhost || root.ghostPlaced || !overlay.active || overlay.fadingOut)
            return;

        if (root.ghostMatchesTile()) {
            root.ghostPlaced = true;
            ghost.surfaceShown = true;
            root.raiseGhost();
            overlay.fadeOut();
            root.traceLog("ghost-handoff");
            return;
        }

        if (++root.ghostChecks < 4)
            ghostHandoffTimer.restart();
        else
            root.traceLog("ghost-handoff-failed");
    }

    Timer {
        id: ghostHandoffTimer

        interval: 70
        onTriggered: root.tryGhostHandoff()
    }

    function ghostMatchesTile() {
        if (!root.useGhost || !root.tile)
            return false;

        var c = root.readClient(root.ghostAddr);
        if (!c || c.ws !== root.targetWs)
            return false;

        return Math.abs(c.x - root.tile.x) <= 2 && Math.abs(c.y - root.tile.y) <= 2 && Math.abs(c.width - root.tile.width) <= 2 && Math.abs(c.height - root.tile.height) <= 2;
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
        root.targetWs = "";
        root.appMatched = false;
        root.wsReasserted = false;
        root.appAddr = "";
        root.candidates = [];
        // the previous chain's pin is superseded by this launch
        pinTimer.stop();
        pinRetryTimer.stop();
        root.pinning = false;
        root.pinned = ({});
        root.pinRetry = [];
        root.pinWs = "";
        root.pinToken = "";
        root.pinClass = "";
        root.ghostPlaced = false;
        root.ghostChecks = 0;
        root.tileAdopted = false;
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
        // app's tile. The title is deliberately left alone: it is what the
        // no-border/no-shadow/no-blur rule matches on.
        root.placeholderParked = false;
        root.lookupWorkspace();
        return true;
    }

    // Which workspace the launch belongs to has to be read at the press.
    // Hyprland.focusedWorkspace is live, but while a special is up it *is*
    // that special, and a monitor's lastIpcObject is only refilled on an
    // explicit refresh: it can still name the workspace the shell started on.
    // Moving the placeholder to that stale name with follow = true is exactly
    // the jump to another workspace a launch used to make.
    Process {
        id: workspaceLookup

        command: ["hyprctl", "-j", "monitors"]

        stdout: StdioCollector {
            onStreamFinished: {
                // The launcher's own screen is authoritative: with several
                // monitors the focused one is not always the one the dock was
                // clicked on, and following it is how an app used to open on
                // the wrong workspace. The focused monitor is only the fallback.
                var reqScreen = root.req && root.req.screen ? String(root.req.screen.name || "") : "";
                var focused = "";
                var launched = "";
                try {
                    var list = JSON.parse(this.text);
                    for (var i = 0; i < list.length; i++) {
                        var m = list[i];
                        // activeWorkspace is the normal workspace underneath a
                        // special, which is where a launch belongs
                        if (!m || !m.activeWorkspace || !m.activeWorkspace.name)
                            continue;

                        var name = String(m.activeWorkspace.name);
                        if (name === "" || name.indexOf("special:") === 0)
                            continue;

                        if (m.focused)
                            focused = name;
                        if (reqScreen !== "" && String(m.name || "") === reqScreen)
                            launched = name;
                    }
                } catch (e) {
                    root.traceLog("workspace " + e);
                }

                var ws = launched !== "" ? launched : focused;

                if (root.phase !== "preparing")
                    return;

                if (ws === "" || ws.indexOf("special:") === 0)
                    ws = root.launchWorkspace();

                root.targetWs = ws;
                root.traceLog("workspace " + ws);
                root.lookupPlaceholder();
            }
        }
    }

    function lookupWorkspace() {
        if (!workspaceLookup.running)
            workspaceLookup.running = true;
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
                var ghost = "";
                try {
                    var list = JSON.parse(this.text);
                    for (var i = 0; i < list.length; i++) {
                        var c = list[i];
                        var t = String(c.title || "");
                        if (String(c.class || "") !== "org.quickshell")
                            continue;

                        if (t === root.ghostTitle && ghost === "")
                            ghost = String(c.address || "");
                        else if ((t === root.stableTitle || t.indexOf("Launching ") === 0) && addr === "")
                            addr = String(c.address || "");
                    }
                } catch (e) {
                    root.traceLog("lookup " + e);
                }
                root.ghostAddr = ghost;
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
        if (root.targetWs === "")
            root.targetWs = root.launchWorkspace();
        root.send("dispatch hl.dsp.window.move({ workspace = \"" + root.targetWs + "\", window = \"address:" + root.placeholderAddr + "\", follow = true })");
        root.stats.unpark = Date.now();
        root.traceLog("unpark " + addr + " to " + root.targetWs);
        tilePoll.restart();
    }

    // fallback for when hyprctl cannot name the focused monitor's workspace.
    // Hyprland.focusedWorkspace follows every workspace change, so it is the
    // live one; it only has to be guarded against naming a special workspace.
    function launchWorkspace() {
        var fw = Hyprland.focusedWorkspace;
        var name = fw && fw.name ? String(fw.name) : "";
        return name === "" || name.indexOf("special:") === 0 ? "1" : name;
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
                root.placeGhost(r);
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

        // start pinning with the token alone: a multi-step app can open more
        // than one window before the first one is matched. The class is filled
        // in by matchWindow once we know it.
        root.pinWs = root.targetWs;
        root.pinToken = root.token;
        root.pinClass = "";
        root.pinned = ({});
        root.pinning = root.pinWs !== "";
        pinTimer.restart();

        root.stats.exec = Date.now();
        root.traceLog("exec " + root.req.command);
        // The helper starts the app in its own transient systemd scope. A
        // plain execDetached only detaches the process tree; the app would
        // still inherit quickshell's cgroup, and stopping or restarting the
        // shell (KillMode=control-group) would take it down with the shell.
        // The helper also exports the launch token the pin below reads.
        Quickshell.execDetached([
            Qt.resolvedUrl("../scripts/launch-detached.sh").toString().replace("file://", ""),
            root.token,
            root.req.command
        ]);
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
            // only re-take the keyboard once the tile is really on the target
            // workspace. focusing the placeholder while it is still parked
            // reveals the parking special workspace and hands it the keyboard
            // for good, which is how a launch used to strand the desktop there
            if (root.phase === "waiting" && root.placeholderAddr !== "" && root.readTile() !== null)
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
            // A special workspace floats over every regular one, so if the
            // parking workspace is ever left up it becomes the focused
            // workspace; Hyprland then opens every new window there and those
            // apps follow you across all workspaces. Hide it the moment it is
            // shown: it only ever holds the invisible placeholder and ghost.
            if (event.name === "activespecial") {
                if (String(event.data || "").split(",")[0] === root.parkWorkspace && root.phase === "idle")
                    root.hideParkWorkspace();
                return;
            }

            if (event.name === "configreloaded") {
                root.installRules();
                root.probeAnimations();
                return;
            }

            if (event.name === "closewindow") {
                var closed = "0x" + String(event.data).split(",")[0];
                if (closed === root.placeholderAddr) {
                    root.placeholderAddr = "";
                    root.ready = false;
                    root.traceLog("placeholder closed");
                }
                if (closed === root.ghostAddr) {
                    root.ghostAddr = "";
                    root.ghostParked = true;
                    root.traceLog("ghost closed");
                }
                return;
            }

            if (event.name === "openwindow") {
                var parts = String(event.data).split(",");
                var addr = "0x" + parts[0];
                var ws = parts[1] || "";
                var cls = parts[2] || "";
                var title = parts.length > 3 ? parts.slice(3).join(",") : "";

                if (title === root.ghostTitle) {
                    root.ghostAddr = addr;
                    return;
                }

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

                // later steps of a multi-window launch (updater → splash →
                // main window) belong to the same launch: pin each one to the
                // launch workspace without stealing focus
                if (root.pinning && addr !== root.placeholderAddr && root.pinned[addr] !== true) {
                    root.pinned[addr] = true;
                    if (root.pinClass !== "" && root.classesMatch(cls, root.pinClass))
                        root.moveToPin(addr, ws);
                    else
                        root.probePinToken(addr, ws);
                }

                // a new floating helper can land above the ghost; keep the
                // held tile on top of the launch's own windows
                if (root.useGhost && root.phase !== "idle" && root.phase !== "preparing")
                    root.raiseGhost();

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
                            root.placeGhost(r);
                            overlay.morphTo(r);
                            root.launchApp();
                        }
                    }
                }
            }
        }
    }

    // one class pair, with the fuzziness the launcher entries need
    function classesMatch(cls, want) {
        if (!cls || !want)
            return false;

        var c = String(cls).toLowerCase();
        var w = String(want).toLowerCase();
        if (w === "")
            return false;

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

        return false;
    }

    function classMatches(cls) {
        if (!cls || !root.req)
            return false;

        if (root.req.wmClass && root.classesMatch(cls, root.req.wmClass))
            return true;
        if (root.req.base && root.classesMatch(cls, root.req.base))
            return true;
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

    // A serialized probe: a step in the chain may open while the previous
    // window is still being checked.
    Process {
        id: pinProbe

        property var queue: []
        property var current: null

        function push(job) {
            queue.push(job);
            pump();
        }

        function pump() {
            if (running || queue.length === 0)
                return;

            current = queue.shift();
            command = ["sh", "-c", "grep -qaF \"$1\" /proc/$2/environ 2>/dev/null", "sh", "LUCID_LAUNCH_TOKEN=" + current.token, String(current.pid)];
            running = true;
        }

        onExited: (code) => {
            var job = current;
            current = null;
            if (code === 0 && job && root.pinning && job.token === root.pinToken)
                root.moveToPin(job.addr, job.ws);
            pump();
        }
    }

    function probePinToken(addr, ws, attempt) {
        if (!root.pinning || root.pinToken === "")
            return;

        // openwindow arrives before refreshToplevels has folded the new
        // toplevel in, so a brand-new window often has no pid on the first
        // look; give the IPC a couple of frames before giving up
        var pid = root.pidOf(addr);
        if (!pid) {
            if ((attempt || 0) < 2) {
                root.pinRetry.push({
                    "addr": addr,
                    "ws": ws,
                    "attempt": (attempt || 0) + 1
                });
                if (!pinRetryTimer.running)
                    pinRetryTimer.start();
            } else {
                root.traceLog("pin-nopid " + addr);
            }
            return;
        }

        root.traceLog("pin-probe " + addr + " ws " + ws + " pid " + pid);
        pinProbe.push({
            "addr": addr,
            "ws": ws,
            "token": root.pinToken,
            "pid": pid
        });
    }

    Timer {
        id: pinRetryTimer

        interval: root.pinRetryMs
        onTriggered: {
            var pending = root.pinRetry;
            root.pinRetry = [];
            for (var i = 0; i < pending.length; i++)
                root.probePinToken(pending[i].addr, pending[i].ws, pending[i].attempt);
        }
    }

    function moveToPin(addr, ws) {
        if (!root.pinning || addr === "" || root.pinWs === "")
            return;

        if (ws !== "" && ws !== root.pinWs) {
            root.traceLog("pin " + addr + " " + ws + " -> " + root.pinWs);
            root.stats.pinned = root.stats.pinned ? root.stats.pinned + 1 : 1;
            root.send("dispatch hl.dsp.window.move({ workspace = \"" + root.pinWs + "\", window = \"address:" + addr + "\", follow = false })");
        }

        // Updater/splash windows often ask to float or keep their own size.
        // Being moved is not enough to make them part of the layout, so put
        // them back under the tiling manager as well.
        root.send("dispatch hl.dsp.window.float({ action = \"disable\", window = \"address:" + addr + "\" })");
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

        // follow the rest of the launch (updaters, splashes, the main window):
        // pinning started at exec with the token; now the class match makes the
        // cheap path work too
        root.pinWs = root.targetWs;
        root.pinToken = root.token;
        root.pinClass = String(cls || "");
        root.pinning = root.pinWs !== "";
        root.pinned[addr] = true;
        if (!pinTimer.running)
            pinTimer.restart();

        // an app can override the focused workspace (its own rule, a stale
        // rule, or a slow map that lands after the press). pin it to the one
        // the launch belongs to before the tile is released.
        if (root.targetWs !== "" && ws !== "" && ws !== root.targetWs) {
            root.traceLog("rehome " + addr + " " + ws + " -> " + root.targetWs);
            root.stats.rehomed = [ws, root.targetWs];
            // never drag the user back if they already left the launch
            // workspace while the app was starting
            root.send("dispatch hl.dsp.window.move({ workspace = \"" + root.targetWs + "\", window = \"address:" + addr + "\", follow = " + (root.launchWorkspaceShown ? "true" : "false") + " })");
        }

        if (root.launchWorkspaceShown)
            root.send("dispatch hl.dsp.focus({ window = \"address:" + addr + "\" })");

        // the placeholder is a *tiled* reservation; an app window that opened
        // floating would neither match the held tile nor fill it, so put the
        // matched window into the layout before the tile is released
        root.send("dispatch hl.dsp.window.float({ action = \"disable\", window = \"address:" + addr + "\" })");
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
        handoverHold.stop();

        // the app is already tiled beside the placeholder; taking the
        // placeholder away lets dwindle give the app the whole held tile. the
        // overlay keeps drawing the tile, so that split and the expansion it
        // causes are never visible: only the app's final frame is underneath.
        if (root.placeholderAddr !== "" && root.placeholderAddr !== root.appAddr) {
            root.send("dispatch hl.dsp.window.move({ workspace = \"" + root.parkWorkspace + "\", window = \"address:" + root.placeholderAddr + "\", follow = false })");
            root.placeholderParked = true;
            root.hideParkWorkspace();
            root.stamp("parked", matched);
        } else {
            root.placeholderAddr = "";
            root.placeholderParked = false;
        }

        root.stamp("finish", matched);

        // wait for the real window to finish growing into the freed tile before
        // opening the iris, or the circle would reveal it while it is still the
        // half-width split beside the placeholder
        if (matched && root.appAddr !== "" && root.tile) {
            settlePoll.tries = 0;
            settlePoll.restart();
        } else {
            root.fadeTile();
            resetTimer.restart();
        }
    }

    function readClient(addr) {
        if (addr === "")
            return null;

        Hyprland.refreshToplevels();
        var t = Hyprland.toplevels.values;
        for (var i = 0; i < t.length; i++) {
            var o = t[i].lastIpcObject;
            if (!o || o.address !== addr || !o.at || !o.size)
                continue;

            return {
                "x": o.at[0],
                "y": o.at[1],
                "width": o.size[0],
                "height": o.size[1],
                "ws": o.workspace ? String(o.workspace.name || "") : ""
            };
        }
        return null;
    }

    function readAppRect() {
        var c = root.readClient(root.appAddr);
        // only a client that is really on the launch workspace can stand in
        // for the held tile; anything else would make the iris reveal another
        // workspace's window
        return c && c.ws === root.targetWs ? c : null;
    }

    function rectsClose(a, b) {
        if (!a || !b)
            return false;

        // tiling geometry is integer, but a border or a rounding pixel can
        // still differ by one; anything larger means the window is elsewhere
        return Math.abs(a.x - b.x) <= 2 && Math.abs(a.y - b.y) <= 2 && Math.abs(a.width - b.width) <= 2 && Math.abs(a.height - b.height) <= 2;
    }

    function rectOverlap(a, b) {
        if (!a || !b)
            return 0;

        var w = Math.max(0, Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x));
        var h = Math.max(0, Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y));
        var ref = Math.min(a.width * a.height, b.width * b.height);
        return ref > 0 ? (w * h) / ref : 0;
    }

    Timer {
        id: settlePoll

        interval: 16
        repeat: true
        property int tries: 0

        onTriggered: {
            if (root.phase !== "done") {
                stop();
                return;
            }

            var r = root.readAppRect();
            if (r && root.rectsClose(r, root.tile)) {
                stop();
                root.stats.appFinal = [r.x, r.y, r.width, r.height];
                root.stamp("settled", [r.x, r.y, r.width, r.height]);
                // the rect is already the tile, but the window is still
                // animating into it; let the motion finish under the ghost
                handoverHold.restart();
                return;
            }

            // the app's rect is the authority if the placeholder's tile went
            // stale (a bar/dock layer was not in the layout when it parked).
            // Only adopt a window that really fills the tile, not a dialog.
            if (r && !root.tileAdopted && root.tile) {
                var fills = (r.width * r.height) / (root.tile.width * root.tile.height);
                if (fills >= 0.8 && root.rectOverlap(r, root.tile) >= 0.9) {
                    stop();
                    root.stats.appFinal = [r.x, r.y, r.width, r.height];
                    root.adoptTile(r);
                    root.stamp("settled", [r.x, r.y, r.width, r.height]);
                    handoverHold.restart();
                    return;
                }
            }

            // windowsMove can be slow with a settle curve; if the app is close
            // enough (or simply inside the tile) reveal anyway rather than
            // keep the ghost up forever
            if (++tries > 80) {
                stop();
                var overlap = root.rectOverlap(r, root.tile);
                if (r)
                    root.stats.appFinal = [r.x, r.y, r.width, r.height];
                root.traceLog("settle-timeout " + JSON.stringify(r) + " overlap " + overlap);
                if (r && overlap >= 0.5) {
                    handoverHold.restart();
                } else {
                    // the app never took the tile (a small dialog, another
                    // workspace, …): fade the ghost and release the phase
                    root.fadeTile();
                    resetTimer.restart();
                }
            }
        }
    }

    Timer {
        id: handoverHold

        // one poll frame for the detection plus the compositor's own move
        // animation; without it the iris opens on a half-sized window
        interval: Math.max(0, root.moveAnimMs) + 40

        onTriggered: {
            if (root.phase !== "done")
                return;

            var c = root.readClient(root.appAddr);
            var shown = root.launchWorkspaceShown;

            // The hold gives focus and the app time to drift. Re-assert the
            // launch workspace once, then give the move its own animation
            // before the iris; if it still is not there, do not reveal another
            // workspace's content.
            if (c && c.ws !== "" && root.targetWs !== "" && c.ws !== root.targetWs) {
                if (!root.wsReasserted) {
                    root.wsReasserted = true;
                    root.traceLog("rehome-late " + c.ws + " -> " + root.targetWs);
                    root.stats.rehomedLate = [c.ws, root.targetWs];
                    root.send("dispatch hl.dsp.window.move({ workspace = \"" + root.targetWs + "\", window = \"address:" + root.appAddr + "\", follow = " + (shown ? "true" : "false") + " })");
                    handoverHold.restart();
                    return;
                }

                root.traceLog("handover-off-workspace " + c.ws);
                root.fadeTile();
                resetTimer.restart();
                return;
            }

            // the user is looking at another workspace: the app still belongs
            // to the launch workspace, but there is nothing to reveal here
            if (!shown) {
                root.traceLog("handover-elsewhere " + root.overlayWorkspace + " (launch " + root.targetWs + ")");
                root.finishTile();
                resetTimer.restart();
                return;
            }

            if (root.appAddr !== "") {
                // make the launch workspace the one on screen again: the iris
                // only makes sense over the window it is revealing
                root.send("dispatch hl.dsp.focus({ window = \"address:" + root.appAddr + "\" })");
            }

            root.traceLog("handover " + root.moveAnimMs + " ws " + (c ? c.ws : "?"));
            root.revealTile();
            // revealOut is a no-op if the tile visual was already fading; never
            // leave the phase stuck on "done" in that case
            if (!root.tileRevealing() && !overlay.fadingOut) {
                root.fadeTile();
                resetTimer.restart();
            }
        }
    }

    Timer {
        id: revealGuard

        interval: root.irisMs + 400
        onTriggered: {
            if (root.phase !== "done")
                return;

            root.traceLog("iris-guard");
            root.finishTile();
            root.afterReveal();
        }
    }

    // the tile visual lives on the workspace-bound ghost when it exists; the
    // overlay is only the fallback and the morph surface
    function revealTile() {
        // a very fast app can settle before the morph has landed, so re-check
        // the ghost's real placement here as well as on landing
        if (root.useGhost && !root.ghostPlaced && root.ghostMatchesTile())
            root.ghostPlaced = true;

        ghostHandoffTimer.stop();
        root.traceLog("reveal-tile " + (root.ghostPlaced ? "ghost" : "overlay"));

        if (!root.ghostPlaced) {
            overlay.revealOut();
            return;
        }

        if (!ghost.surfaceShown) {
            overlay.snapLanded();
            ghost.surfaceShown = true;
            root.raiseGhost();
            overlay.fadeOut();
        }

        ghost.revealOut();
    }

    function finishTile() {
        if (root.ghostPlaced)
            ghost.finishReveal();
        else
            overlay.finishReveal();
    }

    function fadeTile() {
        if (root.ghostPlaced)
            ghost.finishReveal();
        overlay.fadeOut();
    }

    function tileRevealing() {
        return root.ghostPlaced ? ghost.revealing : overlay.revealing;
    }

    // the iris has finished: the app is the only thing left on the tile
    function afterReveal() {
        revealGuard.stop();
        root.traceLog("iris-done " + JSON.stringify(root.stats.appFinal || null));
        resetTimer.restart();
    }

    // outlives the launch handoff on purpose: the app's later windows still
    // belong to the workspace the launch was made on
    Timer {
        id: pinTimer

        interval: root.pinWindowMs
        onTriggered: {
            root.pinning = false;
            root.pinned = ({});
            root.pinRetry = [];
            root.traceLog("pin-end");
        }
    }

    Timer {
        id: resetTimer

        // outlasts the failure crossfade as well as the iris
        interval: 300
        onTriggered: {
            handoverHold.stop();
            root.phase = "idle";
            root.req = null;
            root.appMatched = false;
            root.appAddr = "";
            root.tile = null;
            root.placeholderParked = true;
            placeholder.title = root.stableTitle;
            root.finishTile();
            root.parkGhost();
            root.ghostPlaced = false;
            root.ghostChecks = 0;
            root.tileAdopted = false;
            ghostHandoffTimer.stop();
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
            var title = o ? String(o.title || "") : "";
            // "Launching " is a title an older build used; accept it so a
            // window left that way is found, then put the stable title back so
            // the window rule matches it again
            if (o && o.address && (title === root.stableTitle || title.indexOf("Launching ") === 0)) {
                if (title !== root.stableTitle)
                    placeholder.title = root.stableTitle;
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

    // the parking workspace must never be left on screen: focusing the
    // placeholder while it is still parked brings it up, and it stays up for
    // every later launch. put it away after every park.
    function hideParkWorkspace() {
        root.send("dispatch " + root.hideParkDispatch);
    }

    function parkPlaceholder() {
        if (root.placeholderAddr === "")
            return;
        root.send("dispatch hl.dsp.window.move({ workspace = \"" + root.parkWorkspace + "\", window = \"address:" + root.placeholderAddr + "\", follow = false })");
        root.placeholderParked = true;
        root.hideParkWorkspace();
        readyTimer.restart();
    }

    // ---- the workspace-bound ghost --------------------------------------
    function findGhost() {
        Hyprland.refreshToplevels();
        var t = Hyprland.toplevels.values;
        for (var i = 0; i < t.length; i++) {
            var o = t[i].lastIpcObject;
            if (o && o.address && o.title === root.ghostTitle) {
                if (root.ghostAddr !== o.address) {
                    root.ghostAddr = o.address;
                    root.traceLog("ghost " + o.address + " " + (o.workspace ? o.workspace.name : ""));
                }
                return true;
            }
        }
        return false;
    }

    function placeGhost(rect) {
        if (!root.useGhost || !rect)
            return;

        ghost.finishReveal();
        root.ghostPlaced = false;
        root.ghostChecks = 0;
        root.tileAdopted = false;
        var w = Math.max(1, Math.round(rect.width));
        var h = Math.max(1, Math.round(rect.height));
        ghost.implicitWidth = w;
        ghost.implicitHeight = h;

        root.send("dispatch hl.dsp.window.move({ workspace = \"" + root.targetWs + "\", window = \"address:" + root.ghostAddr + "\", follow = false })");
        // a floating toplevel does not follow its QML size after map, so size
        // it through the compositor too
        root.send("dispatch hl.dsp.window.resize({ x = " + w + ", y = " + h + ", exact = true, window = \"address:" + root.ghostAddr + "\" })");
        root.send("dispatch hl.dsp.window.move({ x = " + Math.round(rect.x) + ", y = " + Math.round(rect.y) + ", relative = false, window = \"address:" + root.ghostAddr + "\" })");
        root.raiseGhost();
        root.ghostParked = false;
        root.traceLog("ghost-place " + JSON.stringify([rect.x, rect.y, rect.width, rect.height]));
    }

    function fitGhost(rect) {
        if (root.ghostAddr === "" || !rect)
            return;

        var w = Math.max(1, Math.round(rect.width));
        var h = Math.max(1, Math.round(rect.height));
        ghost.implicitWidth = w;
        ghost.implicitHeight = h;
        root.send("dispatch hl.dsp.window.resize({ x = " + w + ", y = " + h + ", exact = true, window = \"address:" + root.ghostAddr + "\" })");
        root.send("dispatch hl.dsp.window.move({ x = " + Math.round(rect.x) + ", y = " + Math.round(rect.y) + ", relative = false, window = \"address:" + root.ghostAddr + "\" })");
        root.raiseGhost();
        root.traceLog("ghost-fit " + JSON.stringify([rect.x, rect.y, w, h]));
    }

    // The held tile is usually exact; when a reserved layer (bar/dock) was not
    // in the layout when the placeholder was parked, the app's real rect can
    // differ. Adopt it if it is still clearly the same tile, so the iris
    // reveals the window rather than a stale outline around it.
    function adoptTile(rect) {
        if (!rect || root.tileAdopted)
            return;

        root.tileAdopted = true;
        root.tile = rect;
        root.stats.tileAdopted = [rect.x, rect.y, rect.width, rect.height];
        root.traceLog("tile-adopt " + JSON.stringify(root.stats.tileAdopted));

        if (root.ghostPlaced) {
            root.fitGhost(rect);
        } else {
            overlay.toX = rect.x - overlay.ox;
            overlay.toY = rect.y - overlay.oy;
            overlay.toW = Math.max(1, rect.width);
            overlay.toH = Math.max(1, rect.height);
        }
    }

    function raiseGhost() {
        if (!root.useGhost)
            return;
        root.send("dispatch hl.dsp.window.alter_zorder({ mode = \"top\", window = \"address:" + root.ghostAddr + "\" })");
    }

    function parkGhost() {
        if (root.ghostAddr === "")
            return;
        ghost.finishReveal();
        root.send("dispatch hl.dsp.window.move({ workspace = \"" + root.parkWorkspace + "\", window = \"address:" + root.ghostAddr + "\", follow = false })");
        root.ghostParked = true;
        root.hideParkWorkspace();
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
        onTriggered: {
            root.findPlaceholder();
            root.findGhost();
        }
    }

    Timer {
        interval: 600
        running: true
        repeat: false
        onTriggered: {
            if (!root.findPlaceholder())
                findAgain.start();
            root.findGhost();
        }
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

            // safety net for the activespecial guard: if the parking workspace
            // is still on screen (an event we never saw, or a reload), put it
            // away before it can attract the next app
            var fw = Hyprland.focusedWorkspace;
            if (fw && String(fw.name || "") === root.parkWorkspace)
                root.hideParkWorkspace();

            // cheap refresher: this also repairs a stale address after a hot
            // reload, without touching a window that is still mapped
            root.findGhost();
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
        root.probeAnimations();
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
                "moveMs": root.moveAnimMs,
                "target": root.targetWs,
                "overlayWs": root.overlayWorkspace,
                "shown": root.launchWorkspaceShown,
                "ghost": [ghost.width, ghost.height, root.ghostAddr],
                "ghostPlaced": root.ghostPlaced,
                "pin": {
                    "on": root.pinning,
                    "ws": root.pinWs,
                    "class": root.pinClass
                },
                "stats": root.stats
            });
        }
    }
}

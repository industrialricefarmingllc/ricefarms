import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs
import "../squircle"

// Screen-fixed soft-light wallpaper drawn ON TOP of the visible windows,
// clipped to each window's rounded corners. Opaque apps get the wash; the real
// wallpaper stays sharp in the gaps. Fullscreen windows are excluded, so a
// fullscreen app never gets the wash.
//
// Top layer, created before the bar: windows are below it, the shell's own
// surfaces (bar, dock, launcher, OSD) are above it, so the wash never paints
// over the UI. Hyprland hides Top layers while a window is fullscreen, which
// costs nothing here because a fullscreen window is excluded anyway.
//
// Geometry is streamed by support/lucid/hypr-rects.py: Hyprland 0.56 has no
// move/resize events left in the IPC, so a dragged, resized or re-tiled window
// can only be followed by asking, and hyprctl costs ~8ms a call. Workspace
// switches are replayed as well (see armSwitch) so the clip travels with its
// window instead of appearing at the destination early.
PanelWindow {
    id: root

    required property var modelData

    screen: root.modelData
    color: "transparent"
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "lucid-overlay"
    mask: Region {
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    // ── geometry ────────────────────────────────────────────────────────
    // [{"m": monitor, "w": workspace, "s": special, "r": [[x,y,w,h,flag]]}]
    // rects are screen-local logical px, flag 1 marks a special workspace
    property var state: []

    readonly property var monState: {
        const n = String(root.screen.name);
        for (const m of root.state) {
            if (m.m === n)
                return m;
        }
        return null;
    }
    readonly property string specialName: root.monState ? root.monState.s : ""
    readonly property int workspaceId: root.monState ? root.monState.w : -1
    readonly property var liveRects: {
        const out = [];
        const rows = root.monState ? root.monState.r : [];
        for (const e of rows)
            out.push({ "x": e[0], "y": e[1], "w": e[2], "h": e[3], "special": e[4] === 1 });
        return out;
    }

    Process {
        id: geometry

        running: true
        command: ["python3", Quickshell.env("HOME") + "/.config/lucid/hypr-rects.py"]

        stdout: SplitParser {
            onRead: (line) => {
                try {
                    root.state = JSON.parse(line);
                    streamStale.restart();
                } catch (e) {
                }
            }
        }
    }

    Timer {
        interval: 1500
        repeat: true
        running: !geometry.running
        onTriggered: geometry.running = true
    }

    // no line for this long means the stream died: drop the wash rather than
    // leave a frozen rectangle over the wallpaper
    Timer {
        id: streamStale

        interval: 3000
        onTriggered: root.state = []
    }

    FileView {
        id: texturePath

        path: Quickshell.env("HOME") + "/.cache/quickshell/wallpaper-softlight.path"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.imagePath = text().trim()
    }

    property string imagePath: ""
    readonly property string imageSource: root.imagePath !== "" ? "file://" + root.imagePath : ""

    // ── workspace motion ────────────────────────────────────────────────
    // Hyprland moves a switch with a workspace render offset that no IPC field
    // carries, so it is replayed here from what the compositor does say: the
    // style from the live animation tree (custom.lua steers it per jump: slide
    // right/left, slidevert top/bottom, or fade), the duration from Hyprland's
    // 100 * speed formula with the workspaces leaf at 4.43, and the default
    // bezier. The engine reads the suffix as the edge the incoming workspace
    // slides in from, and a bare "slide" falls back to the id comparison.
    readonly property int slideMs: 443
    // 0 idle, 1 workspace switch, 2 special opening, 3 special closing
    property int phase: 0
    // eased 0..1 across the switch, on Hyprland's cubic-bezier(0, .75, .15, 1)
    property real slide: 1
    property bool switching: false
    property double startedAt: 0
    property var before: []
    // { dx, dy, fade } for the jump being replayed
    property var step: ({ "dx": 0, "dy": 0, "fade": false })
    property var outgoing: []
    // what the wash draws: bx + dx * slide, by + dy * slide, alpha a0 -> a1
    property var drawn: []

    function entry(out, r, bx, by, dx, dy, a0, a1) {
        out.push({ "bx": bx, "by": by, "dx": dx, "dy": dy, "w": r.w, "h": r.h, "a0": a0, "a1": a1 });
    }

    function rest(rects) {
        const out = [];
        for (const r of rects)
            root.entry(out, r, r.x, r.y, 0, 0, 1, 1);
        return out;
    }

    function same(a, b) {
        if (a.length !== b.length)
            return false;
        for (let i = 0; i < a.length; i++) {
            if (a[i].bx !== b[i].bx || a[i].by !== b[i].by || a[i].w !== b[i].w || a[i].h !== b[i].h || a[i].a0 !== b[i].a0 || a[i].dx !== b[i].dx)
                return false;
        }
        return true;
    }

    // The style is the one thing only the compositor knows: custom.lua steers
    // it per jump (slide right/left, slidevert top/bottom, fade) and a bare
    // "slide" falls back to the engine's id comparison. Reading it costs a
    // process, so the clock starts on the event and the progress is computed
    // from how long the answer took: the slide is where the compositor's own
    // is by the time the first frame is drawn.
    property bool armed: false
    property var jump: ({ "from": 0, "to": 0 })

    function armSwitch(p, from, to) {
        root.before = root.liveRects;
        root.phase = p;
        root.jump = { "from": from, "to": to };
        root.step = { "dx": 0, "dy": 0, "fade": false };
        root.armed = true;
        root.startedAt = Date.now();
        styleTimeout.restart();
        styleQuery.running = true;
    }

    function styleOf(text) {
        try {
            const data = JSON.parse(text);
            const list = Array.isArray(data[0]) ? data[0] : data;
            for (const n of list) {
                if (n && n.name === "workspaces")
                    return String(n.style || "");
            }
        } catch (e) {
        }
        return "";
    }

    function startSwitch(text) {
        if (!root.armed)
            return;
        root.armed = false;
        styleTimeout.stop();

        const style = root.styleOf(text) || "slide";
        const parts = style.split(/\s+/);
        const edge = parts.length > 1 ? parts[1] : "";
        const vert = style.indexOf("slidevert") === 0;
        const fade = style.indexOf("fade") === 0 && style.indexOf("slidefade") !== 0;
        // fallback for a bare "slide": ANIMTOLEFT, i.e. a higher id travels
        // left; specials pass their own left (IN from the right, OUT to it)
        let left = root.phase === 2 ? true : (root.phase === 3 ? false : root.jump.to > root.jump.from);
        if (edge === "right" || edge === "bottom")
            left = true;
        else if (edge === "left" || edge === "top")
            left = false;

        const dx = fade ? 0 : (vert ? 0 : (left ? -1 : 1) * root.screen.width);
        const dy = fade ? 0 : (vert ? (left ? -1 : 1) * root.screen.height : 0);
        root.step = { "dx": dx, "dy": dy, "fade": fade };

        const out = [];
        for (const r of root.before) {
            if (root.phase === 2)
                // only the special layer moves; the normal one stays put
                root.entry(out, r, r.x, r.y, 0, 0, 1, 1);
            else if (r.special && root.phase === 3)
                // leaving: specials fade out whatever the style says
                root.entry(out, r, r.x, r.y, dx, dy, 1, 0);
            else
                root.entry(out, r, r.x, r.y, dx, dy, 1, fade ? 0 : 1);
        }

        root.outgoing = out;
        root.switching = true;
        root.drawn = out;
        // the stream may already have moved on while the style was fetched, in
        // which case the incoming set can go in right now
        root.rebuildSlide();
        root.tick();
    }

    // The incoming geometry is whatever the stream holds now: it can still be
    // a tick behind, so it is redone on every update until the slide ends.
    function rebuildSlide() {
        if (!root.switching)
            return;
        const out = root.outgoing.slice();
        const s = root.step;
        if (root.phase === 1) {
            // the stream is a tick behind at the start of a switch: building
            // the incoming set from the old workspace's rects would slide a
            // wash for windows that are not there onto the new workspace
            if (root.jump.to > 0 && root.workspaceId !== root.jump.to)
                return;
            for (const r of root.liveRects)
                root.entry(out, r, r.x - s.dx, r.y - s.dy, s.dx, s.dy, s.fade ? 0 : 1, 1);
        } else if (root.phase === 2) {
            for (const r of root.liveRects) {
                if (r.special)
                    root.entry(out, r, r.x - s.dx, r.y - s.dy, s.dx, s.dy, 0, 1);
            }
        }
        root.drawn = out;
    }

    function endSlide() {
        const behind = root.phase === 1 && root.jump.to > 0 && root.workspaceId !== root.jump.to;
        root.switching = false;
        root.phase = 0;
        root.slide = 1;
        root.outgoing = [];
        // the outgoing clips are already off-screen; if the stream has not
        // reported the new workspace yet, nothing is better than the old set
        root.drawn = behind ? [] : root.rest(root.liveRects);
    }

    // every geometry tick: follow a drag or a re-tile, or rebuild the slide
    onStateChanged: {
        if (root.armed)
            return;
        if (root.switching) {
            root.rebuildSlide();
        } else {
            const next = root.rest(root.liveRects);
            if (!root.same(root.drawn, next))
                root.drawn = next;
        }
    }

    // Hyprland's cubic-bezier(0, 0.75, 0.15, 1), solved for x = p
    function ease(p) {
        let lo = 0;
        let hi = 1;
        for (let i = 0; i < 20; i++) {
            const t = (lo + hi) / 2;
            const x = 3 * (1 - t) * (1 - t) * t * 0.0 + 3 * (1 - t) * t * t * 0.15 + t * t * t;
            if (x < p)
                lo = t;
            else
                hi = t;
        }
        const t = (lo + hi) / 2;
        return 3 * (1 - t) * (1 - t) * t * 0.75 + 3 * (1 - t) * t * t * 1.0 + t * t * t;
    }

    // driven off the wall clock rather than an animation object, so the style
    // query's latency is already accounted for when the first frame is drawn
    function tick() {
        if (!root.switching)
            return;
        const p = (Date.now() - root.startedAt) / root.slideMs;
        root.slide = root.ease(Math.min(1, Math.max(0, p)));
        if (p >= 1)
            root.endSlide();
    }

    // the frame clock needs to sit in a rendered item to be ticked
    Item {
        anchors.fill: parent

        FrameAnimation {
            running: root.switching
            onTriggered: root.tick()
        }

    }

    Repeater {
        model: root.drawn

        Item {
            required property var modelData

            x: modelData.bx + modelData.dx * root.slide
            y: modelData.by + modelData.dy * root.slide
            width: modelData.w
            height: modelData.h
            clip: true
            opacity: modelData.a0 + (modelData.a1 - modelData.a0) * root.slide
            // Follow the compositor's own window rounding: without it the wash
            // spills into the corner triangles outside the window and leaves a
            // faint halo on the wallpaper behind each corner.
            layer.enabled: true
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: windowMask
            }

            Item {
                id: windowMask

                anchors.fill: parent
                visible: false
                layer.enabled: true

                SquircleMask {
                    anchors.fill: parent
                    radius: Theme.windowRadius
                    smoothing: Prefs.squircleF
                }
            }

            Image {
                // the texture is the screen's, so it stays put while the clip
                // slides with its window
                x: -parent.x
                y: -parent.y
                width: root.width
                height: root.height
                source: root.imageSource
                fillMode: Image.Stretch
                asynchronous: false
                cache: true
                smooth: true  // half-res wash: bilinear is invisible here and avoids 2x2 blocks
                mipmap: false
            }
        }
    }

    Process {
        id: styleQuery

        command: ["hyprctl", "animations", "-j"]
        stdout: StdioCollector {
            onStreamFinished: root.startSwitch(this.text)
        }
    }

    // a query that never answers must not leave the switch armed for ever
    Timer {
        id: styleTimeout

        interval: 120
        onTriggered: root.startSwitch("")
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            // The legacy event is posted before Quickshell moves this monitor's
            // active workspace, which is the only moment the outgoing geometry
            // and the old workspace id are both still readable.
            switch (event.name) {

            case "workspace":
                {
                    const to = parseInt(event.data, 10);
                    const from = root.workspaceId;
                    if (!isNaN(to) && from > 0 && to !== from)
                        root.armSwitch(1, from, to);
                }
                break;
            case "activespecial":
                {
                    const parts = String(event.data).split(",");
                    // the shell toggles its launcher placeholder special on
                    // every workspace switch; taking it would restart the slide
                    if (root.switching || root.armed)
                        break;
                    if (parts.length > 1 && parts[1] === String(root.screen.name))
                        root.armSwitch(parts[0] !== "" ? 2 : 3, 0, 0);
                }
                break;
            }
        }
    }
}

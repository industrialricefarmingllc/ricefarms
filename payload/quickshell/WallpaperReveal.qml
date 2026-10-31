import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs

// A wallpaper-only iris used to hide a coordinated theme commit.
//
// The shell writes ~/.cache/quickshell/wallpaper-reveal.json:
//   {"id": "...", "path": "/path/to/wall.jpg", "phase": "in"}
//   {"id": "...", "phase": "out"}
//
// "in" grows a circular mask from the bottom-right until it covers the screen.
// The wallpaper inside is screen-sized, so the circle reveals it in place.
// "out" collapses the same circle toward the top-left, exposing the already
// recoloured desktop underneath. The window is click-through and sits on the
// overlay layer, above the bar, dock and all normal windows.
//
// Cost model (what this file is shaped around):
//   * idle: nothing. The layer surface is unmapped, so the compositor does not
//     blend a fullscreen transparent layer over the desktop on every repaint.
//   * one decode per switch, not one per output: all screens ask the pixmap
//     cache for the same bounded size, and the decode happens off the GUI
//     thread. Before this, three synchronous native-size decodes (6666x3527 is
//     ~105 ms and ~90 MB each) ran inside beginReveal on the GUI thread.
//   * one fullscreen shader pass per animated frame, not two: the wallpaper is
//     rendered into the ShaderEffectSource once, after the decode, instead of
//     live:true re-rendering the image into an FBO on every frame.
//   * only visible frames are animated: the grow completes as soon as the
//     circle covers the screen, and the shrink starts where the circle first
//     touches a corner. Both skipped segments draw exactly the same pixels as
//     the frame before, so nothing visible changes; they were ~310 ms + ~380 ms
//     of frames that could not be seen.
PanelWindow {
    id: root

    required property var modelData

    screen: root.modelData
    color: "transparent"
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "lucid-wallpaper-reveal"
    mask: Region {
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    // An unmapped layer surface costs nothing. A mapped one is a fullscreen
    // alpha buffer the compositor blends into every desktop frame, even when
    // the iris is idle and fully transparent.
    visible: root.active

    Component.onCompleted: {
        // The shell script writes this before every palette swap; on a fresh
        // boot create it so Theme's FileView does not warn about a missing file.
        Quickshell.execDetached(["sh", "-c", "d=$HOME/.cache/quickshell; mkdir -p $d; [ -e $d/reveal-active ] || printf 0 > $d/reveal-active"]);
    }

    property string wallpaper: ""
    property string revealSource: ""
    property string lastId: ""
    property bool active: false
    readonly property real sw: screen ? screen.width : 1368
    readonly property real sh: screen ? screen.height : 912
    readonly property real coverRadius: (Math.hypot(sw / 2, sh / 2) + 2) * 1.25 * 1.25
    property bool pendingIn: false
    property bool concealRequested: false
    property bool completing: false
    readonly property string readyPath: Quickshell.env("HOME") + "/.cache/quickshell/reveal-ready"
    readonly property string coveredPath: Quickshell.env("HOME") + "/.cache/quickshell/reveal-covered"

    // The circle travels from beyond the bottom-right corner to the centre.
    readonly property real startX: root.sw * 1.35
    readonly property real startY: root.sh * 1.35
    readonly property real endX: root.sw / 2
    readonly property real endY: root.sh / 2
    readonly property real outX: -root.sw * 0.45
    readonly property real outY: -root.sh * 0.45

    // Grow progress, already in eased space (0 = off-screen, 1 = covered).
    property real cover: 0
    // Shrink time, 0..1; the InCubic easing is applied in `progress`.
    property real outT: 0
    property bool leaving: false

    // One animator instead of three: the same single progress drives centre and
    // radius, so a frame writes one property and one uniform set.
    readonly property real progress: root.leaving ? root.outT * root.outT * root.outT : root.cover
    readonly property real cx: root.leaving ? root.endX + (root.outX - root.endX) * root.progress : root.startX + (root.endX - root.startX) * root.progress
    readonly property real cy: root.leaving ? root.endY + (root.outY - root.endY) * root.progress : root.startY + (root.endY - root.startY) * root.progress
    readonly property real radius: root.coverRadius * (root.leaving ? 1 - root.progress : root.progress)

    // The point in the shrink where the circle first stops covering a corner.
    // Everything before it is invisible, so the out animation starts here. The
    // solve is monotonic: the radius falls while the centre moves away from the
    // far corner.
    readonly property real tLeave: {
        var lo = 0;
        var hi = 1;
        for (var i = 0; i < 24; i++) {
            var s = (lo + hi) / 2;
            var x = root.endX + (root.outX - root.endX) * s;
            var y = root.endY + (root.outY - root.endY) * s;
            var r = root.coverRadius * (1 - s);
            var d = Math.max(Math.hypot(x, y), Math.hypot(root.sw - x, y), Math.hypot(x, root.sh - y), Math.hypot(root.sw - x, root.sh - y));
            if (r >= d + 2)
                lo = s;
            else
                hi = s;
        }
        return Math.pow(lo, 1 / 3);
    }

    // One decode size for every output. The pixmap cache is keyed by source and
    // sourceSize, so a shared size means one decode for three windows instead
    // of three decodes, and it bounds the texture at the physical screen size
    // instead of the wallpaper's native 6666x3527.
    readonly property size decodeSize: {
        var w = 0;
        var h = 0;
        for (var i = 0; i < Quickshell.screens.length; i++) {
            var s = Quickshell.screens[i];
            w = Math.max(w, Math.round(s.width * s.devicePixelRatio));
            h = Math.max(h, Math.round(s.height * s.devicePixelRatio));
        }
        return Qt.size(w || 1920, h || 1080);
    }

    function covered() {
        var d = Math.max(Math.hypot(root.cx, root.cy), Math.hypot(root.sw - root.cx, root.cy), Math.hypot(root.cx, root.sh - root.cy), Math.hypot(root.sw - root.cx, root.sh - root.cy));
        return root.radius >= d + 2;
    }

    function beginReveal(id, path) {
        // A duplicate IPC delivery for the same selection must not reset the
        // in-animation halfway through; that makes the circle look smaller on
        // some wallpapers depending on timing.
        if (root.active && root.lastId === id)
            return;
        root.lastId = id;
        Theme.revealActive = true;
        root.wallpaper = path || "";
        root.active = true;
        root.pendingIn = true;
        root.concealRequested = false;
        root.leaving = false;
        root.cover = 0;
        root.outT = 0;
        Quickshell.execDetached(["sh", "-c", "rm -f \"$0\" \"$1\"", root.readyPath, root.coveredPath]);
        // Force the Image through Null/Loading so a Ready status from the
        // previous wallpaper cannot start the new animation early. The decode
        // is asynchronous now; startIn runs from the status handler once the
        // texture exists.
        root.revealSource = "";
        root.revealSource = "file://" + encodeURI(root.wallpaper);
        if (image.status === Image.Ready)
            Qt.callLater(root.imageReady);
    }

    function imageReady() {
        if (!root.pendingIn || image.status !== Image.Ready)
            return;
        // Render the wallpaper into its FBO once; it is static for the whole
        // reveal, so there is no reason to re-render it every frame.
        wallpaperSource.scheduleUpdate();
        Qt.callLater(root.startIn);
    }

    function startIn() {
        if (!root.pendingIn)
            return;
        root.pendingIn = false;
        root.cover = 0;
        Quickshell.execDetached(["sh", "-c", "touch \"$0\"", root.readyPath]);
        inAnim.restart();
    }

    function startOut() {
        root.leaving = true;
        root.outT = root.tLeave;
        outAnim.restart();
    }

    function endReveal(id) {
        if (id !== root.lastId || !root.active)
            return;
        // A conceal that arrives while the circle is still growing must not
        // interrupt it; that is the "small circle flies across" bug. Defer it
        // until the grow has completed, then hold the requested 50 ms.
        if (root.pendingIn || inAnim.running) {
            root.concealRequested = true;
            return;
        }
        root.startOut();
    }

    NumberAnimation {
        id: inAnim

        target: root
        property: "cover"
        from: 0
        to: 1
        duration: 700
        easing.type: Easing.OutCubic

        // The moment the last corner is covered the remaining easing only moves
        // the edge further off-screen. Jump to the end so the covered marker is
        // touched (and the palette commit can start) without drawing frames
        // that cannot change a pixel.
        onFinished: {
            Quickshell.execDetached(["sh", "-c", "touch \"$0\"", root.coveredPath]);
            if (root.concealRequested) {
                root.concealRequested = false;
                holdTimer.start();
            }
        }
    }

    onCoverChanged: {
        if (!root.leaving && !root.completing && inAnim.running && root.covered()) {
            root.completing = true;
            inAnim.complete();
            root.completing = false;
        }
    }

    Timer {
        id: holdTimer

        interval: 50
        repeat: false
        onTriggered: {
            if (root.active && !outAnim.running)
                root.startOut();
        }
    }

    NumberAnimation {
        id: outAnim

        target: root
        property: "outT"
        from: root.tLeave
        to: 1
        // The tail of the original 700 ms InCubic, so the edge moves at exactly
        // the same speed; the invisible lead-in is simply not animated.
        duration: Math.max(1, (1 - root.tLeave) * 700)
        easing.type: Easing.Linear
        onFinished: {
            Theme.revealActive = false;
            root.active = false;
            root.wallpaper = "";
        }
    }

    // A watchdog so a lost "out" event cannot leave the screen covered.
    Timer {
        interval: 6000
        repeat: false
        running: root.active && !outAnim.running
        onTriggered: {
            if (root.active && !outAnim.running)
                root.startOut();
        }
    }

    Image {
        id: image

        x: 0
        y: 0
        width: root.sw
        height: root.sh
        source: root.revealSource
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize: root.decodeSize
        visible: false
        onStatusChanged: {
            if (status === Image.Ready)
                root.imageReady();
            else if (status === Image.Error && root.pendingIn)
                root.startIn();
        }
    }

    ShaderEffectSource {
        id: wallpaperSource

        sourceItem: image
        hideSource: true
        live: false
        recursive: false
    }

    ShaderEffect {
        x: 0
        y: 0
        width: root.sw
        height: root.sh
        visible: root.active
        property variant wallpaperTex: wallpaperSource
        property vector2d itemSize: Qt.vector2d(root.sw, root.sh)
        property vector2d center: Qt.vector2d(root.cx, root.cy)
        property real radius: root.radius
        fragmentShader: Qt.resolvedUrl("wallpaper_circle.frag.qsb")
    }

}

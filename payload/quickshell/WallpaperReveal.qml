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
    property real cx: sw
    property real cy: sh
    property real radius: 0
    property bool pendingIn: false
    property bool concealRequested: false
    readonly property string readyPath: Quickshell.env("HOME") + "/.cache/quickshell/reveal-ready"
    readonly property string coveredPath: Quickshell.env("HOME") + "/.cache/quickshell/reveal-covered"
    readonly property real coverRadius: (Math.hypot(sw / 2, sh / 2) + 2) * 1.25 * 1.25

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
        root.radius = 0;
        root.cx = root.sw * 1.35;
        root.cy = root.sh * 1.35;
        Quickshell.execDetached(["sh", "-c", "rm -f \"$0\" \"$1\"", root.readyPath, root.coveredPath]);
        // Force the Image through Null/Loading so a Ready status from the
        // previous wallpaper cannot start the new animation early. Then wait
        // for the new texture before growing.
        root.revealSource = "";
        root.revealSource = "file://" + encodeURI(root.wallpaper);
        if (image.status === Image.Ready)
            Qt.callLater(root.startIn);
    }

    function startIn() {
        if (!root.pendingIn)
            return;
        root.pendingIn = false;
        root.cx = root.sw * 1.35;
        root.cy = root.sh * 1.35;
        root.radius = 0;
        Quickshell.execDetached(["sh", "-c", "touch \"$0\"", root.readyPath]);
        inAnim.restart();
    }

    function endReveal(id) {
        if (id !== root.lastId || !root.active)
            return;
        // A conceal that arrives while the circle is still growing must not
        // interrupt it; that is the "small circle flies across" bug. Defer it
        // until the grow has completed, then hold the requested 100 ms.
        if (root.pendingIn || inAnim.running) {
            root.concealRequested = true;
            return;
        }
        outAnim.restart();
    }

    ParallelAnimation {
        id: inAnim

        onFinished: {
            Quickshell.execDetached(["sh", "-c", "touch \"$0\"", root.coveredPath]);
            if (root.concealRequested) {
                root.concealRequested = false;
                holdTimer.start();
            }
        }

        NumberAnimation {
            target: root
            property: "cx"
            to: root.sw / 2
            duration: 700
            easing.type: Easing.OutCubic
        }

        NumberAnimation {
            target: root
            property: "cy"
            to: root.sh / 2
            duration: 700
            easing.type: Easing.OutCubic
        }

        NumberAnimation {
            target: root
            property: "radius"
            to: root.coverRadius
            duration: 700
            easing.type: Easing.OutCubic
        }

    }

    Timer {
        id: holdTimer

        interval: 100
        repeat: false
        onTriggered: {
            if (root.active && !outAnim.running)
                outAnim.restart();
        }
    }

    ParallelAnimation {
        id: outAnim

        NumberAnimation {
            target: root
            property: "cx"
            to: -root.sw * 0.45
            duration: 700
            easing.type: Easing.InCubic
        }

        NumberAnimation {
            target: root
            property: "cy"
            to: -root.sh * 0.45
            duration: 700
            easing.type: Easing.InCubic
        }

        NumberAnimation {
            target: root
            property: "radius"
            to: 0
            duration: 700
            easing.type: Easing.InCubic
        }

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
                outAnim.restart();
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
        asynchronous: false
        cache: false
        visible: false
    }

    ShaderEffectSource {
        id: wallpaperSource

        sourceItem: image
        hideSource: true
        live: true
        recursive: true
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

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

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
        console.log("REVEAL init", width, height, screen ? screen.name : "?");
        // Avoid a missing-file warning before the first theme change.
        Quickshell.execDetached(["sh", "-c", "d=$HOME/.cache/quickshell; mkdir -p $d; [ -e $d/wallpaper-reveal.json ] || printf '{\"id\":\"\",\"phase\":\"\"}' > $d/wallpaper-reveal.json; [ -e $d/reveal-active ] || printf 0 > $d/reveal-active"]);
    }

    property string wallpaper: ""
    property string lastId: ""
    property bool active: false
    property var pendingEvent: null
    readonly property real sw: screen ? screen.width : 1368
    readonly property real sh: screen ? screen.height : 912
    property real cx: sw
    property real cy: sh
    property real radius: 0
    readonly property real coverRadius: Math.hypot(sw / 2, sh / 2) + 8

    FileView {
        id: trigger

        path: Quickshell.env("HOME") + "/.cache/quickshell/wallpaper-reveal.json"
        watchChanges: true
        blockLoading: true
        onFileChanged: {
            console.log("REVEAL file changed");
            reload();
        }
        onLoaded: {
            console.log("REVEAL file loaded");
            root.handleTrigger(text());
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: trigger.reload()
    }

    function handleTrigger(text) {
        let event;
        try {
            event = JSON.parse(text);
        } catch (e) {
            return;
        }
        console.log("REVEAL trigger", text, "size", width, height, "screen", screen ? screen.width : -1, screen ? screen.height : -1, "implicit", implicitWidth, implicitHeight);
        if (!event || !event.id || event.id === root.lastId && event.phase !== "out")
            return;
        // A panel created during shell startup can still be at its default
        // size for a frame or two. Animating then would put a 500 px circle on
        // a 1368 px screen; wait until the surface matches the screen.
        if (!screen) {
            root.pendingEvent = event;
            sizeWait.restart();
            return;
        }
        root.applyEvent(event);
    }

    function applyEvent(event) {
        if (event.phase === "in") {
            root.lastId = event.id;
            root.wallpaper = event.path || "";
            root.active = true;
            root.radius = 0;
            root.cx = root.sw;
            root.cy = root.sh;
            inAnim.restart();
        } else if (event.phase === "out" && event.id === root.lastId && root.active) {
            outAnim.restart();
        }
    }

    Timer {
        id: sizeWait

        interval: 50
        repeat: true
        onTriggered: {
            if (!root.pendingEvent)
                return;
            if (!screen)
                return;
            stop();
            const event = root.pendingEvent;
            root.pendingEvent = null;
            root.applyEvent(event);
        }
    }

    ParallelAnimation {
        id: inAnim

        onFinished: console.log("REVEAL covered", root.radius)

        NumberAnimation {
            target: root
            property: "cx"
            to: root.sw / 2
            duration: 350
            easing.type: Easing.OutCubic
        }

        NumberAnimation {
            target: root
            property: "cy"
            to: root.sh / 2
            duration: 350
            easing.type: Easing.OutCubic
        }

        NumberAnimation {
            target: root
            property: "radius"
            to: root.coverRadius
            duration: 350
            easing.type: Easing.OutCubic
        }

    }

    ParallelAnimation {
        id: outAnim

        NumberAnimation {
            target: root
            property: "cx"
            to: 0
            duration: 350
            easing.type: Easing.InCubic
        }

        NumberAnimation {
            target: root
            property: "cy"
            to: 0
            duration: 350
            easing.type: Easing.InCubic
        }

        NumberAnimation {
            target: root
            property: "radius"
            to: 0
            duration: 350
            easing.type: Easing.InCubic
        }

        onFinished: {
            console.log("REVEAL out done");
            root.active = false;
            root.wallpaper = "";
        }
    }

    // A watchdog so a lost "out" event cannot leave the screen covered.
    Timer {
        interval: 2500
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
        source: root.wallpaper !== "" ? "file://" + encodeURI(root.wallpaper) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: false
        cache: false
        visible: false
        onStatusChanged: console.log("REVEAL image", status, source)
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

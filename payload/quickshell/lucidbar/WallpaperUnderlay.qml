import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs

// Screen-fixed soft-light wallpaper, drawn only behind the visible normal
// windows. Transparent app backgrounds reveal it; the real wallpaper stays
// sharp in the gaps. Because the texture never moves with a window, alignment
// survives drags, resizes and workspace switches.
PanelWindow {
    id: root

    required property var modelData

    screen: root.modelData
    color: "transparent"
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "lucid-underlay"
    // input only: the visual crop is the Repeater below
    mask: Region {
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    readonly property var monitor: Hyprland.monitorFor(root.screen)
    readonly property string specialName: {
        const o = root.monitor ? root.monitor.lastIpcObject : null;
        return o && o.specialWorkspace && o.specialWorkspace.name ? o.specialWorkspace.name : "";
    }
    // visible toplevel rects in screen-local logical px, fullscreen excluded
    readonly property var rects: {
        const out = [];
        const spaces = [];
        if (root.monitor && root.monitor.activeWorkspace)
            spaces.push(root.monitor.activeWorkspace);
        if (root.specialName !== "") {
            for (const w of Hyprland.workspaces.values) {
                if (w.name === root.specialName)
                    spaces.push(w);
            }
        }
        for (const ws of spaces) {
            if (!ws || !ws.toplevels)
                continue;
            for (const t of ws.toplevels.values) {
                const o = t.lastIpcObject;
                if (!o || !o.at || !o.size || o.hidden || o.fullscreen)
                    continue;
                // hyprland IPC geometry is physical; the underlay is logical
                const sc = root.screen.devicePixelRatio || 1;
                const x = o.at[0] / sc - root.screen.x;
                const y = o.at[1] / sc - root.screen.y;
                const w = o.size[0] / sc;
                const h = o.size[1] / sc;
                if (x + w < 1 || y + h < 1 || x > root.screen.width - 1 || y > root.screen.height - 1)
                    continue;
                out.push({ "x": x, "y": y, "w": w, "h": h });
            }
        }
        return out;
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

    Repeater {
        model: root.rects

        Item {
            required property var modelData

            x: modelData.x
            y: modelData.y
            width: modelData.w
            height: modelData.h
            clip: true

            Image {
                x: -modelData.x
                y: -modelData.y
                width: root.width
                height: root.height
                source: root.imageSource
                fillMode: Image.Stretch
                asynchronous: true
                cache: true
                smooth: true
            }
        }
    }

    // lastIpcObject only moves on an explicit refresh
    Connections {
        target: Hyprland

        function onRawEvent(event) {
            switch (event.name) {
            case "openwindow":
            case "closewindow":
            case "movewindow":
            case "movewindowv2":
            case "workspace":
            case "workspacev2":
            case "activespecial":
            case "activespecialv2":
            case "fullscreen":
            case "changefloatingmode":
                refreshTimer.restart();
                break;
            }
        }
    }

    Timer {
        id: refreshTimer

        interval: 16
        onTriggered: Hyprland.refreshToplevels()
    }
}

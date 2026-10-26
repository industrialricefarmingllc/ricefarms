import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs

// Screen-fixed soft-light wallpaper wash above every window. One image per
// monitor, no geometry masks: it cannot lag behind drags or workspace
// animations. Hidden while a fullscreen window is active on this output.
PanelWindow {
    id: root

    required property var modelData

    screen: root.modelData
    color: "transparent"
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
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

    readonly property bool fullScreenOpen: {
        const mon = Hyprland.monitorFor(root.screen);
        if (!mon)
            return false;
        const list = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < list.length; i++) {
            const t = list[i];
            if (!t || !t.wayland || t.wayland.fullscreen !== true)
                continue;
            if (t.monitor && t.monitor.id === mon.id)
                return true;
        }
        return false;
    }

    visible: !root.fullScreenOpen

    FileView {
        id: texturePath

        path: Quickshell.env("HOME") + "/.cache/quickshell/wallpaper-softlight.path"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: image.source = text().trim() !== "" ? "file://" + text().trim() : ""
    }

    Image {
        id: image

        anchors.fill: parent
        fillMode: Image.Stretch
        asynchronous: false
        cache: true
        smooth: false
        mipmap: false
    }
}

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs

// A screen-fixed soft-light wallpaper wash. It sits below every window at
// WlrLayer.Bottom, so a transparent window reveals exactly the part of the
// wallpaper behind it — through drags, resizes and workspace switches. The
// image is opaque and soft-light baked; 25% opacity lets the real wallpaper
// show through instead of replacing it.
PanelWindow {
    id: root

    required property var modelData

    screen: root.modelData
    color: "transparent"
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "lucid-underlay"
    mask: Region {
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

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
        asynchronous: true
        cache: true
        smooth: true
        opacity: 0.25
    }
}

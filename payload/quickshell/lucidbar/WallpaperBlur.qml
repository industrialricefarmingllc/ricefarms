import QtQuick
import Quickshell
import Quickshell.Io
import qs

// The baked soft-light wallpaper, aligned to the window's position on its
// screen and clipped to the parent. wallpaper-softlight.py does the heavy blur
// and the 25% soft-light blend once per wallpaper/surface change, so drawing it
// is a single static texture sample.
Item {
    id: root

    property var hostWindow: null
    property real offsetX: 0
    property real offsetY: 0

    readonly property var screen: root.hostWindow ? root.hostWindow.screen : null
    readonly property real screenW: root.screen ? root.screen.width : 1368
    readonly property real screenH: root.screen ? root.screen.height : 912
    property string imagePath: ""

    clip: true

    FileView {
        id: texture

        path: Quickshell.env("HOME") + "/.cache/quickshell/wallpaper-softlight.path"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.imagePath = text().trim()
    }

    Image {
        x: -root.offsetX
        y: -root.offsetY
        width: root.screenW
        height: root.screenH
        source: root.imagePath !== "" ? "file://" + root.imagePath : ""
        fillMode: Image.Stretch
        opacity: 0.25
        asynchronous: true
        cache: true
        smooth: true
    }
}

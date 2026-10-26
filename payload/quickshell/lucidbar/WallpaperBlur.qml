import QtQuick
import Quickshell
import qs

// A 10%-alpha, pre-blurred wallpaper crop, aligned to the window's position on
// its screen and clipped to the parent. The blur is baked once per wallpaper
// change (support/lucid/wallpaper-blur.py); drawing it is a single static
// texture sample, which keeps animations and resizes cheap.
Item {
    id: root

    property Item hostWindow: null
    property real offsetX: 0
    property real offsetY: 0
    property string source: "file://" + Quickshell.env("HOME") + "/.cache/quickshell/wallpaper-blur.png"

    readonly property var screen: root.hostWindow ? root.hostWindow.screen : null
    readonly property real screenW: root.screen ? root.screen.width : 1368
    readonly property real screenH: root.screen ? root.screen.height : 912

    clip: true

    Image {
        x: -root.offsetX
        y: -root.offsetY
        width: root.screenW
        height: root.screenH
        source: root.source
        fillMode: Image.Stretch
        asynchronous: true
        cache: true
        smooth: true
    }
}

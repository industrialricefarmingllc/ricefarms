import QtQuick
import Qt5Compat.GraphicalEffects
import qs

// an image cut to one of the m3 expressive shapes. children draw in its place
// until the image is ready, on the shape's own fill
Item {
    id: si

    property alias source: img.source
    property string shape: "cookie12"
    property int fillMode: Image.PreserveAspectCrop
    // a second shape to ease toward, and how far along the way
    property string to: ""
    property real morph: 0
    property real spin: 0
    property color fallbackColor: Theme.primaryContainer
    // Scale the picture inside the shape without changing the shape itself.
    // Used for the mesh preview's hover settle.
    property real contentScale: 1.0
    property bool fallbackVisible: false
    property int decode: 256
    readonly property bool ready: img.status === Image.Ready
    default property alias fallback: fb.data

    MaterialShape {
        anchors.fill: parent
        shape: si.shape
        to: si.to
        morph: si.morph
        spin: si.spin
        color: si.fallbackColor
        visible: si.fallbackVisible || !si.ready
    }

    Item {
        id: fb

        anchors.fill: parent
        visible: !si.ready
    }

    Image {
        id: img

        anchors.fill: parent
        scale: si.contentScale
        transformOrigin: Item.Center
        fillMode: si.fillMode
        sourceSize.width: si.decode
        sourceSize.height: si.decode
        asynchronous: true
        cache: false
        visible: false
    }

    MaterialShape {
        id: mask

        anchors.fill: parent
        shape: si.shape
        to: si.to
        morph: si.morph
        spin: si.spin
        color: "black"
        visible: false
    }

    Behavior on contentScale {
        NumberAnimation {
            duration: 320
            easing.type: Easing.OutCubic
        }
    }

    OpacityMask {
        anchors.fill: parent
        visible: si.ready
        source: img
        maskSource: mask
    }

}

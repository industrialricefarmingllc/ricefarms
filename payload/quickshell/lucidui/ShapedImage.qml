import QtQuick
import Qt5Compat.GraphicalEffects
import qs

// an image cut to one of the m3 expressive shapes. children draw in its place
// until the image is ready, on the shape's own fill
Item {
    id: si

    property alias source: img.source
    property string shape: "cookie12"
    // a second shape to ease toward, and how far along the way
    property string to: ""
    property real morph: 0
    property real spin: 0
    property color fallbackColor: Theme.primaryContainer
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
        visible: !si.ready
    }

    Item {
        id: fb

        anchors.fill: parent
        visible: !si.ready
    }

    Image {
        id: img

        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
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

    OpacityMask {
        anchors.fill: parent
        visible: si.ready
        source: img
        maskSource: mask
    }

}

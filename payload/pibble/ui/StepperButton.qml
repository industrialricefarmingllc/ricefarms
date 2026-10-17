import QtQuick
import "root:/services"
import "../squircle"

// One arrow of a ‹ value › stepper. Uses the icon font rather than a text
// glyph - ‹ › sit at different baselines/widths across UI fonts, which
// misaligned the stepper depending on the user's chosen font.
SquircleRect {
    id: root

    property string icon
    signal pressed
    width: 28
    height: 28
    radius: Theme.radius(14)
    fillColor: Qt.alpha(Theme.accent, hover.containsMouse ? 0.22 : 0.11)
    borderColor: Qt.alpha(Theme.accent, 0.33)
    borderWidth: 1
    smoothing: Theme.squircleF
    anchors.verticalCenter: parent.verticalCenter
    Text {
        anchors.centerIn: parent
        text: root.icon
        color: Theme.accent
        font { family: Icons.family; pixelSize: Theme.fontSize(15) }
    }
    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.pressed()
    }
}

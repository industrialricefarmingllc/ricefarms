import QtQuick
import qs
import "../squircle"

Item {
    id: flare

    property bool mirrored: false
    property int size: 14
    property color fillColor: Theme.bg
    property bool hovered: false

    property real tint: flare.hovered ? 0.08 : 0

    Behavior on tint {
        NumberAnimation {
            duration: Theme.barMs(150)
            easing.type: Easing.OutCubic
        }

    }

    implicitWidth: flare.size
    implicitHeight: flare.size
    visible: flare.size > 0

    // Concave notch shoulder (bar tabs grow out of the top screen edge, so
    // the disc sits on the outer-bottom corner). At squircleF 0 this is
    // exactly the old quarter-arc.
    SquircleFlare {
        anchors.fill: parent
        size: flare.size
        mirrored: flare.mirrored
        fillColor: Qt.tint(flare.fillColor, Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, flare.tint))
        smoothing: Prefs.squircleF
    }

}

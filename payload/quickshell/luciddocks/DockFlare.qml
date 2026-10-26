import QtQuick
import qs
import "../squircle"

Item {
    id: flare

    property bool mirrored: false
    property int size: Theme.dp(14)
    property color fillColor: Theme.bg

    implicitWidth: flare.size
    implicitHeight: flare.size
    visible: flare.size > 0

    // Concave notch shoulder for the bottom edge: the dock grows out of
    // the bottom of the screen, so the disc sits on the outer-TOP corner
    // (the vertical mirror of the bar flare). At squircleF 0 this is
    // exactly the old quarter-arc.
    SquircleFlare {
        anchors.fill: parent
        size: flare.size
        mirrored: flare.mirrored
        discCenter: Qt.vector2d(0, 0)
        fillColor: flare.fillColor
        smoothing: Prefs.squircleF
    }

}

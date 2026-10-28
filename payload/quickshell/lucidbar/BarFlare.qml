import QtQuick
import qs
import "../squircle"

Item {
    id: flare

    property bool mirrored: false
    // upside down, for an edge below it
    property bool flipped: false
    property int size: Theme.dp(14)
    property color fillColor: Theme.bg
    // the shoulder's arc wears the same hairline as the tab it grows out of
    property color borderColor: "transparent"
    property real borderWidth: 0
    // Convex corners read as squircles at any smoothing, but the same
    // superellipse turned inside out (a notch shoulder) collapses toward a
    // straight line: at f = 0.8 the arc is within a pixel of the tab side for
    // most of its height, so the shoulder looks like a seam instead of a
    // fillet. 0 keeps it the classic quarter-arc, where the curve is spread
    // over the whole size and always reads as a fluid transition.
    property real smoothing: Prefs.squircleF
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
        flipped: flare.flipped
        fillColor: Qt.tint(flare.fillColor, Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, flare.tint))
        borderColor: flare.borderColor
        borderWidth: flare.borderWidth
        smoothing: flare.smoothing
    }

}

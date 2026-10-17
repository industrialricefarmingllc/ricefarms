import QtQuick
import "squircle.js" as Sq

// One inverted (concave) squircle fillet — the notch shoulder where a
// bar/dock tab meets the screen edge. Replaces the Shape+PathArc flare.
//
//   SquircleFlare {
//       size: Prefs.barNotchFlare
//       mirrored: true
//       discCenter: Qt.vector2d(0, 1)   // bar/top-edge default
//       fillColor: Theme.bg
//       smoothing: Prefs.squircleF
//   }
//
// Shape: unit box INTERSECT outside-of-superellipse around discCenter
// (outer corner of the flare box). Bar tabs use c = (0,1)/(1,1); the dock
// (bottom edge) uses c = (0,0)/(1,0). At smoothing 0 the edge is exactly
// the old circular arc.
ShaderEffect {
    id: root

    property bool mirrored: false
    property int size: 14
    property color fillColor: "white"
    property real smoothing: 0.5
    // Disc center in unit box coords (see squircle.js header).
    property vector2d discCenter: Qt.vector2d(0, 1)

    property vector2d itemSize: Qt.vector2d(width, height)
    property real exponent: Sq.exponent(root.smoothing)
    property real mirrorFlag: root.mirrored ? 1.0 : 0.0

    implicitWidth: root.size
    implicitHeight: root.size
    visible: root.size > 0 && width > 0.5 && height > 0.5

    fragmentShader: Qt.resolvedUrl("squircle_flare.frag.qsb")
}

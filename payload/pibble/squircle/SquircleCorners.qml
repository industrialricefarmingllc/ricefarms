import QtQuick
import "squircle.js" as Sq

// Fullscreen inverted-corner overlay: black squircles hugging each screen
// corner, like a physical rounded bezel. Replaces the four rotated Shape
// arcs in lucidcorners/ScreenCorners.qml with one SDF draw.
//
//   SquircleCorners {
//       anchors.fill: parent
//       cornerSize: 27
//       color: "black"
//       smoothing: Prefs.squircleF
//   }
//
// Each corner square is filled OUTSIDE the superellipse around its inner
// corner (disc center (1,1) in corner-unit space). At smoothing 0 the edge
// is exactly the old circular arc of radius cornerSize.
ShaderEffect {
    id: root

    property real cornerSize: 27
    property color color: "black"
    property real smoothing: 0.5

    property vector2d itemSize: Qt.vector2d(width, height)
    property real exponent: Sq.exponent(root.smoothing)

    fragmentShader: Qt.resolvedUrl("squircle_corners.frag.qsb")
}

import QtQuick
import "../squircle/squircle.js" as Sq

// Transient liquid body for BarPill's expansion.
//
// Draws the union of the compact pill and a growable panel box. When the two
// are far apart the smooth-min neck is visible; once they overlap the union
// is simply the panel, matching the normal SquircleRect body it replaces.
ShaderEffect {
    id: root

    property color fillColor: "white"
    property vector4d compactRect: Qt.vector4d(0, 0, 0, 0)
    property vector4d compactRadii: Qt.vector4d(0, 0, 0, 0)
    property vector4d panelRect: Qt.vector4d(0, 0, 0, 0)
    property vector4d panelRadii: Qt.vector4d(0, 0, 0, 0)
    property real smoothing: 0.5
    property real goo: 18

    property vector2d itemSize: Qt.vector2d(width, height)
    property real exponent: Sq.exponent(root.smoothing)

    visible: width > 0.5 && height > 0.5
    fragmentShader: Qt.resolvedUrl("liquid_shape.frag.qsb")
}

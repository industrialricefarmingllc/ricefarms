import QtQuick
import QtQuick.Shapes
import "squircle.js" as Sq

// Opaque-white squircle alpha mask for OpacityMask / MultiEffect.maskSource.
//
//   Image { id: thumb; ...; visible: false }
//   SquircleMask { id: m; anchors.fill: parent; radius: 14; smoothing: f }
//   OpacityMask { anchors.fill: parent; source: thumb; maskSource: m }
//
// Same curve as SquircleRect (superellipse corners, same exponent
// mapping), so masked content agrees exactly with sibling squircle
// fills. Radius follows the masked item: bind radius/smoothing to the
// same values as the card.
//
// Deliberately Shape geometry, not a shader: a mask must behave exactly
// like the plain white Rectangle it replaces (render-on-demand as an
// effect maskSource, survive show/hide and size transitions). A
// ShaderEffect mask froze transparent after expand/collapse transitions,
// blanking the content it was meant to cut.
Item {
    id: root

    property real radius: 0
    property real topLeftRadius: -1
    property real topRightRadius: -1
    property real bottomLeftRadius: -1
    property real bottomRightRadius: -1
    property real smoothing: 0.5

    readonly property real _tl: root.topLeftRadius >= 0 ? root.topLeftRadius : root.radius
    readonly property real _tr: root.topRightRadius >= 0 ? root.topRightRadius : root.radius
    readonly property real _br: root.bottomLeftRadius >= 0 ? root.bottomLeftRadius : root.radius
    readonly property real _bl: root.bottomRightRadius >= 0 ? root.bottomRightRadius : root.radius

    Shape {
        anchors.fill: parent
        antialiasing: true

        ShapePath {
            fillColor: "white"
            strokeWidth: 0

            PathSvg {
                path: Sq.svgSquirclePath(root.width, root.height, [root._tl, root._tr, root._br, root._bl], Sq.exponent(root.smoothing))
            }
        }
    }
}

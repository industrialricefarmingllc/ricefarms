import QtQuick
import QtQuick.Shapes
import "Shapes.js" as Shapes

// One filled shape from the Material 3 Expressive library. `morph` eases it
// toward `to`, which gives the small mark beside the composer a reason to move
// when the widget opens or starts thinking.
Shape {
    id: root

    property string shape: "circle"
    property string to: ""
    property real morph: 0
    property color color: Theme.primary
    property real spin: 0

    width: Theme.dp(44)
    height: Theme.dp(44)
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
        fillColor: root.color
        strokeColor: "transparent"
        strokeWidth: 0

        PathSvg {
            path: root.to !== "" && root.morph > 0 ? Shapes.svg(Shapes.mix(Shapes.radii(root.shape), Shapes.radii(root.to), root.morph), root.width, root.spin * Math.PI / 180) : Shapes.path(root.shape, root.width, root.spin * Math.PI / 180)
        }

    }

}

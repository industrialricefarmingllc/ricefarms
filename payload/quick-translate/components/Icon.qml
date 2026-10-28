import QtQuick
import QtQuick.Shapes
import "Icons.js" as Icons

// A Material Symbols glyph drawn from Google's own path data. The widget uses
// the filled cut, which stays legible at the small sizes in the composer.
Item {
    id: icon

    property string name: ""
    property real size: 20
    property color color: "#ffffff"
    property bool filled: true

    implicitWidth: icon.size
    implicitHeight: icon.size
    width: icon.size
    height: icon.size

    Shape {
        width: 24
        height: 24
        preferredRendererType: Shape.GeometryRenderer

        transform: Scale {
            xScale: icon.width / 24
            yScale: icon.height / 24
        }

        ShapePath {
            strokeWidth: 0
            strokeColor: "transparent"
            fillColor: icon.color

            PathSvg {
                path: Icons.path(icon.name, icon.filled)
            }

        }

    }

}

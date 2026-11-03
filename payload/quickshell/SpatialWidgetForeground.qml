import QtQuick
import Quickshell
import Quickshell.Io
import qs

// The subject cutout, painted over the widget board only inside widget rects.
// Hovering a card hides the cutout over that card, so the widget comes forward
// while its neighbours still sit behind the foreground object. The surface is
// click-through; the widget below keeps every press, wheel and hover event.
Item {
    id: root

    required property var screen
    readonly property var rects: {
        const all = SpatialWidgets.rects || ({});
        return all[root.screen ? root.screen.name : ""] || [];
    }
    readonly property size textureSize: Qt.size(
        Math.max(1, Math.round(width * (root.screen ? root.screen.devicePixelRatio : 1))),
        Math.max(1, Math.round(height * (root.screen ? root.screen.devicePixelRatio : 1))))

    SpatialSurface {
        id: subject

        anchors.fill: parent
        screen: root.screen
        foregroundOnly: true
        renderingEnabled: root.rects.length > 0 && !SpatialWall.meshBusy
    }

    ShaderEffectSource {
        id: subjectTexture

        sourceItem: subject
        hideSource: true
        live: true
        smooth: true
        textureSize: root.textureSize
        visible: false
    }

    IpcHandler {
        target: "spatial-widgets-" + (root.screen ? root.screen.name : "unknown")

        function snapshot(): string {
            return JSON.stringify({
                rects: root.rects,
                subjectReady: subject.sourceReady,
                subjectVisible: subject.visible,
                hovered: SpatialWidgets.hovered,
                layered: SpatialWall.layeredReady
            });
        }
    }

    Repeater {
        model: root.rects

        delegate: ShaderEffect {
            required property var modelData

            x: modelData.x
            y: modelData.y
            width: modelData.w
            height: modelData.h
            // Hover lives in a separate map, so this delegate is never
            // destroyed/recreated by a hover change and the Behavior can run.
            readonly property bool isHovered: {
                const map = SpatialWidgets.hovered || ({});
                return map[modelData.uid] === true;
            }
            // Fade the cutout away instead of cutting it: the widget is under
            // this surface, so the transition reads as the card coming forward
            // through the foreground object when the pointer reaches it.
            opacity: isHovered ? 0 : 1
            visible: opacity > 0.01
            Behavior on opacity {
                NumberAnimation {
                    duration: Theme.durShort
                    easing.type: Easing.OutCubic
                }
            }
            property variant source: subjectTexture
            property vector2d viewport: Qt.vector2d(root.width, root.height)
            property vector4d rect: Qt.vector4d(x, y, width, height)
            fragmentShader: Qt.resolvedUrl("luciddocks/shaders/spatial_widget_clip.frag.qsb")
        }
    }
}

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
    readonly property string screenName: root.screen ? root.screen.name : ""
    readonly property var rects: {
        const all = SpatialWidgets.rects || ({});
        return all[root.screenName] || [];
    }
    // The Repeater is keyed on the stable uid list (it only changes when a card
    // is added or removed). Geometry is looked up per uid inside the delegate,
    // so a moving card updates x/y/w/h in place: rebuilding the delegates on
    // every 30 Hz rect publish caused a visible hitch frame.
    readonly property var cards: {
        const all = SpatialWidgets.uids || ({});
        return all[root.screenName] || [];
    }
    readonly property var rectMap: {
        const all = SpatialWidgets.byUid || ({});
        return all[root.screenName] || ({});
    }
    // The liquid-glass pill casts its soft drop shadow beyond the card rect,
    // and the card edge itself can leave a hairline. The cutout quad is grown
    // by this margin so the subject also paints over that halo instead of
    // letting a dark/glass rim float in front of the depth mesh.
    readonly property real pad: 56
    readonly property size textureSize: Qt.size(
        Math.max(1, Math.round(width * (root.screen ? root.screen.devicePixelRatio : 1))),
        Math.max(1, Math.round(height * (root.screen ? root.screen.devicePixelRatio : 1))))

    SpatialSurface {
        id: subject

        anchors.fill: parent
        screen: root.screen
        foregroundOnly: true
        renderingEnabled: root.cards.length > 0 && !SpatialWall.meshBusy
    }

    ShaderEffectSource {
        id: subjectTexture

        sourceItem: subject
        hideSource: true
        // A frozen subject is a static texture inside SpatialSurface; keeping
        // this live would copy the same pixels every frame for no reason.
        live: !subject.frozen
        smooth: true
        textureSize: root.textureSize
        visible: false
    }

    Connections {
        target: subject

        function onFrozenChanged() {
            if (subject.frozen)
                subjectTexture.scheduleUpdate();
        }
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
        model: root.cards

        delegate: ShaderEffect {
            required property string modelData

            readonly property var r: root.rectMap[modelData]
            x: r ? r.x - root.pad : -root.pad
            y: r ? r.y - root.pad : -root.pad
            width: r ? r.w + 2 * root.pad : 1
            height: r ? r.h + 2 * root.pad : 1
            // Hover lives in a separate map, so this delegate is never
            // destroyed/recreated by a hover change and the Behavior can run.
            readonly property bool isHovered: {
                const map = SpatialWidgets.hovered || ({});
                return map[modelData] === true;
            }
            // Fade the cutout away instead of cutting it: the widget is under
            // this surface, so the transition reads as the card coming forward
            // through the foreground object when the pointer reaches it.
            opacity: isHovered ? 0 : 1
            visible: r !== undefined && opacity > 0.01
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

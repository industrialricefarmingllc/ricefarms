import QtQuick
import Quickshell
import Quickshell.Wayland
import qs

// Above the widget board, below normal windows. The cutout is only painted
// inside widget rectangles, so a widget that overlaps the fake 3D subject is
// partially occluded without losing its input.
Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
        required property var modelData

        readonly property var cards: {
            const all = SpatialWidgets.rects || ({});
            return all[modelData ? modelData.name : ""] || [];
        }

        screen: modelData
        // Stills and Workshop scenes have a stable subject cutout. A plain
        // video changes its subject every frame, so its widgets stay above the
        // wallpaper instead of showing a stale silhouette.
        visible: SpatialWall.enabled && SpatialWall.layeredVisual
            && SpatialWall.sourceKind !== "video" && cards.length > 0
            && (SpatialWall.renderOnSecondary || modelData === Monitors.mainScreen)
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.namespace: "lucid-spatial-foreground"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        mask: Region {}

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        SpatialWidgetForeground {
            anchors.fill: parent
            screen: modelData
            opacity: SpatialWall.visualVisible ? 1 : 0

            Behavior on opacity {
                NumberAnimation {
                    duration: 450
                    easing.type: Easing.OutCubic
                }
            }

        }
    }
}

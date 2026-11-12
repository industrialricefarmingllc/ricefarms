import QtQuick
import Quickshell
import Quickshell.Wayland
import qs

// One click-through background surface per output. Widgets are on the Bottom
// layer, so they are naturally above this and keep all input; their glass can
// blur the parallax behind them like any other wallpaper.
Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
        required property var modelData

        screen: modelData
        // Keep the surface mapped while the effect is on so the layer can
        // cross-fade; the wallpaper underneath is already the new one.
        // Only the main output draws the 3D layer: a 4K side output was
        // paying for a fullscreen parallax repaint nobody was looking at.
        readonly property bool drawVisual: SpatialWall.renderOnSecondary
            || modelData === Monitors.mainScreen
        visible: SpatialWall.enabled && drawVisual
        color: "transparent"
        // skwd renders its own wallpaper on the Bottom layer; sit there too,
        // with a lower order, so the depth surface is in front of skwd but
        // still behind the widget board and its input surfaces.
        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.namespace: "lucid-spatial"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        mask: Region {}

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        SpatialSurface {
            anchors.fill: parent
            screen: modelData
            // A local mesh job owns the GPU; the flat wallpaper is enough
            // until it finishes, and this keeps the shell's FBOs allocatable.
            // Side outputs do not render the visual at all.
            renderingEnabled: !SpatialWall.meshBusy
                && (SpatialWall.renderOnSecondary || modelData === Monitors.mainScreen)
        }
    }
}

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs
import "../squircle"

Item {
    id: root
    property var hostWindow: null
    property var dockMod: null
    property real restX: 0
    property real restY: 0
    property bool expanded: false
    property real reveal: expanded ? 1 : 0
    property int slotCount: 6
    property bool shown: Prefs.showWorkspaces && Prefs.barHas("workspaces")
    property bool popupMode: false
    // Fully rounded like the other widgets (BarPill closed state)
    property real cornerRadius: Prefs.barNotch ? Prefs.barNotchRadius : Prefs.barPillRadius
    property real topRadius: Prefs.barNotch ? 0 : Prefs.barPillRadius
    property real pillTopRadius: Prefs.barNotch ? 0 : Prefs.barPillRadius
    property int barRadius: Prefs.barNotch ? Prefs.barNotchRadius : Prefs.barPillRadius
    property int barTopRadius: Prefs.barNotch ? 0 : Prefs.barPillRadius
    property bool showTransition: false
    // External glass (liquid-glass-hypr plugin): see BarPill.externalGlass.
    property bool externalGlass: false
    // Notch mode, liquid glass off: the side group's single background is
    // drawn by shell.qml, so this module contributes content only.
    property bool groupBackground: false
    // Notch solo (set by shell.qml): collapse to zero width so the group's
    // open member can stretch across the full previous group span - same
    // convention as BarPill.soloCollapse (width only, height stays so the
    // morph is a pure slide). Also provides compactWidth so spanFor counts
    // the 200px footprint instead of 0 (which made solo panels shrink).
    property bool soloCollapse: false
    property int compactWidth: 200
    property int compactHeight: Theme.dp(Prefs.barHeight)
    // Bar/overview plumbing: the upstream bar asks every module for these.
    readonly property bool anyOpen: expanded
    readonly property bool surfaceOpen: expanded
    readonly property bool notchedPopup: false
    readonly property bool popupOpen: false
    readonly property var popupItem: null
    readonly property bool compactHovered: false
    readonly property bool surfaceHovered: false
    readonly property bool joined: false
    readonly property bool joinLeft: false
    readonly property bool joinRight: false
    // Notch shoulders: see BarPill.notchGapLeft. Members of a notch group use
    // the group background's border instead, and in every other bar style
    // there are no flares, so these stay 0.
    readonly property real notchGapLeft: (!root.groupBackground && Prefs.barNotch && root.hostWindow && root.hostWindow.notchFlare) ? root.hostWindow.notchFlare(root, true) : 0
    readonly property real notchGapRight: (!root.groupBackground && Prefs.barNotch && root.hostWindow && root.hostWindow.notchFlare) ? root.hostWindow.notchFlare(root, false) : 0
    // Full bar under liquid glass is one strip and traces its outline once
    // (shell.qml); the item must not outline itself there.
    readonly property real windowBorderWidth: (Prefs.barFull && root.externalGlass) ? 0 : WindowBorder.size

    implicitWidth: 200
    implicitHeight: Theme.dp(Prefs.barHeight)
    // Collapse the footprint when hidden so the remaining left modules
    // (mpris/tray) slide back to the bar margin instead of leaving a gap.
    // Width (not just visible) is what the bar layout, glass pills, flares
    // and input mask all key off — same convention as BarPill.
    width: (shown && !soloCollapse) ? implicitWidth : 0
    height: shown ? implicitHeight : 0
    Behavior on width {
        NumberAnimation {
            duration: Theme.barMs(320)
            easing.type: Easing.OutCubic
        }
    }
    x: restX
    y: restY
    visible: shown
    opacity: shown ? 1 : 0
    scale: shown ? 1 : 0.82
    // Background glass with same drop shadow as other widgets (BarPill)
    Rectangle {
        id: bg
        anchors.fill: parent
        color: "transparent"
        radius: root.cornerRadius
        topLeftRadius: root.topRadius
        topRightRadius: root.topRadius
        clip: false
        layer.enabled: !root.externalGlass && !root.groupBackground
        layer.samples: 4
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowBlur: Theme.hyprShadowBlur
            blurMax: Theme.hyprShadowBlurMax
            shadowColor: Theme.hyprShadow
            shadowHorizontalOffset: Theme.hyprShadowOffsetX
            shadowVerticalOffset: Theme.hyprShadowOffsetY
            shadowScale: Theme.hyprShadowScale
            autoPaddingEnabled: true
        }
        // squircle body, so the window hairline follows the same curve as the
        // rest of the bar (Rectangle's border cannot drop its top edge)
        SquircleRect {
            anchors.fill: parent
            // glass off: this is the body. Under the compositor plugin the
            // body is glass, so this keeps only the window hairline over it.
            visible: !root.groupBackground && (!Prefs.liquidGlassEnabled || (root.externalGlass && root.windowBorderWidth > 0))
            fillColor: root.externalGlass ? "transparent" : Theme.bg
            radius: root.cornerRadius
            topLeftRadius: root.topRadius
            topRightRadius: root.topRadius
            smoothing: Prefs.squircleF
            borderColor: WindowBorder.colour
            borderWidth: root.windowBorderWidth
            borderTop: root.topRadius > 0 ? 1 : 0
            borderGap: Qt.vector2d(root.notchGapLeft, root.notchGapRight)
        }

        LiquidGlassBg {
            anchors.fill: parent
            visible: Prefs.liquidGlassEnabled && !root.externalGlass
            hostWindow: root.hostWindow
            targetScreen: root.hostWindow ? root.hostWindow.screen : null
            bgRadius: root.cornerRadius
            bgTopLeftRadius: root.topRadius
            bgTopRightRadius: root.topRadius
            usePill: true
        }
    }
    Row {
        anchors.centerIn: parent
        spacing: 6
        Repeater {
            model: root.slotCount
            Rectangle {
                width: 10; height: 10; radius: 5
                color: Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === index+1 ? Theme.accent : Theme.subtext
                Text { anchors.centerIn: parent; text: index+1; color: Theme.bg; font.pixelSize: 8; font.weight: Font.Bold; font.variableAxes: Theme.axes(8, 700, 0); visible: Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === index+1 }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Hyprland.dispatch("hl.dsp.focus({workspace=" + (index+1) + "})") }
            }
        }
    }
}

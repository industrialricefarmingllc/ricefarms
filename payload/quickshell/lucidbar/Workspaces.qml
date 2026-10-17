import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs

Item {
    id: root
    property var hostWindow: null
    property real restX: 0
    property real restY: 0
    property bool expanded: false
    property real reveal: expanded ? 1 : 0
    property int slotCount: 6
    property bool shown: Prefs.showWorkspaces
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
    // Notch solo (set by shell.qml): collapse to zero width so the group's
    // open member can stretch across the full previous group span - same
    // convention as BarPill.soloCollapse (width only, height stays so the
    // morph is a pure slide). Also provides compactWidth so spanFor counts
    // the 200px footprint instead of 0 (which made solo panels shrink).
    property bool soloCollapse: false
    property int compactWidth: 200
    implicitWidth: 200
    implicitHeight: 35
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
        layer.enabled: !root.externalGlass
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
        Rectangle {
            anchors.fill: parent
            color: Theme.bg
            radius: root.cornerRadius
            topLeftRadius: root.topRadius
            topRightRadius: root.topRadius
            visible: !Prefs.liquidGlassEnabled && !root.externalGlass
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
                Text { anchors.centerIn: parent; text: index+1; color: Theme.bg; font.pixelSize: 8; visible: Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === index+1 }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Hyprland.dispatch("hl.dsp.focus({workspace=" + (index+1) + "})") }
            }
        }
    }
}

import QtQuick
import QtQuick.Effects
import Quickshell.Hyprland._FocusGrab
import qs
import "../squircle"

Item {
    id: pill

    property var hostWindow: null
    property bool shown: true
    property bool expanded: false
    property bool altOpen: false
    property int compactWidth: 0
    property int compactHeight: Prefs.barHeight
    property int panelWidth: 320
    property int panelHeight: 200
    property int altWidth: 0
    property int altHeight: 0
    property int expandedRadius: Theme.radiusLg
    // how far the compact face shrinks as the panel opens
    property real compactCollapseScale: 0.82
    property bool compactInteractive: true
    property bool focusGrabs: true
    property bool panelFades: true
    property bool surfaceLayered: false
    // External glass (liquid-glass-hypr plugin): QML backgrounds go fully
    // transparent and the plugin draws glass + shadow behind. Content and
    // clip layers are untouched.
    property bool externalGlass: false
    // Notch solo (set by shell.qml): collapse to zero width so the group's
    // open member can stretch across the full previous group span. Separate
    // from shown (which also fades/scales) so the morph is a pure slide and
    // no binding loops with Prefs flags can form.
    property bool soloCollapse: false

    signal compactClicked()

    property alias compactContent: compactHolder.data
    property alias altContent: altHolder.data
    property alias panelContent: panelHolder.data
    property alias overlayContent: overlayHolder.data
    property bool overlayOpen: false
    property Item overlayItem: null

    readonly property int morphDuration: Theme.barDurEnter
    readonly property var morphEasing: Theme.easeEmphasizedDecel

    function beginTransition() {
        panelTransitionTimer.restart();
    }

    readonly property bool anyOpen: pill.expanded || pill.altOpen

    property int panelFadePause: 0
    property int panelFadeDuration: Theme.barMs(220)
    property int compactFadePause: 0
    property int compactFadeDuration: Theme.barMs(220)

    function syncFadeTimings() {
        var open = pill.expanded || pill.altOpen;
        pill.panelFadePause = Theme.barMs(pill.expanded ? 150 : 0);
        pill.panelFadeDuration = Theme.barMs(pill.expanded ? 220 : 150);
        pill.compactFadePause = Theme.barMs(open ? 0 : 150);
        pill.compactFadeDuration = Theme.barMs(open ? 150 : 220);
    }

    onExpandedChanged: pill.syncFadeTimings()
    onAltOpenChanged: pill.syncFadeTimings()
    property bool compactHovered: false
    property bool panelTransitioning: false

    readonly property bool hoverLift: Prefs.barHoverGrow > 0 && pill.compactHovered && !pill.anyOpen && pill.shown
    property real hoverGrow: pill.hoverLift ? Math.min(Prefs.barHoverGrow, Math.max(0, Prefs.barSpacing / 2)) : 0

    property int hoverGrowDuration: Theme.barMs(150)

    onCompactHoveredChanged: pill.hoverGrowDuration = Theme.barMs(pill.compactHovered ? 150 : 220)

    Behavior on hoverGrow {
        NumberAnimation {
            duration: pill.hoverGrowDuration
            easing.type: Easing.OutCubic
        }

    }

    readonly property bool popupMode: Prefs.barPopupMode
    readonly property int openWidth: pill.altOpen ? pill.altWidth : (pill.expanded ? pill.panelWidth : pill.compactWidth)
    readonly property int openHeight: pill.altOpen ? pill.altHeight : (pill.expanded ? pill.panelHeight : pill.compactHeight)
    readonly property int cornerRadius: pill.popupMode ? Math.min(pill.expandedRadius, Math.round(shell.height / 2)) : (pill.anyOpen ? pill.expandedRadius : pill.closedRadius)
    // Closed-tab radius: in notch mode the explicit barNotchRadius
    // (independent of the bar-height cap on barPillRadius); islands keep
    // the height-capped pill value.
    readonly property int closedRadius: Prefs.barNotch ? Prefs.barNotchRadius : Prefs.barPillRadius
    readonly property int topRadius: Prefs.barNotch && !pill.popupMode ? 0 : pill.cornerRadius
    readonly property int pillTopRadius: Prefs.barNotch ? 0 : Prefs.barPillRadius
    readonly property int barRadius: pill.popupMode ? Prefs.barPillRadius : pill.cornerRadius
    readonly property int barTopRadius: pill.popupMode ? pill.pillTopRadius : pill.topRadius

    property string popupAlign: "left"
    property bool popupIsAlt: false

    onAnyOpenChanged: {
        if (pill.anyOpen)
            pill.popupIsAlt = pill.altOpen && !pill.expanded;

        panelTransitionTimer.restart();
    }

    readonly property int popupWidth: pill.popupIsAlt ? pill.altWidth : pill.panelWidth
    readonly property int popupHeight: pill.popupIsAlt ? pill.altHeight : pill.panelHeight
    readonly property real popupX: {
        if (!pill.popupMode)
            return 0;

        if (pill.popupAlign === "right")
            return pill.compactWidth - pill.popupWidth;

        if (pill.popupAlign === "center")
            return (pill.compactWidth - pill.popupWidth) / 2;

        return 0;
    }
    readonly property bool popupExpanding: pill.popupMode && pill.anyOpen
    readonly property bool popupOpen: pill.shown && pill.popupMode && shell.y > 0.5
    readonly property Item popupItem: shell

    // Docked (notch) hover grows from the fixed outer edge so compact text
    // stays put: left notches keep their left edge, right notches keep
    // their right edge, center grows symmetrically. Matches the expansion
    // direction (outer-fixed for sides, center-fixed for clock), so text
    // doesn't slide between hover and open.
    readonly property bool alignLeft: pill.popupAlign === "left"
    readonly property bool alignRight: pill.popupAlign === "right"
    readonly property real surfaceX: pill.alignRight ? -pill.hoverGrow : (pill.alignLeft ? 0 : -pill.hoverGrow)
    readonly property real surfaceY: 0
    readonly property real hoverGrowWidth: pill.hoverGrow * ((pill.popupAlign === "center") ? 2 : 1)
    readonly property real surfaceWidth: (pill.popupMode ? pill.compactWidth : pill.width) + pill.hoverGrowWidth
    readonly property real surfaceHeight: pill.popupMode ? pill.compactHeight : pill.height

    implicitWidth: (!pill.shown || pill.soloCollapse) ? 0 : (pill.popupMode ? pill.compactWidth : pill.openWidth)
    implicitHeight: !pill.shown ? 0 : (pill.popupMode ? pill.compactHeight : pill.openHeight)
    opacity: pill.shown ? 1 : 0
    scale: pill.shown ? 1 : 0.82
    transformOrigin: Item.Center
    visible: pill.opacity > 0.01
    clip: false
    z: (pill.popupOpen || pill.overlayOpen) ? 100 : 1

    Behavior on opacity {
        NumberAnimation {
            duration: Theme.barMs(180)
            easing.type: Easing.OutCubic
        }

    }

    Behavior on scale {
        NumberAnimation {
            duration: Theme.barMs(260)
            easing.type: pill.shown ? Easing.OutBack : Easing.InCubic
        }

    }

    Behavior on implicitWidth {
        NumberAnimation {
            duration: pill.morphDuration
            easing.type: Easing.Bezier
            easing.bezierCurve: pill.morphEasing
        }

    }

    property bool shownTransition: false

    onShownChanged: {
        pill.shownTransition = true;
        shownTransitionTimer.restart();
    }

    Behavior on implicitHeight {
        enabled: !pill.anyOpen || pill.panelTransitioning || pill.shownTransition

        NumberAnimation {
            duration: pill.morphDuration
            easing.type: Easing.Bezier
            easing.bezierCurve: pill.morphEasing
        }

    }

    Item {
        id: overlayHolder

        x: 0
        y: 0
        width: (pill.overlayOpen && pill.hostWindow) ? Math.max(pill.width, pill.hostWindow.width - pill.x) : pill.width
        height: (pill.overlayOpen && pill.hostWindow) ? Math.max(pill.height, pill.hostWindow.height - pill.y) : pill.height
        z: 200
    }

    Timer {
        id: shownTransitionTimer

        interval: Theme.barMs(420)
        onTriggered: pill.shownTransition = false
    }

    Timer {
        id: panelTransitionTimer

        interval: Theme.barMs(420)
        onTriggered: pill.panelTransitioning = false
        onRunningChanged: {
            if (running)
                pill.panelTransitioning = true;

        }
    }

    Rectangle {
        id: pillRect

        visible: pill.popupMode
        x: pill.surfaceX
        y: pill.surfaceY
        width: pill.compactWidth + pill.hoverGrowWidth
        height: pill.compactHeight
        color: "transparent"
        clip: false
        radius: pill.closedRadius
        topLeftRadius: pill.pillTopRadius
        topRightRadius: pill.pillTopRadius
        // No QML shadow under external glass: the plugin draws it, and a
        // shadow of the transparent bg would blob around glyphs instead.
        layer.enabled: !pill.externalGlass
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

        LiquidGlassBg {
            anchors.fill: parent
            externalGlass: pill.externalGlass
            hostWindow: pill.hostWindow
            targetScreen: pill.hostWindow ? pill.hostWindow.screen : null
            powerFactor: Prefs.liquidGlassPower
            bgRadius: pill.closedRadius
            bgTopLeftRadius: pill.pillTopRadius
            bgTopRightRadius: pill.pillTopRadius
            usePill: true
        }

    }

    Rectangle {
        id: shell

        width: pill.popupMode ? (pill.anyOpen ? pill.popupWidth : pill.compactWidth + pill.hoverGrowWidth) : pill.width + pill.hoverGrowWidth
        height: pill.popupMode ? (pill.anyOpen ? pill.popupHeight : pill.compactHeight) : pill.height
        x: pill.popupMode && pill.anyOpen ? pill.popupX : pill.surfaceX
        y: pill.popupMode && pill.anyOpen ? pill.compactHeight + Prefs.barPopupGap : pill.surfaceY
        visible: !pill.popupMode || shell.y > 0.5
        color: "transparent"
        radius: pill.cornerRadius
        topLeftRadius: pill.topRadius
        topRightRadius: pill.topRadius
        // clip via inner container to ensure overflow hidden even with layer
        clip: false
        layer.enabled: !pill.externalGlass
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

        LiquidGlassBg {
            anchors.fill: parent
            externalGlass: pill.externalGlass
            hostWindow: pill.hostWindow
            targetScreen: pill.hostWindow ? pill.hostWindow.screen : null
            powerFactor: Prefs.liquidGlassPower + (pill.anyOpen ? 0.4 : 0)
            bgRadius: pill.cornerRadius
            bgTopLeftRadius: pill.topRadius
            bgTopRightRadius: pill.topRadius
            usePill: true
        }
        // inner clip for content overflow — separate from outer layer
        Item {
            id: shellContentClip
            anchors.fill: parent
            clip: true
            layer.enabled: true
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: shellContentMask
            }
            // content inside clipped container
            Item {
                id: compactFace
                parent: pill.popupMode ? pillRect : shellContentClip
                anchors.fill: parent
                opacity: pill.popupMode || !pill.anyOpen ? 1 : 0
                scale: pill.popupMode || !pill.anyOpen ? 1 : pill.compactCollapseScale
                // Scale from the fixed outer edge so outer-aligned text stays
                // put while fading (left keeps left, right keeps right).
                transformOrigin: pill.alignLeft ? Item.Left : (pill.alignRight ? Item.Right : Item.Center)
                visible: opacity > 0.01
                MouseArea {
                    anchors.fill: parent
                    enabled: pill.compactInteractive
                    hoverEnabled: pill.compactInteractive
                    cursorShape: Qt.PointingHandCursor
                    onEntered: pill.compactHovered = true
                    onExited: pill.compactHovered = false
                    onClicked: {
                        pill.compactClicked();
                        pill.expanded = true;
                    }
                }
                Item {
                    id: compactHolder
                    width: pill.compactWidth
                    height: pill.compactHeight
                    // Outer-aligned (top-fixed) so text stays put while the
                    // pill grows from the fixed outer edge (sides) or center.
                    // Centered would slide by half the growth during expansion;
                    // top-fixed keeps it from sinking as height grows.
                    y: 0
                    x: pill.alignLeft ? 0 : (pill.alignRight ? parent.width - width : (parent.width - width) / 2)
                }
                Behavior on opacity {
                    SequentialAnimation {
                        PauseAnimation { duration: pill.compactFadePause }
                        NumberAnimation { duration: pill.compactFadeDuration; easing.type: Easing.OutCubic }
                    }
                }
                Behavior on scale {
                    NumberAnimation { duration: Theme.barMs(220); easing.type: Easing.OutCubic }
                }
            }
            Item {
                id: altHolder
                anchors.fill: parent
                opacity: pill.altOpen && !pill.expanded ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity {
                    NumberAnimation { duration: Theme.barMs(200); easing.type: Easing.OutCubic }
                }
            }
            Item {
                id: panelHolder
                anchors.fill: parent
                opacity: (!pill.panelFades || pill.expanded) ? 1 : 0
                // No overshoot scale: under external glass there is no QML bg
                // to hide behind, so even a 4% pop spills past the rounded
                // corners visibly. The fade carries the transition alone.
                scale: 1
                visible: opacity > 0.01
                HyprlandFocusGrab {
                    active: pill.expanded && pill.focusGrabs
                    windows: pill.hostWindow ? [pill.hostWindow] : []
                    onCleared: pill.expanded = false
                }
                Behavior on opacity {
                    SequentialAnimation {
                        PauseAnimation { duration: pill.panelFadePause }
                        NumberAnimation { duration: pill.panelFadeDuration; easing.type: Easing.OutCubic }
                    }
                }
                Behavior on scale {
                    SequentialAnimation {
                        PauseAnimation { duration: pill.panelFadePause }
                        NumberAnimation { duration: Theme.barMs(220); easing.type: Easing.OutCubic }
                    }
                }
            }
        }
        Item {
            id: shellContentMask
            anchors.fill: parent
            visible: false
            layer.enabled: true
            // Squircle content clip: same curve the compositor plugin draws
            // for the glass behind (squircleF), so text/icons never poke
            // past the visible corner.
            SquircleMask {
                anchors.fill: parent
                radius: pill.cornerRadius
                topLeftRadius: pill.topRadius
                topRightRadius: pill.topRadius
                smoothing: Prefs.squircleF
            }
        }

        Behavior on x {
            enabled: pill.popupMode

            NumberAnimation {
                duration: pill.popupExpanding ? pill.morphDuration : Theme.barDurExit
                easing.type: Easing.Bezier
                easing.bezierCurve: pill.popupExpanding ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel
            }

        }

        Behavior on y {
            enabled: pill.popupMode

            NumberAnimation {
                duration: pill.popupExpanding ? pill.morphDuration : Theme.barDurExit
                easing.type: Easing.Bezier
                easing.bezierCurve: pill.popupExpanding ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel
            }

        }

        Behavior on width {
            enabled: pill.popupMode

            NumberAnimation {
                duration: pill.popupExpanding ? pill.morphDuration : Theme.barDurExit
                easing.type: Easing.Bezier
                easing.bezierCurve: pill.popupExpanding ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel
            }

        }

        Behavior on height {
            enabled: pill.popupMode

            NumberAnimation {
                duration: pill.popupExpanding ? pill.morphDuration : Theme.barDurExit
                easing.type: Easing.Bezier
                easing.bezierCurve: pill.popupExpanding ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel
            }

        }

        Behavior on radius {
            NumberAnimation {
                duration: Theme.barMs(380)
                easing.type: Easing.OutCubic
            }

        }

    }
}

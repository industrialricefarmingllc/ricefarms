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
    property int compactHeight: Theme.dp(Prefs.barHeight)
    property int panelWidth: Theme.dp(320)
    property int panelHeight: Theme.dp(200)
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

    // ── liquid morph ────────────────────────────────────────────────────
    // Shape animation ported from Vitreus' bar drawers: an underdamped
    // spring (`drip = 170, 18`) grows the body out of the exact pressed
    // point, a smooth-union neck joins it to the compact pill, and the
    // body stretches with spring velocity. Only the motion is borrowed —
    // this draws the same Theme.bg fill as the normal body, no glass.
    // The shader silhouette is shown while the spring runs; when it
    // settles the ordinary QML body takes over pixel-identically.
    property bool liquidMorph: true
    property bool liquidRunning: false
    property bool liquidHasOrigin: false
    property real liquidOriginX: 0
    property real liquidOriginY: 0
    // Open rect, frozen on close so the body still knows where to fold to.
    property real liquidOpenX: 0
    property real liquidOpenY: 0
    property real liquidOpenW: 0
    property real liquidOpenH: 0
    readonly property bool glassUnion: !!(pill.hostWindow && pill.hostWindow.glassUnion)
    readonly property bool liquidActive: pill.liquidMorph && pill.liquidRunning && (!pill.externalGlass || pill.glassUnion)
    // The QML silhouette is only used when no external glass owns the body.
    // With glass on, the compositor plugin draws the same union shape (see
    // shell.qml's glassPillFor).
    readonly property bool liquidDrawBody: pill.liquidActive && !pill.externalGlass
    readonly property bool liquidCentre: pill.popupAlign === "center"
    // Centre and right pills read as an extrusion when their body travels
    // down from the click. Keep their top edge on the bar and let width lead;
    // left pills keep the Vitreus drop/origin motion.
    readonly property bool liquidTopPinned: pill.popupAlign === "center" || pill.popupAlign === "right"
    readonly property real liquidP: liquidSpring.value
    readonly property real liquidPad: 28

    // Live compact pill in pill coordinates. In island mode it sits inside
    // the growing shell; in popup mode it is the separate pillRect.
    readonly property real liquidCompactX: (pill.popupMode ? pillRect.x : shell.x) + compactHolder.x
    readonly property real liquidCompactY: (pill.popupMode ? pillRect.y : shell.y) + compactHolder.y
    readonly property real liquidCompactW: compactHolder.width
    readonly property real liquidCompactH: compactHolder.height

    readonly property real liquidBubble: Math.max(8, Math.min(12, pill.compactHeight * 0.34))
    // The droplet is born at the click and dies back into it, so the shader
    // silhouette at p=0 is exactly the compact pill (no last-frame pop).
    readonly property real liquidBirth: Math.min(1, Math.max(0, pill.liquidP) * 8)
    readonly property real liquidBubbleNow: pill.liquidBubble * pill.liquidBirth
    // Vitreus' drawer growth curves: width rushes out first, height follows.
    // The centre (clock) leads even harder with width and only drops its height
    // once the stretch has widened — otherwise it reads as a tongue extruding
    // down out of the bar.
    readonly property real liquidGrowW: Math.min(1.18, Math.min(1, Math.max(0, pill.liquidP) * 1.45) + Math.max(0, pill.liquidP - 1) * 0.4)
    readonly property real liquidGrowH: pill.liquidTopPinned ? Math.min(1.18, Math.max(0, (pill.liquidP - 0.30) / 0.70) + Math.max(0, pill.liquidP - 1) * 0.4) : Math.min(1.18, Math.max(0, pill.liquidP) + Math.max(0, pill.liquidP - 1) * 0.4)
    readonly property real liquidTravel: Math.min(1, Math.max(0, pill.liquidP) * 1.3)
    // Drop stretch: the velocity of the spring bows the body wide for a
    // moment as it leaves the bar (capped; negatives do not squash it).
    readonly property real liquidStretch: Math.max(0, Math.min(0.035, liquidSpring.velocity * 0.012))
    readonly property real liquidPanelW: Math.max(0, (pill.liquidBubbleNow + (Math.max(pill.liquidBubbleNow, pill.liquidOpenW) - pill.liquidBubbleNow) * pill.liquidGrowW) * (1 + pill.liquidStretch))
    readonly property real liquidPanelH: Math.max(0, (pill.liquidBubbleNow + (Math.max(pill.liquidBubbleNow, pill.liquidOpenH) - pill.liquidBubbleNow) * pill.liquidGrowH) * (1 - pill.liquidStretch * 0.5))
    // Centre: top edge stays on the bar, width still grows from the click.
    readonly property real liquidPanelCx: pill.liquidOriginX + (pill.liquidOpenX + pill.liquidOpenW / 2 - pill.liquidOriginX) * pill.liquidTravel
    readonly property real liquidPanelCy: pill.liquidTopPinned ? (pill.liquidOpenY + pill.liquidPanelH / 2) : (pill.liquidOriginY + (pill.liquidOpenY + pill.liquidOpenH / 2 - pill.liquidOriginY) * pill.liquidTravel)
    readonly property real liquidPanelRawX: pill.liquidPanelCx - pill.liquidPanelW / 2
    readonly property real liquidPanelRawY: pill.liquidPanelCy - pill.liquidPanelH / 2
    // Keep the box inside compact ∪ open, with a little slack so a click near
    // an edge still visibly bulges (and so the glass union never spills far
    // over a neighbouring pill).
    readonly property real liquidSlack: 8
    readonly property real liquidClampX0: Math.min(pill.liquidCompactX, pill.liquidOpenX) - pill.liquidSlack
    readonly property real liquidClampX1: Math.max(pill.liquidClampX0, Math.max(pill.liquidCompactX + pill.liquidCompactW, pill.liquidOpenX + pill.liquidOpenW) - pill.liquidPanelW + pill.liquidSlack)
    readonly property real liquidClampY0: Math.min(pill.liquidCompactY, pill.liquidOpenY) - pill.liquidSlack
    readonly property real liquidClampY1: Math.max(pill.liquidClampY0, Math.max(pill.liquidCompactY + pill.liquidCompactH, pill.liquidOpenY + pill.liquidOpenH) - pill.liquidPanelH + pill.liquidSlack)
    readonly property real liquidPanelX: Math.max(pill.liquidClampX0, Math.min(pill.liquidClampX1, pill.liquidPanelRawX))
    readonly property real liquidPanelY: Math.max(pill.liquidClampY0, Math.min(pill.liquidClampY1, pill.liquidPanelRawY))
    // Neck width: in popup mode the compact pill and panel are separate, so
    // pinch the neck off before the final handoff (otherwise the gap would
    // visibly snap closed). Island mode can keep it.
    readonly property real liquidGoo: {
        const base = Math.max(6, Math.min(14, pill.compactHeight * 0.32)) * pill.liquidBirth;
        if (!pill.popupMode)
            return base;
        return base * (1 - Math.max(0, Math.min(1, (pill.liquidP - 0.8) / 0.18)));
    }
    // Round at birth (a drop), square up as it lands, exactly like Vitreus.
    readonly property real liquidCornerMix: Math.max(0, Math.min(1, pill.liquidP * 2.2 - 0.05))
    readonly property real liquidCorner0: Math.min(pill.liquidPanelW, pill.liquidPanelH) / 2
    readonly property real liquidPanelTL: pill.popupMode ? pill.capped(pill.notchedPopup ? pill.hangTops : null, "tl", pill.topRadius) : (pill.joinLeft ? 0 : pill.topRadius)
    readonly property real liquidPanelTR: pill.popupMode ? pill.capped(pill.notchedPopup ? pill.hangTops : null, "tr", pill.topRadius) : (pill.joinRight ? 0 : pill.topRadius)
    readonly property real liquidPanelBL: pill.popupMode ? pill.cornerRadius : pill.capped(pill.hangSides, "bl", pill.capped(pill.hangCorners, "bl", pill.joinLeft && !pill.hangSides ? 0 : pill.cornerRadius))
    readonly property real liquidPanelBR: pill.popupMode ? pill.cornerRadius : pill.capped(pill.hangSides, "br", pill.capped(pill.hangCorners, "br", pill.joinRight && !pill.hangSides ? 0 : pill.cornerRadius))
    readonly property real liquidCompactTL: pill.popupMode ? (pill.joinLeft ? 0 : pill.pillTopRadius) : (pill.joinLeft ? 0 : (Prefs.barFlush ? 0 : pill.closedRadius))
    readonly property real liquidCompactTR: pill.popupMode ? (pill.joinRight ? 0 : pill.pillTopRadius) : (pill.joinRight ? 0 : (Prefs.barFlush ? 0 : pill.closedRadius))
    readonly property real liquidCompactBL: pill.capped(pill.hangCorners, "bl", pill.joinLeft ? 0 : pill.closedRadius)
    readonly property real liquidCompactBR: pill.capped(pill.hangCorners, "br", pill.joinRight ? 0 : pill.closedRadius)
    readonly property vector4d liquidPanelRadii: Qt.vector4d(
        pill.liquidCorner0 + (pill.liquidPanelTL - pill.liquidCorner0) * pill.liquidCornerMix,
        pill.liquidCorner0 + (pill.liquidPanelTR - pill.liquidCorner0) * pill.liquidCornerMix,
        pill.liquidCorner0 + (pill.liquidPanelBR - pill.liquidCorner0) * pill.liquidCornerMix,
        pill.liquidCorner0 + (pill.liquidPanelBL - pill.liquidCorner0) * pill.liquidCornerMix)
    readonly property vector4d liquidCompactRadii: Qt.vector4d(
        pill.liquidCompactTL,
        pill.liquidCompactTR,
        pill.liquidCompactBR,
        pill.liquidCompactBL)

    // Stable shader bounds for the whole transition: the layer texture must
    // not be reallocated on every spring frame.
    readonly property real liquidBoundsW: Math.max(pill.liquidCompactX + pill.liquidCompactW, pill.liquidOpenX + pill.liquidOpenW * 1.2, pill.liquidPanelX + pill.liquidPanelW) + pill.liquidPad * 2
    readonly property real liquidBoundsH: Math.max(pill.liquidCompactY + pill.liquidCompactH, pill.liquidOpenY + pill.liquidOpenH * 1.2, pill.liquidPanelY + pill.liquidPanelH) + pill.liquidPad * 2
    // Panel content only uncovers once the body is essentially at its
    // final silhouette, so text can never poke out of the liquid shape.
    readonly property real liquidPanelReveal: {
        if (!pill.liquidActive)
            return 1;

        return Math.max(0, Math.min(1, (pill.liquidP - 0.86) / 0.12));
    }

    function noteLiquidOrigin(x, y, item) {
        const from = item || pill;
        const p = from.mapToItem(pill, x, y);
        pill.liquidOriginX = p.x;
        pill.liquidOriginY = p.y;
        pill.liquidHasOrigin = true;
    }

    function liquidDefaultOrigin() {
        pill.liquidOriginX = pill.liquidCompactX + pill.liquidCompactW / 2;
        pill.liquidOriginY = pill.liquidCompactY + pill.liquidCompactH / 2;
        pill.liquidHasOrigin = true;
    }

    function captureLiquidOpen() {
        if (pill.popupMode) {
            pill.liquidOpenX = pill.popupX;
            pill.liquidOpenY = pill.compactHeight + Prefs.barPopupGap;
            pill.liquidOpenW = pill.popupWidth;
            pill.liquidOpenH = pill.popupHeight;
        } else {
            pill.liquidOpenX = 0;
            pill.liquidOpenY = 0;
            pill.liquidOpenW = pill.openWidth;
            pill.liquidOpenH = pill.openHeight;
        }
    }

    property alias compactContent: compactHolder.data
    property alias altContent: altHolder.data
    property alias panelContent: panelHolder.data
    property alias overlayContent: overlayHolder.data
    property bool overlayOpen: false
    property Item overlayItem: null

    readonly property int morphDuration: Theme.barDurEnter
    readonly property var morphEasing: Theme.easeEmphasizedDecel

    // the look picked on the module's card, and the one its face draws: a
    // switch fades the old look out, flips, and brings the new one in as the
    // pill takes its width. one set as the bar comes up just shows
    property string lookPref: ""
    property string look: ""
    property bool lookSettled: false

    function switchLook() {
        if (pill.look === pill.lookPref)
            return ;

        if (!pill.lookSettled || !pill.shown || !pill.visible) {
            lookSwitch.stop();
            // a pill on its way out keeps its contents faded
            if (pill.shown) {
                compactHolder.opacity = 1;
                compactHolder.scale = 1;
            }
            pill.look = pill.lookPref;
            return ;
        }
        lookSwitch.restart();
    }

    onLookPrefChanged: pill.switchLook()
    Component.onCompleted: pill.look = pill.lookPref

    Timer {
        interval: 1500
        running: Prefs.loaded && !pill.lookSettled
        onTriggered: pill.lookSettled = true
    }

    SequentialAnimation {
        id: lookSwitch

        ParallelAnimation {
            NumberAnimation {
                target: compactHolder
                property: "opacity"
                to: 0
                duration: Theme.barMs(120)
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.easeEmphasizedAccel
            }

            NumberAnimation {
                target: compactHolder
                property: "scale"
                to: 0.86
                duration: Theme.barMs(120)
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.easeEmphasizedAccel
            }

        }

        ScriptAction {
            script: pill.look = pill.lookPref
        }

        ParallelAnimation {
            NumberAnimation {
                target: compactHolder
                property: "opacity"
                to: 1
                duration: Theme.barMs(240)
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.easeEmphasizedDecel
            }

            NumberAnimation {
                target: compactHolder
                property: "scale"
                to: 1
                duration: Theme.barMs(320)
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.curveDefaultSpatial
            }

        }

    }

    // the id the bar knows this pill by
    function moduleId() {
        const map = pill.hostWindow && pill.hostWindow.moduleById ? pill.hostWindow.moduleById : {};
        for (const id in map) {
            if (map[id] === pill)
                return id;

        }
        return "";
    }

    function beginTransition() {
        panelTransitionTimer.restart();
    }

    readonly property bool anyOpen: pill.expanded || pill.altOpen

    property int panelFadePause: 0
    property int panelFadeDuration: Theme.barMs(220)
    property int compactFadePause: 0
    property int compactFadeDuration: Theme.barMs(220)

    // set in syncFadeTimings: popupExpanding is still stale when the Behaviors start
    property int popupMorphDuration: pill.morphDuration
    property var popupMorphCurve: Theme.easeEmphasizedDecel

    function syncFadeTimings() {
        var open = pill.expanded || pill.altOpen;
        pill.popupMorphDuration = open ? pill.morphDuration : Theme.barDurExit;
        pill.popupMorphCurve = open ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel;
        pill.panelFadePause = Theme.barMs(pill.expanded ? 150 : 0);
        pill.panelFadeDuration = Theme.barMs(pill.expanded ? 220 : 150);
        pill.compactFadePause = Theme.barMs(open ? 0 : 150);
        pill.compactFadeDuration = Theme.barMs(open ? 150 : 220);
    }

    onExpandedChanged: pill.syncFadeTimings()
    onAltOpenChanged: pill.syncFadeTimings()
    property bool compactHovered: false
    property bool panelTransitioning: false

    // joined to a neighbour in Settings > Bar: the shared edge loses its corners
    // and its gap, so the group reads as one island (or one notch). the bar works
    // it out; the open popup of popup mode stands apart either way
    readonly property string modId: pill.moduleId()
    readonly property bool joinLeft: !!pill.hostWindow && !!pill.hostWindow.joinedLeftOf && pill.modId !== "" && pill.hostWindow.joinedLeftOf(pill.modId)
    readonly property bool joinRight: !!pill.hostWindow && !!pill.hostWindow.joinedRightOf && pill.modId !== "" && pill.hostWindow.joinedRightOf(pill.modId)
    readonly property bool joined: pill.joinLeft || pill.joinRight

    // how each corner meets a panel hanging below the bar, from shell.qml's hangPlan
    readonly property bool notchedPopup: pill.popupMode && Prefs.barPopupNotched
    readonly property var hangPlan: pill.hostWindow && pill.hostWindow.hangPlan ? pill.hostWindow.hangPlan : null
    readonly property var hangCorners: pill.hangPlan && pill.modId !== "" ? (pill.hangPlan.corners[pill.modId] || null) : null
    readonly property var hangTops: pill.hangPlan && pill.modId !== "" ? (pill.hangPlan.tops[pill.modId] || null) : null
    readonly property var hangSides: pill.hangPlan && pill.modId !== "" ? (pill.hangPlan.sides[pill.modId] || null) : null

    function capped(limits, corner, v) {
        return limits && limits[corner] !== undefined ? Math.max(0, Math.min(v, limits[corner])) : v;
    }

    // growing sideways would run into a joined neighbour, so a joined pill lights
    // up in place instead
    readonly property bool hoverLift: Prefs.barHoverGrow > 0 && pill.compactHovered && !pill.anyOpen && pill.shown && !pill.joined
    property real hoverGrow: pill.hoverLift ? Math.min(Theme.dp(Prefs.barHoverGrow), Math.max(0, Theme.dp(Prefs.barSpacing) / 2)) : 0

    property int hoverGrowDuration: Theme.barMs(150)

    onCompactHoveredChanged: pill.hoverGrowDuration = Theme.barMs(pill.compactHovered ? 150 : 220)

    Behavior on hoverGrow {
        NumberAnimation {
            duration: pill.hoverGrowDuration
            easing.type: Easing.OutCubic
        }

    }

    // hover to open: the pill unfolds on its own once the pointer rests on it,
    // and folds back when the pointer leaves. Opened this way it deliberately
    // skips the focus grab - that pulls the keyboard off the focused window, and
    // merely passing over the bar must not do that - so a click anywhere on the
    // pill promotes it to an ordinary clicked-open panel, grab and all.
    // off for a pill that is only a button, with nothing to unfold
    property bool opensOnHover: true
    readonly property bool hoverOpens: Prefs.barHoverOpen && pill.shown && pill.opensOnHover
    property bool hoverOpen: false
    readonly property bool surfaceHovered: pill.compactHovered || shellHover.hovered || pillHover.hovered

    function openOnHover() {
        if (!pill.hoverOpens || pill.anyOpen)
            return ;

        pill.hoverOpen = true;
        pill.compactClicked();
        pill.expanded = true;
    }

    function closeHoverOpen() {
        if (!pill.hoverOpen)
            return ;

        // collapse first: dropping hoverOpen while still expanded would arm the
        // focus grab for an instant on the way out
        pill.expanded = false;
        pill.hoverOpen = false;
    }

    onSurfaceHoveredChanged: {
        if (pill.surfaceHovered) {
            hoverCloseTimer.stop();
            if (pill.hoverOpens && !pill.anyOpen)
                hoverOpenTimer.restart();

        } else {
            hoverOpenTimer.stop();
            if (pill.hoverOpen)
                hoverCloseTimer.restart();

        }
    }
    onHoverOpensChanged: {
        if (!pill.hoverOpens)
            pill.closeHoverOpen();

    }

    // long enough that sweeping the pointer across the bar opens nothing
    Timer {
        id: hoverOpenTimer

        interval: 180
        onTriggered: pill.openOnHover()
    }

    // in pop-up mode the gap between pill and panel is outside the input region,
    // so crossing it unhovers both; this rides that out
    Timer {
        id: hoverCloseTimer

        interval: 320
        onTriggered: {
            if (!pill.surfaceHovered)
                pill.closeHoverOpen();

        }
    }

    readonly property bool popupMode: Prefs.barPopupMode
    readonly property int openWidth: pill.altOpen ? pill.altWidth : (pill.expanded ? pill.panelWidth : pill.compactWidth)
    readonly property int openHeight: pill.altOpen ? pill.altHeight : (pill.expanded ? pill.panelHeight : pill.compactHeight)
    readonly property int cornerRadius: pill.popupMode ? Math.min(pill.expandedRadius, Math.round(shell.height / 2)) : (pill.anyOpen ? pill.expandedRadius : pill.closedRadius)
    // Closed-tab radius: in notch mode the explicit barNotchRadius (independent
    // of the bar-height cap on barPillRadius); islands keep the height-capped
    // pill value.
    readonly property int closedRadius: Prefs.barNotch ? Prefs.barNotchRadius : Prefs.barPillRadius
    readonly property int topRadius: Prefs.barFlush && !pill.popupMode ? 0 : pill.cornerRadius
    readonly property int pillTopRadius: Prefs.barFlush ? 0 : Prefs.barPillRadius
    // on the full bar the strip behind already paints the resting pill, so the
    // pill itself only shows a hover tint
    readonly property color restingColor: Prefs.barFull ? Theme.alpha(Theme.bg, 0) : Theme.bg
    // still taller than the pill: a closing panel keeps its colour until it has
    // folded away, or on the full bar its fading contents float over the desktop
    readonly property bool surfaceOpen: pill.anyOpen || pill.height > pill.compactHeight + 0.5
    readonly property int barRadius: pill.popupMode ? Prefs.barPillRadius : pill.cornerRadius
    readonly property int barTopRadius: pill.popupMode ? pill.pillTopRadius : pill.topRadius

    property string popupAlign: "left"
    property bool popupIsAlt: false

    onAnyOpenChanged: {
        if (pill.anyOpen)
            pill.popupIsAlt = pill.altOpen && !pill.expanded;
        else
            pill.hoverOpen = false;

        if (pill.liquidMorph) {
            if (pill.anyOpen) {
                pill.captureLiquidOpen();
                if (!pill.liquidHasOrigin)
                    pill.liquidDefaultOrigin();
                pill.liquidHasOrigin = false;
                pill.liquidRunning = true;
                liquidSpring.target = 1;
            } else if (pill.liquidP > 0.0001 || pill.liquidRunning) {
                pill.liquidRunning = true;
                liquidSpring.target = 0;
            }
        }

        panelTransitionTimer.restart();
    }

    // Keep the frozen target in step while the panel is open and its content
    // changes height (Mpris pages, System subviews). Closing freezes it.
    onOpenWidthChanged: if (pill.anyOpen && pill.liquidRunning) pill.captureLiquidOpen()
    onOpenHeightChanged: if (pill.anyOpen && pill.liquidRunning) pill.captureLiquidOpen()

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
    readonly property bool popupOpen: pill.shown && pill.popupMode && (pill.notchedPopup ? shell.height > 0.5 : shell.y > 0.5)
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
    // the corners ModuleRegion's mask and blur follow
    readonly property real barTopLeftRadius: pill.popupMode ? pillRect.topLeftRadius : shell.topLeftRadius
    readonly property real barTopRightRadius: pill.popupMode ? pillRect.topRightRadius : shell.topRightRadius
    readonly property real barBottomLeftRadius: pill.popupMode ? pillRect.bottomLeftRadius : shell.bottomLeftRadius
    readonly property real barBottomRightRadius: pill.popupMode ? pillRect.bottomRightRadius : shell.bottomRightRadius
    readonly property real popupTopLeftRadius: shell.topLeftRadius
    readonly property real popupTopRightRadius: shell.topRightRadius

    // leaving, the contents fade first, then the pill fades and shrinks as the
    // gap closes on the standard curve; its height holds until it has gone, so
    // it never squashes up into the bar's edge. set in onShownChanged, the one
    // place the animations below read it fresh
    property bool exiting: false

    implicitWidth: (!pill.shown || pill.soloCollapse) ? 0 : (pill.popupMode ? pill.compactWidth : pill.openWidth)
    implicitHeight: !pill.shown ? 0 : (pill.popupMode ? pill.compactHeight : pill.openHeight)
    opacity: pill.shown ? 1 : 0
    scale: pill.shown ? 1 : 0.86
    transformOrigin: Item.Center
    visible: pill.opacity > 0.01
    clip: false
    z: (pill.popupOpen || pill.overlayOpen) ? 100 : 1

    Behavior on opacity {
        SequentialAnimation {
            PauseAnimation {
                duration: pill.exiting ? Theme.barMs(40) : 0
            }

            NumberAnimation {
                duration: pill.exiting ? Theme.barMs(180) : Theme.barMs(180)
                easing.type: pill.exiting ? Easing.InOutCubic : Easing.OutCubic
            }

        }

    }

    Behavior on scale {
        NumberAnimation {
            duration: pill.exiting ? Theme.barMs(300) : Theme.barMs(260)
            easing.type: pill.exiting ? Easing.InOutCubic : Easing.OutBack
        }

    }

    Behavior on implicitWidth {
        NumberAnimation {
            duration: pill.exiting ? Theme.barMs(360) : pill.morphDuration
            easing.type: Easing.Bezier
            easing.bezierCurve: pill.exiting ? Theme.curveStandard : pill.morphEasing
        }

    }

    property bool shownTransition: false

    onShownChanged: {
        pill.exiting = !pill.shown;
        pill.shownTransition = true;
        shownTransitionTimer.restart();
        if (pill.exiting) {
            lookSwitch.stop();
            contentEnter.stop();
            contentExit.restart();
        } else {
            contentExit.stop();
            contentEnter.restart();
        }
    }

    ParallelAnimation {
        id: contentExit

        NumberAnimation {
            target: compactHolder
            property: "opacity"
            to: 0
            duration: Theme.barMs(90)
            easing.type: Easing.OutCubic
        }

        NumberAnimation {
            target: compactHolder
            property: "scale"
            to: 0.9
            duration: Theme.barMs(90)
            easing.type: Easing.OutCubic
        }

    }

    ParallelAnimation {
        id: contentEnter

        NumberAnimation {
            target: compactHolder
            property: "opacity"
            to: 1
            duration: Theme.barMs(200)
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.easeEmphasizedDecel
        }

        NumberAnimation {
            target: compactHolder
            property: "scale"
            to: 1
            duration: Theme.barMs(240)
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.easeEmphasizedDecel
        }

    }

    Behavior on implicitHeight {
        enabled: !pill.anyOpen || pill.panelTransitioning || pill.shownTransition

        SequentialAnimation {
            PauseAnimation {
                duration: pill.exiting ? Theme.barMs(280) : 0
            }

            NumberAnimation {
                duration: pill.exiting ? 0 : pill.morphDuration
                easing.type: Easing.Bezier
                easing.bezierCurve: pill.morphEasing
            }

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

    LiquidSpring {
        id: liquidSpring

        stiffness: 190
        damping: 24
        mass: 1
        epsilon: 0.002
        onSettled: {
            if (pill.liquidRunning) {
                pill.liquidRunning = false;
                pill.liquidHasOrigin = false;
            }
        }
    }

    LiquidShape {
        id: liquidBody

        z: -1
        visible: pill.liquidDrawBody
        x: -pill.liquidPad
        y: -pill.liquidPad
        width: pill.liquidBoundsW
        height: pill.liquidBoundsH
        fillColor: Theme.bg
        smoothing: Prefs.squircleF
        goo: pill.liquidGoo
        compactRect: Qt.vector4d(pill.liquidCompactX + pill.liquidPad, pill.liquidCompactY + pill.liquidPad, pill.liquidCompactW, pill.liquidCompactH)
        compactRadii: pill.liquidCompactRadii
        panelRect: Qt.vector4d(pill.liquidPanelX + pill.liquidPad, pill.liquidPanelY + pill.liquidPad, pill.liquidPanelW, pill.liquidPanelH)
        panelRadii: pill.liquidPanelRadii
        layer.enabled: pill.liquidDrawBody
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
    }

    Rectangle {
        id: pillRect

        visible: pill.popupMode
        x: pill.surfaceX
        y: pill.surfaceY
        width: pill.compactWidth + pill.hoverGrowWidth
        height: pill.compactHeight
        color: "transparent"
        clip: true
        radius: Prefs.barPillRadius
        topLeftRadius: pill.joinLeft ? 0 : pill.pillTopRadius
        topRightRadius: pill.joinRight ? 0 : pill.pillTopRadius
        bottomLeftRadius: pill.capped(pill.hangCorners, "bl", pill.joinLeft ? 0 : Prefs.barPillRadius)
        bottomRightRadius: pill.capped(pill.hangCorners, "br", pill.joinRight ? 0 : Prefs.barPillRadius)
        // No QML shadow under external glass: the plugin draws it, and a
        // shadow of the transparent bg would blob around glyphs instead.
        layer.enabled: !pill.externalGlass && !pill.liquidDrawBody
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

        HoverHandler {
            id: pillHover

            enabled: pill.popupMode
        }

        // over the contents, not on this rect: a handler on a parent never hears
        // a press a child MouseArea already took
        Item {
            anchors.fill: parent
            z: 1000

            PointHandler {
                enabled: pill.hoverOpen
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                onActiveChanged: {
                    if (active)
                        pill.hoverOpen = false;

                }
            }

        }

        LiquidGlassBg {
            anchors.fill: parent
            visible: false
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

        // a notched pop-up grows down out of the pill's bottom edge, flush
        width: pill.popupMode ? (pill.anyOpen ? pill.popupWidth : pill.compactWidth + (pill.notchedPopup ? 0 : pill.hoverGrow * 2)) : pill.width + pill.hoverGrow * 2
        height: pill.popupMode ? (pill.anyOpen ? pill.popupHeight : (pill.notchedPopup ? 0 : pill.compactHeight)) : pill.height
        x: pill.popupMode && pill.anyOpen ? pill.popupX : (pill.notchedPopup ? 0 : pill.surfaceX)
        y: pill.popupMode && (pill.anyOpen || pill.notchedPopup) ? pill.compactHeight + (pill.notchedPopup ? 0 : Theme.dp(Prefs.barPopupGap)) : pill.surfaceY
        visible: !pill.popupMode || (pill.notchedPopup ? shell.height > 0.5 : shell.y > 0.5)
        color: "transparent"
        radius: pill.cornerRadius
        // opened in place, the panel hangs from its own stretch of the group: the
        // shared top corners stay square, the bottom ones round off below it
        topLeftRadius: pill.popupMode ? pill.capped(pill.notchedPopup ? pill.hangTops : null, "tl", pill.topRadius) : (pill.joinLeft ? 0 : pill.topRadius)
        topRightRadius: pill.popupMode ? pill.capped(pill.notchedPopup ? pill.hangTops : null, "tr", pill.topRadius) : (pill.joinRight ? 0 : pill.topRadius)
        bottomLeftRadius: pill.popupMode ? pill.cornerRadius : pill.capped(pill.hangSides, "bl", pill.capped(pill.hangCorners, "bl", pill.joinLeft && !pill.hangSides ? 0 : pill.cornerRadius))
        bottomRightRadius: pill.popupMode ? pill.cornerRadius : pill.capped(pill.hangSides, "br", pill.capped(pill.hangCorners, "br", pill.joinRight && !pill.hangSides ? 0 : pill.cornerRadius))
        clip: true
        // Panel path uses the layered shell; compact islands have no panel
        // layer, so force the same shadow here (skipped during the liquid
        // morph, whose LiquidShape already carries a shadow, and under
        // external glass, where the plugin draws it).
        layer.enabled: pill.surfaceLayered || (!pill.popupMode && !pill.anyOpen && !pill.liquidDrawBody && !pill.externalGlass)
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
            visible: false
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

                // on the full bar, hover lifts the module's own island out of
                // the strip
                Rectangle {
                    readonly property real inset: Theme.dp(4)

                    y: inset
                    width: parent.width
                    height: parent.height - inset * 2
                    visible: Prefs.barFull && opacity > 0
                    radius: height / 2
                    color: Theme.alpha(Theme.surfaceHigh, Theme.bg.a)
                    opacity: pill.compactHovered && !pill.anyOpen ? 1 : 0

                    Behavior on opacity {
                        NumberAnimation {
                            duration: pill.hoverGrowDuration
                            easing.type: Easing.OutCubic
                        }

                    }

                }

                // a joined pill doesn't grow on hover, so its stretch of the
                // group lights up
                Rectangle {
                    anchors.fill: parent
                    visible: pill.joined && opacity > 0
                    color: Theme.text
                    opacity: pill.compactHovered && !pill.anyOpen ? Theme.stateHover : 0
                    topLeftRadius: compactFace.parent ? compactFace.parent.topLeftRadius : 0
                    topRightRadius: compactFace.parent ? compactFace.parent.topRightRadius : 0
                    bottomLeftRadius: compactFace.parent ? compactFace.parent.bottomLeftRadius : 0
                    bottomRightRadius: compactFace.parent ? compactFace.parent.bottomRightRadius : 0

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.barMs(150)
                            easing.type: Easing.OutCubic
                        }

                    }

                }

                // the seam between two joined modules, drawn by the right-hand one
                Rectangle {
                    visible: pill.joinLeft && Prefs.barJoinDividers
                    x: 0
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(1, Theme.dp(1))
                    height: Math.round(parent.height * 0.42)
                    radius: width / 2
                    color: Theme.alpha(Theme.text, 0.14)
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: pill.compactInteractive
                    hoverEnabled: pill.compactInteractive
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onEntered: pill.compactHovered = true
                    onExited: pill.compactHovered = false
                    onClicked: (mouse) => {
                        // a right click opens this module's card in Settings
                        if (mouse.button === Qt.RightButton) {
                            const id = pill.moduleId();
                            if (id !== "")
                                Prefs.openBarModule(id);

                            return ;
                        }
                        // a second click shuts a clicked-open pop-up; a hover-opened one stays, now clicked open
                        if (pill.popupMode && pill.expanded && !pill.hoverOpen) {
                            pill.expanded = false;
                            return ;
                        }
                        pill.hoverOpen = false;
                        pill.noteLiquidOrigin(mouse.x, mouse.y, compactFace);
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
                id: panelGate
                anchors.fill: parent
                // Holds the content back until the liquid body has almost
                // reached its final silhouette (see liquidPanelReveal).
                opacity: pill.liquidPanelReveal
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

        // handlers on the surface itself, so hovering the panel's own contents
        // still counts as hovering the pill
        HoverHandler {
            id: shellHover
        }

        // a passive grab, so the panel's buttons and drags keep working. On an
        // item stacked over the contents, not on the shell: a handler on a parent
        // never hears a press a child MouseArea already took (a right-click on a
        // tray item, say), and the panel folded away under the tray's menu
        Item {
            anchors.fill: parent
            z: 1000

            PointHandler {
                enabled: pill.hoverOpen
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                onActiveChanged: {
                    if (active)
                        pill.hoverOpen = false;

                }
            }

        }

        Behavior on x {
            enabled: pill.popupMode

            NumberAnimation {
                duration: pill.popupMorphDuration
                easing.type: Easing.Bezier
                easing.bezierCurve: pill.popupMorphCurve
            }

        }

        Behavior on y {
            enabled: pill.popupMode

            NumberAnimation {
                duration: pill.popupMorphDuration
                easing.type: Easing.Bezier
                easing.bezierCurve: pill.popupMorphCurve
            }

        }

        Behavior on width {
            enabled: pill.popupMode

            NumberAnimation {
                duration: pill.popupMorphDuration
                easing.type: Easing.Bezier
                easing.bezierCurve: pill.popupMorphCurve
            }

        }

        Behavior on height {
            enabled: pill.popupMode

            NumberAnimation {
                duration: pill.popupMorphDuration
                easing.type: Easing.Bezier
                easing.bezierCurve: pill.popupMorphCurve
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

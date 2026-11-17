import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs
import qs.lucidui
import "../lucidbar" as LucidBar
import "../squircle"

// One transparent, always-mapped overlay per output.  Keeping the surface
// mapped lets the upper-case path take focus before the repeat and lets the
// lower-case card appear without a map round-trip.
PanelWindow {
    id: picker

    required property var modelData

    screen: picker.modelData
    readonly property bool mine: Accent.open && picker.screen !== null && Accent.screenName === picker.screen.name
    readonly property bool shown: picker.mine && !Accent.closing
    readonly property string ns: "quickshell"

    // where the card rests: above the dock when one is out
    readonly property real bottomBase: Theme.dp(96) + ((Prefs.dockEnabled && (!Prefs.dockAutoHide || Prefs.dockDynamicHide)) ? Theme.dp(Prefs.dockIconSize + 20) + Prefs.effectiveDockBottomMargin + Prefs.shellGap : 0)

    // The system repeat rate here is 125 Hz.  25 ms lets a held arrow/Tab
    // move at roughly the keyboard's own pace instead of feeling throttled.
    property double lastStepMs: 0

    function nav(delta, autoRepeat) {
        const now = Date.now();
        if (autoRepeat && now - picker.lastStepMs < 25)
            return ;

        picker.lastStepMs = now;
        Accent.step(delta);
    }

    color: "transparent"
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: picker.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    WlrLayershell.namespace: picker.ns
    // remapped with the rest of the shell when displays change
    visible: Monitors.surfacesUp

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    // the whole output catches the click that dismisses, so the pointer cannot
    // reach anything behind the picker by accident
    mask: Region {
        x: 0
        y: 0
        width: picker.shown ? picker.width : 0
        height: picker.shown ? picker.height : 0
    }

    // click anywhere outside the card to leave the base letter alone
    MouseArea {
        anchors.fill: parent
        enabled: picker.shown
        onClicked: Accent.dismiss()
    }

    Item {
        id: stage

        anchors.fill: parent
        focus: picker.shown
        Keys.onPressed: (e) => {
            if (!Accent.open)
                return ;

            const n = Accent.items.length;
            switch (e.key) {
            case Qt.Key_Escape:
                Accent.dismiss();
                e.accepted = true;
                break;
            case Qt.Key_Tab:
                picker.nav((e.modifiers & Qt.ShiftModifier) ? -1 : 1, e.isAutoRepeat);
                e.accepted = true;
                break;
            case Qt.Key_Backtab:
                picker.nav(-1, e.isAutoRepeat);
                e.accepted = true;
                break;
            case Qt.Key_Right:
            case Qt.Key_Down:
                picker.nav(1, e.isAutoRepeat);
                e.accepted = true;
                break;
            case Qt.Key_Left:
            case Qt.Key_Up:
                picker.nav(-1, e.isAutoRepeat);
                e.accepted = true;
                break;
            case Qt.Key_Return:
            case Qt.Key_Enter:
                Accent.choose(Accent.selected);
                e.accepted = true;
                break;
            default:
                // 1..9 jump straight to a spelling
                if (n > 0 && e.key >= Qt.Key_1 && e.key <= Qt.Key_9) {
                    const i = e.key - Qt.Key_1;
                    if (i < n)
                        Accent.choose(i);
                    e.accepted = true;
                }
                break;
            }
        }

    }

    // The painted card, including its scale and rise.  The compositor glass
    // is published from this rect so it tracks the animation exactly.
    Region {
        id: painted

        readonly property real px: card.x + card.width * (1 - card.scale) / 2
        readonly property real py: card.y + card.height * (1 - card.scale) / 2
        readonly property real pw: card.width * card.scale
        readonly property real ph: card.height * card.scale

        x: Math.ceil(painted.px - 0.002)
        y: Math.ceil(painted.py - 0.002)
        width: card.visible ? Math.max(0, Math.floor(painted.px + painted.pw + 0.002) - Math.ceil(painted.px - 0.002)) : 0
        height: card.visible ? Math.max(0, Math.floor(painted.py + painted.ph + 0.002) - Math.ceil(painted.py - 0.002)) : 0
        radius: Math.round(card.radius * card.scale)
    }

    LucidBar.GlassLayout {
        name: "accent"
        surfaceNamespace: picker.ns
        targetScreen: picker.screen
        surfaceW: picker.width
        surfaceH: picker.height
        // Publish from the first entrance frame, not once opacity is already
        // 12% in.  With scale/rise/width fixed on glass the pill geometry is
        // constant, so the bridge writes once instead of on every frame.
        coalesceMs: 8
        pills: (picker.mine && (picker.shown || card.opacity > 0.12)) ? [{
            x: painted.px,
            y: painted.py,
            w: painted.pw,
            h: painted.ph,
            r: [card.radius * card.scale, card.radius * card.scale, card.radius * card.scale, card.radius * card.scale],
            // a true stadium pill, like the OSD and the bar
            sq: 0
        }] : []
    }

    SquircleRect {
        id: card

        readonly property int pad: Theme.dp(10)
        readonly property int chip: Theme.dp(46)
        readonly property int gap: Theme.dp(4)
        readonly property real wantedW: Accent.items.length * card.chip + Math.max(0, Accent.items.length - 1) * card.gap + card.pad * 2
        readonly property real maxW: Math.max(Theme.dp(180), Math.min(picker.width - Theme.dp(48), Theme.dp(1000)))

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: picker.bottomBase + (Prefs.liquidGlassEnabled ? 0 : (picker.shown ? 0 : Theme.dp(18)))
        width: Math.min(card.maxW, card.wantedW)
        height: card.chip + card.pad * 2
        radius: height / 2
        // deliberately circular: radius == height/2 must draw a true stadium
        smoothing: 0
        // with the compositor glass on, the fill is the plugin's; without it,
        // this is the solid m3 fallback
        fillColor: Prefs.liquidGlassEnabled ? "transparent" : Theme.bg
        opacity: picker.shown ? 1 : 0
        // Scaling or rising a glass pill re-renders the compositor blur every
        // frame.  On glass, keep the geometry fixed and fade the content.
        scale: Prefs.liquidGlassEnabled ? 1 : (picker.shown ? 1 : 0.92)
        // visible from the first entrance frame so the card's shader/content is
        // initialized before the fade starts, not halfway through it
        visible: picker.mine || opacity > 0.12

        // only the solid fallback gets a QML shadow: around glyphs on glass,
        // an offscreen shadow layer blobs
        layer.enabled: !Prefs.liquidGlassEnabled
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowBlur: Theme.hyprShadowBlur
            blurMax: Theme.hyprShadowBlurMax
            shadowColor: Theme.cardShadow
            shadowHorizontalOffset: Theme.hyprShadowOffsetX
            shadowVerticalOffset: Theme.hyprShadowOffsetY
            shadowScale: Theme.hyprShadowScale
            autoPaddingEnabled: true
        }

        // swallow clicks on the card's own padding; the chips handle theirs
        MouseArea {
            anchors.fill: parent
            onClicked: {
            }
        }

        ListView {
            id: list

            anchors.fill: parent
            anchors.margins: card.pad
            orientation: ListView.Horizontal
            model: Accent.items
            spacing: card.gap
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: true
            cacheBuffer: Theme.dp(120)
            // the selected chip is always reachable with Tab, even when the
            // list is wider than the card
            onCountChanged: {
                if (list.count > 0)
                    Qt.callLater(() => list.positionViewAtIndex(Accent.selected, ListView.Center));
            }

            delegate: Item {
                id: slot

                required property int index
                required property string modelData

                readonly property bool selected: index === Accent.selected
                readonly property bool hovered: hover.containsMouse

                width: card.chip
                height: card.chip
                scale: slot.selected ? 1 : 0.88

                Behavior on scale {
                    NumberAnimation {
                        duration: Theme.durQuick
                        easing.type: Easing.OutBack
                        easing.overshoot: Theme.emphasizedOvershoot
                    }

                }

                SquircleRect {
                    anchors.fill: parent
                    radius: width / 2
                    smoothing: 0
                    fillColor: slot.selected ? Theme.primary : (slot.hovered ? Theme.alpha(Theme.text, Theme.stateHover) : "transparent")

                    Behavior on fillColor {
                        ColorAnimation {
                            duration: Theme.durShort
                        }

                    }

                }

                LText {
                    anchors.centerIn: parent
                    role: "titleLarge"
                    weight: 520
                    text: slot.modelData
                    color: slot.selected ? Theme.fgPrimary : Theme.text

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.durShort
                        }

                    }

                }

                MouseArea {
                    id: hover

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Accent.choose(slot.index)
                }

            }

        }

        // changing the number of spellings animates the capsule when the solid
        // fallback is in use; under glass the final width is snapped so the
        // glass shape never changes during the fade
        Behavior on width {
            enabled: card.visible && !Prefs.liquidGlassEnabled

            NumberAnimation {
                duration: Theme.durMedium
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.easeEmphasizedDecel
            }

        }

        Behavior on opacity {
            NumberAnimation {
                id: cardFade

                duration: picker.shown ? Theme.durEnter : Theme.durExit
                easing.type: Easing.Bezier
                easing.bezierCurve: picker.shown ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel
            }

        }

        Behavior on scale {
            NumberAnimation {
                id: cardPop

                duration: picker.shown ? Theme.durEnter : Theme.durExit
                easing.type: picker.shown ? Easing.OutBack : Easing.Bezier
                easing.overshoot: Theme.emphasizedOvershoot
                easing.bezierCurve: picker.shown ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel
            }

        }

        Behavior on anchors.bottomMargin {
            NumberAnimation {
                id: cardRise

                duration: picker.shown ? Theme.durEnter : Theme.durExit
                easing.type: Easing.Bezier
                easing.bezierCurve: picker.shown ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel
            }

        }

    }

    // Enter and exit use the same pair of curves as the shell's OSD.  Focus is
    // taken only once the card is actually going up; the surface has been
    // mapped all along, so this lands before the compositor repeats the key.
    onShownChanged: {
        if (picker.shown)
            Qt.callLater(() => {
                stage.forceActiveFocus();
                if (list.count > 0)
                    list.positionViewAtIndex(Accent.selected, ListView.Center);
            });
    }

    Connections {
        target: Accent

        function onSelectedChanged() {
            if (picker.shown && list.count > 0)
                list.positionViewAtIndex(Accent.selected, ListView.Center);

        }

    }

}

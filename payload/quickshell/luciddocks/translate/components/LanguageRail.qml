import QtQuick
import "squircle"

// The target-language picker. Focus is deliberate: Arrow Down in the composer
// or a click on a chip activates it. Arrow Down keeps the current language and
// gives its chip a small expressive shape pulse. From then on Tab/Shift+Tab
// cycle the languages. Up goes back to the launcher tabs; Return goes back to
// the composer (standalone, both go to the composer).
FocusScope {
    id: rail

    property var languages: []
    property string current: "fr"
    // The standalone widget keeps its own size; the launcher passes the Lucid
    // type-role size so the chips sit one step below the launcher mode labels.
    property real labelSize: Theme.fs(13)
    signal selected(string code)
    signal leaveRequested(bool backward)
    signal engaged()
    signal pasteImageRequested()
    signal textTyped(string text)

    implicitHeight: Theme.dp(34)
    // Focus is deliberate: Arrow Down in the composer or a click on a chip.
    // Tab does not put focus here on its own.
    activeFocusOnTab: false
    readonly property real contentWidth: row.implicitWidth

    function indexOf(code) {
        for (var i = 0; i < rail.languages.length; i++) {
            if (rail.languages[i].code === code)
                return i;
        }
        return 0;
    }

    function cycle(delta) {
        if (rail.languages.length === 0)
            return;

        var i = rail.indexOf(rail.current);
        var next = (i + delta + rail.languages.length) % rail.languages.length;
        rail.selected(rail.languages[next].code);
    }

    function activate() {
        rail.forceActiveFocus();
        rail.engaged();
    }

    Keys.onLeftPressed: rail.cycle(-1)
    Keys.onRightPressed: rail.cycle(1)
    // Down is feedback only: the current chip pulses, the choice stays put.
    Keys.onDownPressed: rail.engaged()
    Keys.onPressed: (event) => {
        if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_V) {
            event.accepted = true;
            rail.pasteImageRequested();
            return;
        }
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab || event.key === Qt.Key_Up || event.key === Qt.Key_Down || event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Escape)
            return;
        if ((event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) !== 0)
            return;
        if (event.text !== "" && event.text.charCodeAt(0) >= 32) {
            event.accepted = true;
            rail.textTyped(event.text);
        }
    }
    // Once the row is active, Tab/Shift+Tab belong to it. It does not capture
    // them before Arrow Down or a click has put focus here.
    Keys.onTabPressed: (event) => rail.cycle((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
    Keys.onBacktabPressed: rail.cycle(-1)
    Keys.onUpPressed: rail.leaveRequested(true)
    Keys.onReturnPressed: rail.leaveRequested(false)
    Keys.onEnterPressed: rail.leaveRequested(false)

    Row {
        id: row

        anchors.fill: parent
        spacing: Theme.dp(4)

        Repeater {
            model: rail.languages

            delegate: SquircleRect {
                id: chip

                required property var modelData
                readonly property bool on: rail.current === chip.modelData.code
                readonly property bool pointed: mouse.containsMouse
                readonly property bool ring: rail.activeFocus && chip.on
                property real pulse: 1

                width: chipLabel.implicitWidth + Theme.dp(16)
                height: rail.height
                radius: Theme.pill(height)
                smoothing: Theme.squircleF
                fillColor: chip.on ? Theme.chipSelected : (chip.pointed ? Theme.surfaceHighest : Theme.chip)
                // Filled chips only: the squircle border shader fragments
                // along the pill's straight top/bottom edges at this height.
                // The selected fill and the small focus scale carry the state.
                scale: mouse.pressed ? 0.96 : (chip.ring ? 1.025 : 1)
                // A spatial pulse on the selected chip, not a selection change.
                // The press scale above still handles the pointer separately.
                transform: Scale {
                    origin.x: chip.width / 2
                    origin.y: chip.height / 2
                    xScale: chip.pulse
                    yScale: chip.pulse
                }

                Connections {
                    target: rail

                    function onEngaged() {
                        if (chip.on)
                            pulseAnim.restart();
                    }
                }

                SequentialAnimation {
                    id: pulseAnim

                    NumberAnimation {
                        target: chip
                        property: "pulse"
                        from: 1
                        to: 1.06
                        duration: Theme.ms(140)
                        easing.type: Easing.Bezier
                        easing.bezierCurve: Theme.curveEmphasized
                    }

                    NumberAnimation {
                        target: chip
                        property: "pulse"
                        to: 1
                        duration: Theme.ms(320)
                        easing.type: Easing.Bezier
                        easing.bezierCurve: Theme.curveSpatial
                    }
                }

                Behavior on fillColor {
                    ColorAnimation {
                        duration: Theme.ms(180)
                        easing.type: Easing.Bezier
                        easing.bezierCurve: Theme.curveStandard
                    }

                }

                Behavior on scale {
                    NumberAnimation {
                        duration: Theme.ms(220)
                        easing.type: Easing.OutBack
                        easing.overshoot: 0.7
                    }

                }

                Text {
                    id: chipLabel

                    anchors.centerIn: parent
                    text: chip.modelData.name
                    color: chip.on ? Theme.chipSelectedText : Theme.chipText
                    font.family: Theme.scriptFontFamily
                    font.pixelSize: rail.labelSize
                    font.weight: chip.on ? Font.DemiBold : Font.Medium

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.ms(160)
                        }

                    }

                }

                MouseArea {
                    id: mouse

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        rail.forceActiveFocus();
                        rail.selected(chip.modelData.code);
                    }
                }

            }

        }

    }

}

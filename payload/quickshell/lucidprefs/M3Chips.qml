import QtQuick
import qs

// m3 filter chips, wrapping. options are { key, label, note } and the track
// colours match M3Segmented so a page can mix the two
Flow {
    id: chips

    property var options: []
    property var current: ""
    // membership rather than choice: every key in selectedKeys reads as picked
    property bool multi: false
    property var selectedKeys: []
    property bool enabled: true
    // a lone chip is worth showing as the current value even when there is
    // nothing else to pick, so this gates the click without dimming it
    property bool interactive: true

    signal chosen(var key)

    Accessible.role: Accessible.Grouping
    spacing: Theme.dp(8)

    Repeater {
        model: chips.options

        Rectangle {
            id: chip

            required property var modelData
            readonly property bool selected: chips.multi ? chips.selectedKeys.indexOf(chip.modelData.key) >= 0 : chips.current === chip.modelData.key

            width: label.implicitWidth + Theme.dp(30)
            height: Theme.dp(36)
            radius: Theme.pill(height)
            color: chip.selected ? Theme.accentContainer : Theme.bgSunken
            opacity: chips.enabled ? 1 : 0.38

            activeFocusOnTab: chips.enabled && chips.interactive
            Accessible.role: chips.multi ? Accessible.CheckBox : Accessible.RadioButton
            Accessible.name: Tr.t(chip.modelData.label || chip.modelData.key)
            Accessible.checkable: true
            Accessible.checked: chip.selected
            Accessible.selected: chip.selected
            Accessible.focusable: chips.enabled && chips.interactive
            Accessible.focused: chip.activeFocus
            Accessible.onPressAction: chips.chosen(chip.modelData.key)
            Keys.onSpacePressed: chips.chosen(chip.modelData.key)
            Keys.onReturnPressed: chips.chosen(chip.modelData.key)
            Keys.onEnterPressed: chips.chosen(chip.modelData.key)

            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                color: Theme.text
                opacity: !chips.enabled ? 0 : (area.pressed ? Theme.statePressed : (area.containsMouse ? Theme.stateHover : 0))

                Behavior on opacity {
                    NumberAnimation {
                        duration: Theme.durQuick
                    }

                }

            }

            Text {
                id: label

                anchors.centerIn: parent
                text: Tr.t(chip.modelData.label)
                color: chip.selected ? Theme.fgAccentContainer : Theme.subtext
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontLabelLg
                font.variableAxes: Theme.axes(Theme.fontLabelLg, 420, 0)
                font.weight: chip.selected ? Font.DemiBold : Font.Medium
                Accessible.ignored: true
            }

            MouseArea {
                id: area

                anchors.fill: parent
                hoverEnabled: chips.enabled && chips.interactive
                enabled: chips.enabled && chips.interactive
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    chip.forceActiveFocus();
                    chips.chosen(chip.modelData.key);
                }
            }

            Rectangle {
                anchors.fill: parent
                anchors.margins: -Theme.dp(2)
                radius: parent.radius + Theme.dp(2)
                color: "transparent"
                border.width: chip.activeFocus && chips.enabled ? Theme.dp(2) : 0
                border.color: Theme.accent
                visible: border.width > 0 && Prefs.a11yFocusRing
                z: 10
            }

            Behavior on color {
                ColorAnimation {
                    duration: Theme.durShort
                }

            }

        }

    }

}

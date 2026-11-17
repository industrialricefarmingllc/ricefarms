import QtQuick
import QtQuick.Layouts
import qs
import qs.lucidui

// Reaction chips plus a picker, shared by post cards and comment rows. The
// host owns the source call; this component only reads target.reactions and
// asks the host to toggle/add.
Flow {
    id: root

    property var target: ({})
    property var host: null
    property bool compact: true
    property bool showAddButton: true

    readonly property var reactions: (root.target && root.target.reactions) ? root.target.reactions : []
    readonly property bool canReact: !!(root.target && root.target.capabilities && root.target.capabilities.react)
    readonly property int chipSize: Theme.dp(root.compact ? 22 : 24)
    readonly property var reactors: {
        var ref = root.target && root.target.ref ? root.target.ref : ({});
        var out = Object.assign({}, ref.reaction_users || {});
        var groups = ref.segment_reaction_users;
        if (Array.isArray(groups)) {
            for (var i = 0; i < groups.length; i++) {
                var group = groups[i] || ({});
                for (var key in group) {
                    if (!out[key])
                        out[key] = group[key];
                }
            }
        }
        return out;
    }

    spacing: Theme.dp(5)
    visible: root.reactions.length > 0 || root.canReact

    Rectangle {
        id: addButton

        width: root.chipSize
        height: root.chipSize
        radius: height / 2
        visible: root.canReact && root.showAddButton
        color: addArea.containsMouse ? Theme.surfaceHighest : "transparent"
        border.width: 1
        border.color: Theme.alpha(root.host ? root.host.ink : Theme.text, 0.15)

        Icon {
            anchors.centerIn: parent
            name: "mood"
            size: Math.round(root.chipSize * 0.62)
            color: root.host ? root.host.inkDim : Theme.subtext
        }

        MouseArea {
            id: addArea

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (root.host && root.host.requestEmojiCatalog)
                    root.host.requestEmojiCatalog();
                if (pickerLoader.item)
                    pickerLoader.item.open();
            }
        }

    }

    Repeater {
        model: root.reactions

        Rectangle {
            id: chip

            required property var modelData

            width: chipRow.implicitWidth + Theme.dp(10)
            height: root.chipSize
            radius: height / 2
            color: modelData.me === true ? Theme.primaryContainer : Theme.surfaceHigh
            border.width: 1
            border.color: Theme.alpha(root.host ? root.host.ink : Theme.text, 0.07)

            RowLayout {
                id: chipRow

                anchors.centerIn: parent
                spacing: Theme.dp(3)

                Item {
                    width: stack.count > 0 ? 13 + (stack.count - 1) * 8 : 0
                    height: root.chipSize
                    Layout.preferredWidth: width
                    Layout.preferredHeight: height
                    visible: stack.count > 0

                    readonly property var people: {
                        var key = String(chip.modelData.id || chip.modelData.emoji || chip.modelData.name || "");
                        var list = root.reactors[key] || [];
                        return list.slice(0, 3);
                    }

                    Repeater {
                        id: stack

                        model: parent.people

                        Rectangle {
                            required property var modelData
                            required property int index

                            x: index * 8
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.round(root.chipSize * 0.66)
                            height: width
                            radius: width / 2
                            color: Theme.surfaceHighest
                            border.width: 1
                            border.color: Theme.alpha(root.host ? root.host.ink : Theme.text, 0.16)

                            Image {
                                anchors.fill: parent
                                source: String(modelData.avatar || "")
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                                visible: source !== ""
                            }

                        }

                    }

                }

                Twemoji {
                    size: Math.round(root.chipSize * 0.66)
                    emoji: String(chip.modelData.emoji || "")
                    imageSource: String(chip.modelData.image || "")
                    animated: chip.modelData.animated === true
                    fallbackColor: root.host ? root.host.ink : Theme.text
                }

                LText {
                    role: "labelSmall"
                    tabular: true
                    text: String(chip.modelData.count || 0)
                    color: chip.modelData.me === true
                        ? Theme.fgPrimaryContainer
                        : (root.host ? root.host.inkDim : Theme.subtext)
                }

            }

            MouseArea {
                anchors.fill: parent
                cursorShape: root.canReact ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    if (root.canReact && root.host && root.host.toggleReaction)
                        root.host.toggleReaction(root.target, chip.modelData);
                }
            }

        }

    }

    Loader {
        id: pickerLoader

        active: root.showAddButton
        sourceComponent: ReactionPicker {
            parent: addButton
            x: Math.round(addButton.width - width)
            y: addButton.height + Theme.dp(4)
            catalog: root.host ? root.host.emojiCatalog : []
            usage: root.host ? root.host.emojiUsageCounts : ({})
            onPicked: (entry) => {
                if (root.host && root.host.addReaction)
                    root.host.addReaction(root.target, entry);
            }
        }
    }

}

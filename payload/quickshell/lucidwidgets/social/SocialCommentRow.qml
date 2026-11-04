import QtQuick
import QtQuick.Layouts
import qs
import qs.lucidui
import "../../squircle"

// A comment in the opened thread.  Nested replies step in, and an indentation
// rail keeps a long chain readable without drawing boxes around every reply.
Item {
    id: row

    required property var comment
    required property var host
    property bool compact: false
    property int depth: Math.min(4, Math.max(0, intOf(comment.depth)))
    property bool hasChildren: false
    property int childCount: 0
    property bool collapsed: false
    property string parentName: ""

    signal replyRequested()
    signal likeClicked()
    signal collapseToggled()

    readonly property var caps: row.comment.capabilities || ({})
    readonly property var stats: row.comment.stats || ({})
    readonly property int likeCount: row.stats.likes !== null && row.stats.likes !== undefined ? Number(row.stats.likes) : -1
    readonly property bool liked: row.comment.liked === true

    implicitHeight: content.implicitHeight + Theme.dp(row.compact ? 8 : 14)
    height: implicitHeight
    x: Theme.dp(12) + row.depth * Theme.dp(15)
    width: parent ? parent.width - x - Theme.dp(12) : implicitWidth

    function intOf(value) {
        var number = Number(value || 0);
        return isNaN(number) ? 0 : number;
    }

    // A thread rail: a continuous vertical line from the parent, with a short
    // elbow into this comment's avatar. It is the visual grammar Twitter uses
    // for a reply chain.
    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.leftMargin: -Theme.dp(11)
        width: 1
        color: row.depth > 0 ? Theme.alpha(row.host ? row.host.ink : Theme.text, 0.22) : "transparent"
    }

    Rectangle {
        anchors.left: parent.left
        anchors.leftMargin: -Theme.dp(11)
        anchors.top: parent.top
        anchors.topMargin: Theme.dp(12)
        width: Theme.dp(10)
        height: 1
        color: row.depth > 0 ? Theme.alpha(row.host ? row.host.ink : Theme.text, 0.22) : "transparent"
    }

    ColumnLayout {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: Theme.dp(2)
        anchors.rightMargin: Theme.dp(2)
        anchors.topMargin: Theme.dp(row.compact ? 4 : 7)
        spacing: Theme.dp(2)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(7)

            SocialAvatar {
                Layout.alignment: Qt.AlignTop
                author: row.comment.author || ({})
                size: Theme.dp(row.compact ? 24 : 28)
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(6)

                    LText {
                        role: "labelLarge"
                        text: (row.comment.author || {}).display_name || (row.comment.author || {}).handle || "Someone"
                        color: row.host ? row.host.ink : Theme.text
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }

                    Item {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: collapseRow.implicitWidth + Theme.dp(6)
                        implicitHeight: Theme.dp(22)
                        visible: row.hasChildren

                        Row {
                            id: collapseRow

                            anchors.centerIn: parent
                            spacing: Theme.dp(2)

                            Icon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: "expand_more"
                                size: Theme.dp(13)
                                color: Theme.primary
                                rotation: row.collapsed ? -90 : 0

                                Behavior on rotation {
                                    NumberAnimation {
                                        duration: Theme.durFastSpatial
                                        easing.type: Easing.Bezier
                                        easing.bezierCurve: Theme.curveFastSpatial
                                    }

                                }

                            }

                            LText {
                                anchors.verticalCenter: parent.verticalCenter
                                role: "labelSmall"
                                text: row.collapsed ? String(row.childCount) : "hide"
                                color: Theme.primary
                            }

                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: row.collapseToggled()
                        }

                    }

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        width: Theme.dp(16)
                        height: Theme.dp(16)
                        radius: width / 2
                        color: Theme.tertiaryContainer
                        visible: row.comment.pending === true

                        Icon {
                            anchors.centerIn: parent
                            name: "schedule"
                            size: Theme.dp(11)
                            color: Theme.tertiary
                        }

                    }

                    LText {
                        Layout.alignment: Qt.AlignVCenter
                        role: "labelSmall"
                        text: row.comment.grouped ? "grouped" : ""
                        color: row.host ? row.host.inkFaint : Theme.subtextDim
                        visible: text !== ""
                    }

                    LText {
                        Layout.alignment: Qt.AlignVCenter
                        role: "labelSmall"
                        text: row.host ? row.host.ago(row.comment.created_at) : ""
                        color: row.host ? row.host.inkFaint : Theme.subtextDim
                    }

                }

                LText {
                    Layout.fillWidth: true
                    visible: row.parentName !== ""
                    role: "labelSmall"
                    text: "Replying to " + row.parentName
                    color: Theme.alpha(row.host ? row.host.ink : Theme.text, 0.55)
                    elide: Text.ElideRight
                }

                LText {
                    Layout.fillWidth: true
                    role: row.compact ? "bodySmall" : "bodyMedium"
                    text: row.comment.body || ""
                    color: row.host ? row.host.inkDim : Theme.subtext
                    wrapMode: Text.Wrap
                    maximumLineCount: row.compact ? 3 : 1000
                    elide: Text.ElideRight
                }

            }

        }

        Column {
            id: commentMedia

            Layout.fillWidth: true
            Layout.leftMargin: Theme.dp(row.compact ? 31 : 35)
            spacing: Theme.dp(6)

            Repeater {
                model: row.comment.media || []

                SocialMedia {
                    required property var modelData

                    width: commentMedia.width
                    height: implicitHeight
                    value: modelData
                    host: row.host
                    maxHeight: Theme.dp(260)
                    ink: row.host ? row.host.ink : Theme.text
                }

            }

        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.dp(row.compact ? 31 : 35)
            spacing: Theme.dp(8)

            SocialLikeButton {
                visible: row.caps.like === true || row.likeCount >= 0
                liked: row.liked
                count: row.likeCount
                enabled: row.caps.like === true
                ink: row.host ? row.host.inkDim : Theme.subtext
                onClicked: row.likeClicked()
            }

            Item {
                implicitWidth: replyRow.implicitWidth + Theme.dp(10)
                implicitHeight: Theme.dp(26)

                Row {
                    id: replyRow

                    anchors.centerIn: parent
                    spacing: Theme.dp(4)

                    Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chat"
                        size: Theme.dp(15)
                        color: row.host ? row.host.inkFaint : Theme.subtextDim
                    }

                    LText {
                        anchors.verticalCenter: parent.verticalCenter
                        role: "labelSmall"
                        text: "Reply"
                        color: row.host ? row.host.inkFaint : Theme.subtextDim
                    }

                }

                StateLayer {
                    radius: Theme.pill(height)
                    tint: row.host ? row.host.inkDim : Theme.subtext
                    onClicked: row.replyRequested()
                }

            }

            Item {
                Layout.fillWidth: true
            }

        }

    }

}

import QtQuick
import QtQuick.Layouts
import qs
import qs.lucidui

// The reply composer.  It never talks to a source directly: the widget hands
// the text to lucid-social, which either uses the source's own write API or the
// configured Lucid comment relay.
Item {
    id: composer

    property alias text: field.text
    property var host: null
    property string replyName: ""
    property bool busy: false
    property string placeholder: "Add a comment…"
    property color ink: Theme.text

    signal send(string body)
    signal cancelReply()

    implicitHeight: body.implicitHeight + Theme.dp(16)

    function focus() {
        field.input.forceActiveFocus();
    }

    function clear() {
        field.text = "";
    }

    function submit() {
        var value = String(composer.text || "").trim();
        if (value !== "" && !composer.busy)
            composer.send(value);

    }

    ColumnLayout {
        id: body

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Theme.dp(6)

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.dp(30)
            radius: Theme.rad(10)
            color: Theme.primaryContainer
            visible: composer.replyName !== ""

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.dp(10)
                anchors.rightMargin: Theme.dp(4)
                spacing: Theme.dp(4)

                Icon {
                    name: "chat"
                    size: Theme.dp(14)
                    color: Theme.primary
                }

                LText {
                    Layout.fillWidth: true
                    role: "labelSmall"
                    text: "Replying to " + composer.replyName
                    color: Theme.primary
                    elide: Text.ElideRight
                }

                IconButton {
                    icon: "close"
                    size: "xs"
                    onClicked: composer.cancelReply()
                }

            }

        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(6)

            TextField {
                id: field

                Layout.fillWidth: true
                variant: "search"
                icon: "chat"
                placeholder: composer.replyName !== "" ? ("Reply to " + composer.replyName + "…") : composer.placeholder
                text: ""
                onAccepted: composer.submit()

                input.onActiveFocusChanged: {
                    if (!composer.host)
                        return ;

                    if (input.activeFocus)
                        composer.host.beginEdit();
                    else
                        composer.host.endEdit();

                }

                input.Keys.onEscapePressed: {
                    if (composer.host)
                        composer.host.endEdit();

                    input.focus = false;
                }
            }

            IconButton {
                icon: "send"
                variant: "filled"
                size: "m"
                enabled: String(field.text || "").trim() !== "" && !composer.busy
                onClicked: composer.submit()
            }

        }

    }

}

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs
import qs.lucidui
import "../../lucidmoji/emojiSearch.js" as EmojiSearch

// The reply composer.  It never talks to a source directly: the widget hands
// the text to lucid-social, which either uses the source's own write API or the
// configured Lucid comment relay.
Item {
    id: composer

    property alias text: field.text
    property var host: null
    property var emojiCatalog: []
    property var emojiUsage: ({})
    property string replyName: ""
    property bool busy: false
    // Inline `:shortcode:` suggestions, ranked by the LucidMoji search.
    property var emojiMatches: []
    property int emojiIndex: 0
    property bool emojiOpen: false
    property int emojiReplaceStart: -1
    property int emojiReplaceEnd: -1
    property string placeholder: "Add a comment…"
    property color ink: Theme.text
    // Local image paths, in paste order. The widget sends them with the body.
    property var attachments: []
    property int maxAttachments: 10
    readonly property string pasteDir: (Quickshell.env("HOME") || "/tmp") + "/.cache/lucid-social/paste"

    signal send(string body, var images)
    signal cancelReply()

    // The rest of the card draws emoji as Twemoji; use the matching font in the
    // plain TextInput so typed/pasted emoji do not fall back to Noto.
    FontLoader {
        id: emojiFont

        source: Qt.resolvedUrl("../../assets/fonts/TwemojiMozilla.ttf")
    }

    implicitHeight: body.implicitHeight + Theme.dp(16)

    function focusInput() {
        field.forceActiveFocus();
    }

    function clear() {
        field.text = "";
    }

    function clearAttachments() {
        composer.attachments = [];
    }

    function setAttachments(values) {
        composer.attachments = (values || []).slice();
    }

    function addDropped(paths) {
        var next = composer.attachments.slice();
        for (var i = 0; i < (paths || []).length; i++) {
            var path = String(paths[i] || "");
            if (path === "" || next.indexOf(path) >= 0)
                continue;
            if (next.length >= composer.maxAttachments)
                break;
            next.push(path);
        }
        if (next.length !== composer.attachments.length)
            composer.attachments = next;
    }

    function removeAttachment(index) {
        var next = composer.attachments.slice();
        if (index >= 0 && index < next.length)
            next.splice(index, 1);

        composer.attachments = next;
    }

    function submit() {
        var value = String(composer.text || "").trim();
        if ((value !== "" || composer.attachments.length > 0) && !composer.busy)
            composer.send(value, composer.attachments);

    }

    function closeEmoji() {
        composer.emojiOpen = false;
        composer.emojiMatches = [];
        composer.emojiIndex = 0;
        composer.emojiReplaceStart = -1;
        composer.emojiReplaceEnd = -1;
    }

    function updateEmojiPicker() {
        var pos = field.cursorPosition;
        var text = String(field.text || "");
        var start = -1;
        for (var i = pos - 1; i >= 0; i--) {
            var ch = text.charAt(i);
            if (ch === ":") {
                start = i;
                break;
            }
            if (ch === " " || ch === "\n" || ch === "\t")
                break;
        }
        if (start < 0 || (start > 0 && !/\s/.test(text.charAt(start - 1)))) {
            composer.closeEmoji();
            return ;
        }
        var end = pos;
        while (end < text.length && !/\s/.test(text.charAt(end)) && text.charAt(end) !== ":")
            end++;
        if (text.charAt(end) === ":")
            end++;
        var raw = text.slice(start + 1, end);
        var query = raw;
        if (query.charAt(query.length - 1) === ":")
            query = query.slice(0, -1);
        if (query === "" || /\s/.test(query) || query.indexOf(":") >= 0
            || !/^[A-Za-z0-9_+\-]+$/.test(query)) {
            composer.closeEmoji();
            return ;
        }
        if (composer.emojiCatalog.length === 0) {
            if (composer.host && composer.host.requestEmojiCatalog)
                composer.host.requestEmojiCatalog();
            composer.closeEmoji();
            return ;
        }
        var found = EmojiSearch.matches(composer.emojiCatalog, query, 18, composer.emojiUsage);
        if (found.length === 0) {
            composer.closeEmoji();
            return ;
        }
        composer.emojiMatches = found;
        composer.emojiReplaceStart = start;
        composer.emojiReplaceEnd = end;
        composer.emojiIndex = 0;
        composer.emojiOpen = true;
    }

    function moveEmoji(delta) {
        if (!composer.emojiOpen || composer.emojiMatches.length === 0)
            return ;
        composer.emojiIndex = Math.max(0, Math.min(composer.emojiMatches.length - 1, composer.emojiIndex + delta));
        emojiList.positionViewAtIndex(composer.emojiIndex, ListView.Contain);
    }

    function pickEmoji(index) {
        if (!composer.emojiOpen || index < 0 || index >= composer.emojiMatches.length)
            return ;
        var entry = composer.emojiMatches[index];
        var glyph = entry.custom === true ? String(entry.copy || "") : String(entry.e || "");
        var start = composer.emojiReplaceStart;
        var end = composer.emojiReplaceEnd;
        if (glyph === "" || start < 0 || end < start) {
            composer.closeEmoji();
            return ;
        }
        if (entry.custom === true) {
            // Keep the CDN URL as its own token so following text cannot be
            // swallowed into the link before the adapter splits it out.
            var text = String(field.text || "");
            if (start > 0 && !/\s/.test(text.charAt(start - 1)))
                glyph = " " + glyph;
            glyph += " ";
        }
        field.remove(start, end);
        field.insert(start, glyph);
        if (entry.u && composer.host && composer.host.recordEmojiUse)
            composer.host.recordEmojiUse(entry.u);
        composer.closeEmoji();
        field.forceActiveFocus();
    }

    onEmojiCatalogChanged: composer.updateEmojiPicker()
    onEmojiUsageChanged: composer.updateEmojiPicker()

    function pasteImage() {
        if (!pasteProc.running && composer.attachments.length < composer.maxAttachments)
            pasteProc.running = true;

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
                    color: "white"
                }

                LText {
                    Layout.fillWidth: true
                    role: "labelSmall"
                    text: Tr.t("Replying to ") + composer.replyName
                    color: "white"
                    elide: Text.ElideRight
                }

                IconButton {
                    icon: "close"
                    size: "xs"
                    tintOverride: "white"
                    onClicked: composer.cancelReply()
                }

            }

        }

        Flow {
            Layout.fillWidth: true
            spacing: Theme.dp(6)
            visible: composer.attachments.length > 0

            Repeater {
                model: composer.attachments

                Item {
                    id: thumbItem

                    required property var modelData
                    required property int index

                    width: Theme.dp(54)
                    height: Theme.dp(54)

                    readonly property bool video: /\.(mp4|webm|mov|mkv|ogv|m4v)$/i.test(String(modelData || ""))

                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.rad(10)
                        color: Theme.surfaceHighest
                        clip: true

                        Image {
                            anchors.fill: parent
                            visible: !thumbItem.video
                            source: thumbItem.video || String(modelData || "") === "" ? "" : "file://" + modelData
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            smooth: true
                            mipmap: true
                        }

                        Icon {
                            anchors.centerIn: parent
                            visible: thumbItem.video
                            name: "movie"
                            size: Theme.dp(20)
                            color: Theme.subtext
                        }

                    }

                    Rectangle {
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.topMargin: Theme.dp(-3)
                        anchors.rightMargin: Theme.dp(-3)
                        width: Theme.dp(20)
                        height: Theme.dp(20)
                        radius: width / 2
                        color: Theme.surfaceHighest
                        border.width: 1
                        border.color: Theme.alpha(Theme.text, 0.12)

                        Icon {
                            anchors.centerIn: parent
                            name: "close"
                            size: Theme.dp(12)
                            color: Theme.subtext
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: composer.removeAttachment(index)
                        }

                    }

                }

            }

        }

        ListView {
            id: emojiList

            Layout.fillWidth: true
            Layout.preferredHeight: composer.emojiOpen
                ? Math.min(Theme.dp(238), Math.max(Theme.dp(38), composer.emojiMatches.length * Theme.dp(34) + Theme.dp(6)))
                : 0
            visible: composer.emojiOpen
            clip: true
            spacing: 0
            model: composer.emojiMatches
            currentIndex: composer.emojiIndex

            delegate: Rectangle {
                id: emojiRow

                required property var modelData
                required property int index

                width: emojiList.width
                height: Theme.dp(34)
                radius: Theme.rad(8)
                color: index === composer.emojiIndex
                    ? Theme.primaryContainer
                    : (emojiMouse.containsMouse ? Theme.surfaceHigh : "transparent")

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.dp(10)
                    anchors.rightMargin: Theme.dp(10)
                    spacing: Theme.dp(8)

                    Item {
                        Layout.preferredWidth: Theme.dp(24)
                        Layout.preferredHeight: Theme.dp(24)

                        LText {
                            anchors.centerIn: parent
                            visible: emojiRow.modelData.custom !== true
                            role: "titleMedium"
                            text: String(emojiRow.modelData.e || "")
                            font.family: emojiFont.status === FontLoader.Ready ? emojiFont.name : Theme.fontFamily
                            color: emojiRow.index === composer.emojiIndex ? Theme.fgPrimaryContainer : Theme.text
                        }

                        AnimatedImage {
                            anchors.fill: parent
                            visible: emojiRow.modelData.custom === true && emojiRow.modelData.animated === true
                            source: visible ? String(emojiRow.modelData.image || "") : ""
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            smooth: true
                            playing: visible
                            loops: AnimatedImage.Infinite
                        }

                        Image {
                            anchors.fill: parent
                            visible: emojiRow.modelData.custom === true && emojiRow.modelData.animated !== true
                            source: visible ? String(emojiRow.modelData.image || "") : ""
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            smooth: true
                            mipmap: true
                        }

                    }

                    LText {
                        Layout.fillWidth: true
                        role: "labelMedium"
                        text: String(emojiRow.modelData.n || "")
                        color: emojiRow.index === composer.emojiIndex ? Theme.fgPrimaryContainer : Theme.subtext
                        elide: Text.ElideRight
                    }

                    LText {
                        role: "labelSmall"
                        text: ":" + String(emojiRow.modelData.n || "").replace(/[^A-Za-z0-9]+/g, "_") + ":"
                        color: emojiRow.index === composer.emojiIndex ? Theme.fgPrimaryContainer : Theme.subtextDim
                        elide: Text.ElideRight
                    }

                }

                MouseArea {
                    id: emojiMouse

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: composer.pickEmoji(emojiRow.index)
                }

            }

        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(6)

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Theme.dp(36)
                radius: Theme.pill(height)
                color: Theme.surfaceHigh
                border.width: field.activeFocus ? 1 : 0
                border.color: Theme.alpha(Theme.primary, 0.55)

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.IBeamCursor
                    onClicked: field.forceActiveFocus()
                }

                TextInput {
                    id: field

                    anchors.left: parent.left
                    anchors.leftMargin: Theme.dp(12)
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.dp(10)
                    anchors.verticalCenter: parent.verticalCenter
                    height: Math.max(Theme.dp(18), font.pixelSize * 1.3)
                    clip: true
                    color: Theme.text
                    selectionColor: Theme.alpha(Theme.primary, 0.35)
                    selectedTextColor: Theme.text
                    font.family: emojiFont.status === FontLoader.Ready ? emojiFont.name : Theme.fontFamily
                    font.pixelSize: Theme.typeSize("bodyMedium")
                    font.variableAxes: Theme.axes(Theme.typeSize("bodyMedium"), 420, 0)
                    onTextChanged: composer.updateEmojiPicker()
                    onCursorPositionChanged: composer.updateEmojiPicker()
                    onAccepted: {
                        if (composer.emojiOpen) {
                            composer.pickEmoji(composer.emojiIndex);
                            return ;
                        }
                        composer.submit();
                    }

                    Keys.onPressed: (event) => {
                        if (composer.emojiOpen) {
                            if (event.key === Qt.Key_Down) {
                                composer.moveEmoji(1);
                                event.accepted = true;
                                return ;
                            }
                            if (event.key === Qt.Key_Up) {
                                composer.moveEmoji(-1);
                                event.accepted = true;
                                return ;
                            }
                            if (event.key === Qt.Key_Tab) {
                                composer.pickEmoji(composer.emojiIndex);
                                event.accepted = true;
                                return ;
                            }
                        }
                        if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_V)
                            composer.pasteImage();

                    }

                    onActiveFocusChanged: {
                        if (!composer.host)
                            return ;

                        if (activeFocus)
                            composer.host.beginEdit();
                        else
                            composer.host.endEdit();

                    }

                    Keys.onEscapePressed: {
                        if (composer.emojiOpen) {
                            composer.closeEmoji();
                            return ;
                        }
                        if (composer.host)
                            composer.host.endEdit();

                        focus = false;
                    }

                    LText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: field.text === ""
                        role: "bodyMedium"
                        text: composer.placeholder
                        color: Theme.subtextDim
                        opacity: 0.8
                    }

                }

            }

            IconButton {
                Layout.alignment: Qt.AlignVCenter
                icon: "send"
                variant: "filled"
                size: "s"
                enabled: (String(field.text || "").trim() !== "" || composer.attachments.length > 0) && !composer.busy
                onClicked: composer.submit()
            }

        }

    }

    Process {
        id: pasteProc

        running: false
        command: [
            "sh", "-c",
            "d=\"$1\"; mkdir -p \"$d\"; t=''; for x in $(wl-paste --list-types 2>/dev/null); do case \"$x\" in image/*) t=\"$x\"; break;; esac; done; [ -n \"$t\" ] || exit 0; ext=\"${t#image/}\"; f=\"$d/paste-$(date +%s%N).${ext%%+*}\"; wl-paste --type \"$t\" > \"$f\" 2>/dev/null && printf '%s' \"$f\"",
            "sh", composer.pasteDir
        ]

        stdout: StdioCollector {
            onStreamFinished: {
                var path = String(this.text || "").trim();
                if (path === "" || composer.attachments.indexOf(path) >= 0)
                    return ;

                if (composer.attachments.length < composer.maxAttachments)
                    composer.attachments = composer.attachments.concat([path]);

            }
        }
    }

}

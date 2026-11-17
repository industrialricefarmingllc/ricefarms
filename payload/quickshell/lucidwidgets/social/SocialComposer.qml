import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs
import qs.lucidui
import "../../lucidmoji/emojiSearch.js" as EmojiSearch
import "../../lucidui/twemoji.js" as Twemoji
import "emoji.js" as SocialEmoji

// The reply composer.  It never talks to a source directly: the widget hands
// the text to lucid-social, which either uses the source's own write API or the
// configured Lucid comment relay.
Item {
    id: composer

    // The plain body that will be sent. The field itself is rich text so a
    // custom emoji can be painted as an image; U+FFFC marks each image and its
    // alt text carries the CDN link the source adapter expects.
    readonly property string text: composer.plainBody()
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
    property string placeholder: Tr.t("Add a comment…")
    property color ink: Theme.text
    // Local image paths, in paste order. The widget sends them with the body.
    property var attachments: []
    property int maxAttachments: 10
    // Where a plain-text fallback paste should land. Ctrl+V is consumed on
    // the field so the clipboard's HTML/thumbnail text cannot also paste.
    property int pasteCursor: -1
    readonly property string pasteDir: (Quickshell.env("HOME") || "/tmp") + "/.cache/lucid-social/paste"
    readonly property string emojiBase: Qt.resolvedUrl("../../assets/twemoji/")
    property bool emojiRewriting: false

    signal send(string body, var images)
    signal cancelReply()

    implicitHeight: body.implicitHeight + Theme.dp(16)

    function focusInput() {
        field.forceActiveFocus();
    }

    function clear() {
        field.text = "";
    }

    function decodeEntities(value) {
        return String(value || "")
            .replace(/&quot;/g, "\"")
            .replace(/&#39;/g, "'")
            .replace(/&lt;/g, "<")
            .replace(/&gt;/g, ">")
            .replace(/&amp;/g, "&");
    }

    function escapeAttr(value) {
        return String(value || "")
            .replace(/&/g, "&amp;")
            .replace(/"/g, "&quot;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;");
    }

    function escapeBody(value) {
        return String(value || "")
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/\n/g, "<br>");
    }

    function emojiSize() {
        return Math.max(14, Math.round(field.font.pixelSize * 1.15));
    }

    function emojiUrl(value) {
        return /^https?:\/\/(?:cdn\.discordapp\.com|media\.discordapp\.net)\/emojis\/\d+\.(?:png|gif|webp)(?:[?#]|$)/i.test(String(value || ""));
    }

    function displayEmojiUrl(value) {
        return String(value || "").replace(/\.webp(?=([?#]|$))/i, ".png");
    }

    function imageCopies() {
        var html = String(field.text || "");
        var out = [];
        var pattern = /<img\b[^>]*>/gi;
        var match;
        while ((match = pattern.exec(html)) !== null) {
            var tag = match[0];
            var alt = /\balt="([^"]*)"/i.exec(tag);
            var src = /\bsrc="([^"]*)"/i.exec(tag);
            var value = alt ? alt[1] : (src ? src[1] : "");
            out.push(composer.decodeEntities(value));
        }
        return out;
    }

    function plainBody() {
        var raw = String(field.getText(0, field.length) || "").replace(/\u2029/g, "\n");
        var images = composer.imageCopies();
        var out = "";
        var imageIndex = 0;
        for (var i = 0; i < raw.length; i++) {
            if (raw.charCodeAt(i) !== 0xFFFC) {
                out += raw.charAt(i);
                continue;
            }
            var url = imageIndex < images.length ? String(images[imageIndex] || "") : "";
            imageIndex++;
            if (url === "")
                continue;
            if (/^https?:\/\//.test(url)) {
                // A custom emoji is sent as its CDN link, with spaces so a
                // Discord client keeps it a standalone token.
                if (out !== "" && !/\s$/.test(out))
                    out += " ";
                out += url;
                if (i + 1 >= raw.length || !/\s/.test(raw.charAt(i + 1)))
                    out += " ";
            } else {
                out += url;
            }
        }
        return out;
    }

    function unicodeEmojiImage(value) {
        var glyph = String(value || "");
        var asset = Twemoji.assetName(glyph);
        if (asset === "")
            return composer.escapeHtml(glyph);
        return '<img src="' + composer.escapeAttr(composer.emojiBase + asset + '.svg')
            + '" alt="' + composer.escapeAttr(glyph)
            + '" height="' + composer.emojiSize() + '" align="middle">';
    }

    function imageForAlt(value) {
        var alt = String(value || "");
        if (/^https?:\/\//.test(alt)) {
            return '<img src="' + composer.escapeAttr(composer.displayEmojiUrl(alt))
                + '" alt="' + composer.escapeAttr(alt) + '" height="' + composer.emojiSize()
                + '" align="middle">';
        }
        return composer.unicodeEmojiImage(alt);
    }

    function isEmojiStart(value, index) {
        var cp = value.codePointAt(index);
        if (cp === 0xFFFC || cp === 0xFE0F || cp === 0x200D || cp === 0x20E3)
            return false;
        if (SocialEmoji.isEmoji(cp))
            return true;
        if (cp !== 0x23 && cp !== 0x2A && (cp < 0x30 || cp > 0x39))
            return false;
        var next = index + SocialEmoji.codePointLength(cp);
        if (value.codePointAt(next) === 0xFE0F)
            next++;
        return value.codePointAt(next) === 0x20E3;
    }

    function emojiEnd(value, index) {
        if (!composer.isEmojiStart(value, index))
            return index + SocialEmoji.codePointLength(value.codePointAt(index));
        var cp = value.codePointAt(index);
        if (cp === 0x23 || cp === 0x2A || (cp >= 0x30 && cp <= 0x39)) {
            var end = index + SocialEmoji.codePointLength(cp);
            if (value.codePointAt(end) === 0xFE0F)
                end++;
            return value.codePointAt(end) === 0x20E3 ? end + 1 : end;
        }
        return SocialEmoji.scanRun(value, index);
    }

    function hasRawEmoji(value) {
        var plain = String(value || "").replace(/\u2029/g, "\n");
        for (var i = 0; i < plain.length;) {
            if (composer.isEmojiStart(plain, i))
                return true;
            i += SocialEmoji.codePointLength(plain.codePointAt(i));
        }
        return false;
    }

    // Rich text paints Unicode emoji as Twemoji SVGs. The picker, a paste or a
    // restored draft can still insert the raw glyph, which TextEdit would draw
    // with the low-resolution system bitmap font. Convert it in place and keep
    // the caret where the writer left it.
    function rebuildEmoji() {
        if (composer.emojiRewriting)
            return ;
        var plain = String(field.getText(0, field.length) || "").replace(/\u2029/g, "\n");
        if (!composer.hasRawEmoji(plain))
            return ;

        var images = composer.imageCopies();
        var imageIndex = 0;
        var html = "";
        var i = 0;
        while (i < plain.length) {
            var cp = plain.codePointAt(i);
            if (cp === 0xFFFC) {
                var alt = imageIndex < images.length ? String(images[imageIndex] || "") : "";
                imageIndex++;
                html += composer.imageForAlt(alt);
                i++;
                continue;
            }
            if (composer.isEmojiStart(plain, i)) {
                var end = composer.emojiEnd(plain, i);
                html += composer.unicodeEmojiImage(plain.slice(i, end));
                i = end;
                continue;
            }
            var length = SocialEmoji.codePointLength(cp);
            html += composer.escapeBody(plain.substr(i, length));
            i += length;
        }

        var oldCursor = field.cursorPosition;
        var newCursor = 0;
        for (var k = 0; k < oldCursor && k < plain.length;) {
            var ahead = plain.codePointAt(k);
            if (ahead === 0xFFFC) {
                newCursor++;
                k++;
            } else if (composer.isEmojiStart(plain, k)) {
                newCursor++;
                k = composer.emojiEnd(plain, k);
            } else {
                var step = SocialEmoji.codePointLength(ahead);
                newCursor += step;
                k += step;
            }
        }

        composer.emojiRewriting = true;
        field.text = html;
        field.cursorPosition = Math.max(0, Math.min(field.length, newCursor));
        composer.emojiRewriting = false;
    }

    function setText(value) {
        var source = String(value || "");
        var out = "";
        var last = 0;
        var pattern = /https?:\/\/(?:cdn\.discordapp\.com|media\.discordapp\.net)\/emojis\/\d+\.(?:png|gif|webp)(?:[^\s<>"']*)?/gi;
        var match;
        while ((match = pattern.exec(source)) !== null) {
            var url = match[0].replace(/[.,;:!?]+$/, "");
            out += composer.escapeBody(source.slice(last, match.index));
            out += composer.imageForAlt(url);
            last = match.index + url.length;
        }
        out += composer.escapeBody(source.slice(last));
        field.text = out;
        field.cursorPosition = field.length;
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
        var text = String(field.getText(0, field.length) || "");
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
        // The picker is a scrollable list. Fetch every match instead of the
        // old 18-row slice so a common query can reach the whole catalogue.
        var found = EmojiSearch.matches(composer.emojiCatalog, query, 0, composer.emojiUsage);
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

    function setEmojiIndex(index) {
        if (!composer.emojiOpen || composer.emojiMatches.length === 0)
            return ;
        composer.emojiIndex = Math.max(0, Math.min(composer.emojiMatches.length - 1, index));
        emojiList.positionViewAtIndex(composer.emojiIndex, ListView.Contain);
    }

    function moveEmoji(delta) {
        composer.setEmojiIndex(composer.emojiIndex + delta);
    }

    function pageEmoji(delta) {
        var row = Math.max(1, Math.round(Theme.dp(34)));
        var rows = Math.max(1, Math.floor(emojiList.height / row));
        composer.setEmojiIndex(composer.emojiIndex + delta * rows);
    }

    function firstEmoji() {
        composer.setEmojiIndex(0);
    }

    function lastEmoji() {
        composer.setEmojiIndex(composer.emojiMatches.length - 1);
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
            var image = String(entry.image || entry.copy || "");
            if (image === "") {
                composer.closeEmoji();
                return ;
            }
            var copy = String(entry.copy || image);
            var label = ":" + String(entry.n || "") + ":";
            glyph = '<img src="' + composer.escapeAttr(image)
                + '" alt="' + composer.escapeAttr(copy)
                + '" title="' + composer.escapeAttr(label)
                + '" height="' + composer.emojiSize() + '" align="middle">';
            // Keep the emoji a standalone token in the sent body so the
            // adapter can emit it as its own message, but paint it inline.
            var text = String(field.getText(0, field.length) || "");
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

    function pasteCursorPosition() {
        if (field.selectionStart >= 0 && field.selectionStart !== field.selectionEnd)
            return field.selectionStart;
        return Math.max(0, field.cursorPosition);
    }

    function pasteImage() {
        composer.pasteCursor = composer.pasteCursorPosition();
        if (composer.attachments.length >= composer.maxAttachments) {
            composer.pasteText();
            return ;
        }
        if (!pasteProc.running)
            pasteProc.running = true;
    }

    function pasteText() {
        if (!pasteTextProc.running)
            pasteTextProc.running = true;
    }

    function addPastedPath(path, fromUri) {
        var value = String(path || "");
        if (fromUri === true) {
            try {
                value = decodeURIComponent(value);
            } catch (error) {
                value = value;
            }
        }
        if (value === "" || composer.attachments.indexOf(value) >= 0)
            return false;
        if (composer.attachments.length >= composer.maxAttachments)
            return false;
        composer.attachments = composer.attachments.concat([value]);
        return true;
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
                    text: Tr.fmt("Replying to %1", composer.replyName)
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

                        Twemoji {
                            anchors.fill: parent
                            visible: emojiRow.modelData.custom !== true
                            emoji: String(emojiRow.modelData.e || "")
                            size: Theme.dp(22)
                            fallbackColor: emojiRow.index === composer.emojiIndex ? Theme.fgPrimaryContainer : Theme.text
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
                    // Let the wheel scroll the list instead of being swallowed
                    // by the row's click target.
                    onWheel: (wheel) => {
                        wheel.accepted = false;
                    }
                    onClicked: composer.pickEmoji(emojiRow.index)
                }

            }

        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(6)

            Rectangle {
                id: inputBox

                Layout.fillWidth: true
                readonly property real maxHeight: Theme.dp(140)
                Layout.preferredHeight: Math.min(inputBox.maxHeight,
                    Math.max(Theme.dp(36), field.contentHeight + Theme.dp(14)))
                radius: height <= Theme.dp(40) ? Theme.pill(height) : Theme.rad(18)
                color: Theme.surfaceHigh
                border.width: field.activeFocus ? 1 : 0
                border.color: Theme.alpha(Theme.primary, 0.55)

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.IBeamCursor
                    onClicked: field.forceActiveFocus()
                }

                Flickable {
                    id: inputScroll

                    anchors.fill: parent
                    anchors.leftMargin: Theme.dp(12)
                    anchors.rightMargin: Theme.dp(10)
                    anchors.topMargin: Theme.dp(7)
                    anchors.bottomMargin: Theme.dp(7)
                    clip: true
                    contentWidth: width
                    contentHeight: field.height
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: false

                    function keepCursorVisible() {
                        var limit = Math.max(0, inputScroll.contentHeight - inputScroll.height);
                        if (limit <= 0) {
                            if (inputScroll.contentY !== 0)
                                inputScroll.contentY = 0;
                            return ;
                        }
                        var rect = field.positionToRectangle(field.cursorPosition);
                        var margin = Theme.dp(3);
                        if (rect.y < inputScroll.contentY + margin) {
                            inputScroll.contentY = Math.max(0, Math.min(limit, rect.y - margin));
                        } else if (rect.y + rect.height > inputScroll.contentY + inputScroll.height - margin) {
                            inputScroll.contentY = Math.max(0, Math.min(limit,
                                rect.y + rect.height - inputScroll.height + margin));
                        }
                    }

                    WheelHandler {
                        onWheel: (event) => {
                            var limit = Math.max(0, inputScroll.contentHeight - inputScroll.height);
                            if (limit <= 0)
                                return ;
                            var delta = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y;
                            inputScroll.contentY = Math.max(0, Math.min(limit, inputScroll.contentY - delta));
                            event.accepted = true;
                        }
                    }

                    TextEdit {
                        id: field

                        width: inputScroll.width
                        height: Math.max(contentHeight, inputScroll.height)
                        textFormat: TextEdit.RichText
                        wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
                        verticalAlignment: TextEdit.AlignVCenter
                        selectByMouse: true
                        persistentSelection: true
                        activeFocusOnPress: true
                        topPadding: 0
                        bottomPadding: 0
                        leftPadding: 0
                        rightPadding: 0
                        color: Theme.text
                        selectionColor: Theme.alpha(Theme.primary, 0.35)
                        selectedTextColor: Theme.text
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.typeSize("bodyMedium")
                        font.variableAxes: Theme.axes(Theme.typeSize("bodyMedium"), 420, 0)
                        onTextChanged: {
                            composer.rebuildEmoji();
                            composer.updateEmojiPicker();
                            Qt.callLater(inputScroll.keepCursorVisible);
                        }
                        onCursorPositionChanged: {
                            composer.updateEmojiPicker();
                            Qt.callLater(inputScroll.keepCursorVisible);
                        }
                        onContentHeightChanged: Qt.callLater(inputScroll.keepCursorVisible)
                        onActiveFocusChanged: {
                            if (!composer.host)
                                return ;

                            if (activeFocus)
                                composer.host.beginEdit();
                            else
                                composer.host.endEdit();

                        }

                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                if (event.modifiers & Qt.ShiftModifier) {
                                    field.insert(field.cursorPosition, "\n");
                                } else if (composer.emojiOpen) {
                                    composer.pickEmoji(composer.emojiIndex);
                                } else {
                                    composer.submit();
                                }
                                event.accepted = true;
                                return ;
                            }
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
                                if (event.key === Qt.Key_Home) {
                                    composer.firstEmoji();
                                    event.accepted = true;
                                    return ;
                                }
                                if (event.key === Qt.Key_End) {
                                    composer.lastEmoji();
                                    event.accepted = true;
                                    return ;
                                }
                                if (event.key === Qt.Key_PageUp) {
                                    composer.pageEmoji(-1);
                                    event.accepted = true;
                                    return ;
                                }
                                if (event.key === Qt.Key_PageDown) {
                                    composer.pageEmoji(1);
                                    event.accepted = true;
                                    return ;
                                }
                                if (event.key === Qt.Key_Tab) {
                                    composer.pickEmoji(composer.emojiIndex);
                                    event.accepted = true;
                                    return ;
                                }
                            }
                            if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_V) {
                                // Taking the key stops TextEdit from inserting
                                // the clipboard's text/html copy beside the
                                // attachment.
                                event.accepted = true;
                                composer.pasteImage();
                            }

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
                            anchors.left: parent.left
                            width: parent.width
                            visible: field.length === 0
                            role: "bodyMedium"
                            text: composer.placeholder
                            color: Theme.subtextDim
                            opacity: 0.8
                            elide: Text.ElideRight
                        }

                    }

                    onHeightChanged: Qt.callLater(keepCursorVisible)

                }

            }

            IconButton {
                Layout.alignment: Qt.AlignVCenter
                icon: "send"
                variant: "filled"
                size: "s"
                enabled: (String(composer.text || "").trim() !== "" || composer.attachments.length > 0) && !composer.busy
                onClicked: composer.submit()
            }

        }

    }

    Process {
        id: pasteProc

        running: false
        command: [
            "sh", "-c",
            "d=\"$1\"; mkdir -p \"$d\"; types=$(wl-paste --list-types 2>/dev/null); "
                + "for x in $types; do case \"$x\" in image/*) ext=\"${x#image/}\"; f=\"$d/paste-$(date +%s%N).${ext%%+*}\"; "
                + "if wl-paste --type \"$x\" > \"$f\" 2>/dev/null; then printf 'I\\t%s\\n' \"$f\"; exit 0; fi;; esac; done; "
                + "case \"$types\" in *text/uri-list*) "
                + "out=$(wl-paste --type text/uri-list 2>/dev/null | while IFS= read -r u; do case \"$u\" in file://*) printf 'U\\t%s\\n' \"$u\";; esac; done); "
                + "if [ -n \"$out\" ]; then printf '%s\\n' \"$out\"; else printf 'N\\n'; fi; exit 0;; esac; "
                + "printf 'N\\n'",
            "sh", composer.pasteDir
        ]

        stdout: StdioCollector {
            onStreamFinished: {
                var added = false;
                var blocked = false;
                var lines = String(this.text || "").split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var line = String(lines[i] || "").replace(/\r$/, "");
                    if (line === "X") {
                        blocked = true;
                        continue;
                    }
                    if (line === "N")
                        continue;
                    if (line.indexOf("I\t") === 0) {
                        if (composer.addPastedPath(line.slice(2), false))
                            added = true;
                        continue;
                    }
                    if (line.indexOf("U\t") === 0) {
                        var uri = line.slice(2).trim();
                        if (uri.indexOf("file://") === 0 && composer.addPastedPath(uri.slice(7), true))
                            added = true;
                    }
                }
                if (!added && !blocked)
                    composer.pasteText();
            }
        }
    }

    Process {
        id: pasteTextProc

        running: false
        command: ["sh", "-c", "wl-paste --no-newline --type text/plain 2>/dev/null"]

        stdout: StdioCollector {
            onStreamFinished: {
                var text = String(this.text || "");
                composer.pasteCursor = composer.pasteCursor >= 0 ? composer.pasteCursor : composer.pasteCursorPosition();
                if (field.selectionStart >= 0 && field.selectionStart !== field.selectionEnd)
                    field.remove(field.selectionStart, field.selectionEnd);
                if (text !== "")
                    field.insert(Math.min(composer.pasteCursor, field.length), text);
                composer.pasteCursor = -1;
                field.forceActiveFocus();
            }
        }
    }

}

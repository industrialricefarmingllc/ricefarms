import QtQuick
import QtQuick.Layouts
import qs
import qs.lucidui

// Text body that keeps the individual messages of a Discord grouping as
// separate paragraphs, with a 2 px gap instead of a full blank line.
ColumnLayout {
    id: body

    property var segments: []
    property string fallback: ""
    property var host: null
    property string role: "bodyLarge"
    property bool linkify: false
    property bool stripAllUrls: false
    property var stripUrls: []
    property int maxChars: 0
    property int maxLines: 1000
    property real lineHeight: 1.0
    property color ink: Theme.text

    signal linkActivated(string link)
    // A plain tap on the body, without dragging a selection and not on a link.
    // Cards use this to open the post even when the pointer lands on text.
    signal clicked()

    spacing: Theme.dp(2)

    readonly property int emojiPx: Math.round(Theme.typeSize(body.role) + 2)
    // TextEdit has no linkColor property; inline the palette colour instead of
    // letting Qt's default deep blue through.
    readonly property string linkColorHex: body.colorHex(Theme.primary)
    readonly property var parts: {
        var source = (body.segments && body.segments.length > 0) ? body.segments : [body.fallback];
        var clean = [];
        for (var i = 0; i < source.length; i++) {
            var text = String(source[i] || "");
            // Hiding external links must not hide a FakeNitro emoji: its link
            // is the emoji itself, not a surrounding URL.
            if (body.stripAllUrls)
                text = text.replace(/(https?:\/\/(?!cdn\.discordapp\.com\/emojis\/|media\.discordapp\.net\/emojis\/)[^\s<>"']+)/g, "");
            for (var s = 0; s < body.stripUrls.length; s++) {
                var strip = String(body.stripUrls[s]);
                if (strip.indexOf("/emojis/") >= 0)
                    continue;
                text = text.split(strip).join("");
            }
            text = text.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
            if (text !== "")
                clean.push(text);
        }
        if (body.maxChars <= 0)
            return clean;

        var capped = [];
        var used = 0;
        for (var c = 0; c < clean.length; c++) {
            if (used >= body.maxChars)
                break;
            var left = body.maxChars - used;
            var value = clean[c];
            if (value.length > left) {
                capped.push(value.slice(0, left).replace(/\s+$/, "") + "…");
                break;
            }
            capped.push(value);
            used += value.length + 1;
        }
        return capped;
    }

    function colorHex(value) {
        function channel(v) {
            var text = Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16);
            return text.length < 2 ? "0" + text : text;
        }
        return "#" + channel(value.r) + channel(value.g) + channel(value.b);
    }

    function renderParts(value) {
        var text = String(value || "");
        if (body.host && body.host.discordParts) {
            var parts = body.host.discordParts(text, body.emojiPx, body.linkify, body.linkColorHex);
            if (parts && parts.html !== undefined)
                return parts;
        }
        return {"html": body.render(text), "images": []};
    }

    function render(value) {
        var text = String(value || "");
        // One pass for Discord's custom emoji, FakeNitro's CDN links, Unicode
        // Twemoji and ordinary links. Fall back to the old split renderer if
        // an older host is driving this body.
        if (body.host && body.host.discordRich)
            return body.host.discordRich(text, body.emojiPx, body.linkify, body.linkColorHex);

        if (!body.linkify)
            return body.host && body.host.emojiRich ? body.host.emojiRich(text, body.emojiPx) : text;

        text = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        text = text.replace(/(https?:\/\/[^\s<>"']+)/g, function (url) {
            return '<a href="' + url + '" style="color:' + body.linkColorHex + '">' + url + '</a>';
        });
        text = text.replace(/\n/g, "<br>");
        return body.host && body.host.emojiHtml ? body.host.emojiHtml(text, body.emojiPx) : text;
    }

    Repeater {
        model: body.parts

        TextEdit {
            id: bodyEdit

            Layout.fillWidth: true
            textFormat: TextEdit.RichText
            property var rendered: body.renderParts(modelData)
            property var emojiRects: []
            text: rendered.html
            color: body.ink
            readOnly: true
            selectByMouse: true
            selectByKeyboard: true
            persistentSelection: true
            cursorVisible: false
            activeFocusOnPress: true
            wrapMode: TextEdit.Wrap
            topPadding: 0
            bottomPadding: 0
            leftPadding: 0
            rightPadding: 0
            selectionColor: Theme.alpha(Theme.primary, 0.35)
            selectedTextColor: Theme.text
            font.family: Theme.fontFamily
            font.pixelSize: Theme.typeSize(body.role)
            font.weight: Theme.typeWeight(body.role) >= 650 ? Font.Bold : (Theme.typeWeight(body.role) >= 540 ? Font.DemiBold : (Theme.typeWeight(body.role) >= 470 ? Font.Medium : Font.Normal))
            font.variableAxes: Theme.axes(Theme.typeSize(body.role), Theme.typeWeight(body.role), Theme.typeRound(body.role))
            font.letterSpacing: body.role.indexOf("label") === 0 ? 0.2 : 0
            onLinkActivated: (link) => body.linkActivated(link)
            onActiveFocusChanged: {
                if (!body.host)
                    return ;
                if (activeFocus)
                    body.host.beginEdit();
                else
                    body.host.endEdit();
            }

            // Rich text renders inline images statically; animated custom
            // emoji get a live AnimatedImage laid exactly over their <img>
            // slot, so they animate at emoji size instead of becoming a media
            // card. The HTML's <img> order matches the document's U+FFFC order.
            function syncEmoji() {
                var images = rendered && rendered.images ? rendered.images : [];
                var animated = [];
                for (var k = 0; k < images.length; k++) {
                    if (images[k].animated)
                        animated.push(k);
                }
                if (animated.length === 0) {
                    if (emojiRects.length > 0)
                        emojiRects = [];
                    return ;
                }

                var doc = getText(0, length);
                var positions = [];
                for (var i = 0; i < doc.length; i++) {
                    if (doc.charCodeAt(i) === 0xFFFC)
                        positions.push(i);
                }

                var out = [];
                for (var a = 0; a < animated.length; a++) {
                    var index = animated[a];
                    var pos = positions[index];
                    if (pos === undefined)
                        continue;

                    var rect = positionToRectangle(pos);
                    var size = Math.max(1, Math.round(images[index].box));
                    var top = rect.y + Math.max(0, (rect.height - size) / 2);
                    out.push({
                        "x": Math.round(rect.x),
                        "y": Math.round(top),
                        "width": size,
                        "height": size,
                        "source": images[index].url
                    });
                }
                var next = JSON.stringify(out);
                if (next !== JSON.stringify(emojiRects))
                    emojiRects = out;
            }

            Component.onCompleted: Qt.callLater(syncEmoji)
            onRenderedChanged: Qt.callLater(syncEmoji)
            onWidthChanged: Qt.callLater(syncEmoji)
            onContentHeightChanged: Qt.callLater(syncEmoji)
            onLengthChanged: Qt.callLater(syncEmoji)

            Repeater {
                model: bodyEdit.emojiRects

                AnimatedImage {
                    x: modelData.x
                    y: modelData.y
                    width: modelData.width
                    height: modelData.height
                    source: modelData.source
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                    mipmap: true
                    playing: true
                    loops: AnimatedImage.Infinite
                    cache: true
                    z: 1
                }

            }

            // Passive tap detector: it fires alongside the TextEdit's normal
            // press handling, but never takes the exclusive grab, so dragging
            // still selects text. Links keep their own activation.
            TapHandler {
                gesturePolicy: TapHandler.DragThreshold
                acceptedButtons: Qt.LeftButton

                onTapped: (point, button) => {
                    if (bodyEdit.linkAt(point.position.x, point.position.y) === "")
                        body.clicked();
                }
            }
        }
    }
}

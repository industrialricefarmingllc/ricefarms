import QtQuick
import QtQuick.Layouts
import qs
import qs.lucidui
import "../../squircle"

// One post in the feed.  It is deliberately a reading surface first: the whole
// card opens the thread, while likes/comments/media keep their own tap targets.
Item {
    id: card

    required property var post
    required property var host
    property bool detail: false
    property int order: 0

    signal activated()
    signal likeClicked()
    signal commentsClicked()
    signal replyClicked()
    signal externalClicked()
    signal deleteClicked()
    signal dismissed()

    property real swipeOffset: 0
    property bool swiping: false
    property bool didSwipe: false
    property bool leaving: false

    // MouseArea.containsMouse can be swallowed by nested interactive items
    // (text selection, media, buttons). Combine it with a card-level handler
    // so the whole post reliably picks up its hover state.
    readonly property bool hovered: area.containsMouse || cardHover.hovered

    readonly property real pad: Theme.dp(card.detail ? 18 : 14)
    readonly property var stats: card.post.stats || ({})
    readonly property var caps: card.post.capabilities || ({})
    readonly property bool canLike: card.caps.like === true
    readonly property int commentCount: card.post.comment_count !== null && card.post.comment_count !== undefined ? Number(card.post.comment_count) : (card.stats.comments !== null && card.stats.comments !== undefined ? Number(card.stats.comments) : -1)
    readonly property int likeCount: card.stats.likes !== null && card.stats.likes !== undefined ? Number(card.stats.likes) : -1
    readonly property bool liked: card.post.liked === true
    readonly property string sourceGlyph: card.host ? card.host.sourceGlyph(card.post.source) : "public"
    readonly property string bodyText: card.post.body || ""
    readonly property string titleText: card.post.title || ""
    // Discord conversations read newest-first in the feed preview. Other
    // sources keep the first replies, which are their top-level discussion.
    readonly property var previewComments: {
        var all = card.post.comments_preview || [];
        if (card.host && card.host.dropCoveredComments)
            all = card.host.dropCoveredComments(all);
        if (card.host && card.host.dropSplitEmojiComments)
            all = card.host.dropSplitEmojiComments(all);
        if (card.detail || String(card.post.source || "") === "hackernews")
            return [];
        if (String(card.post.source || "") === "discord")
            return all.slice(-2);
        return all.slice(0, 2);
    }
    readonly property bool longBody: card.bodyText.length > 280
    readonly property string shownBody: card.detail || !card.longBody ? card.bodyText : card.bodyText.slice(0, 280).replace(/\s+$/, "") + "…"
    // FakeNitro emoji links are painted inline by SocialBody; they must never
    // become a link/media card or a stray "open link" button.
    readonly property var mediaList: {
        var out = [];
        var media = card.post.media || [];
        for (var i = 0; i < media.length; i++) {
            var item = media[i];
            if (card.host && card.host.isEmojiLink && (card.host.isEmojiLink(item.url) || card.host.isEmojiLink(item.external_url)))
                continue;

            var url = String(item.external_url || item.url || "");
            if ((item.kind === "link" || item.kind === "embed") && /\.gif(?:[?#]|$)/i.test(url)) {
                out.push({"kind": "image", "url": url, "thumbnail_url": url, "external_url": url,
                          "mime": "image/gif", "width": item.width, "height": item.height, "title": item.title || ""});
                continue;
            }
            out.push(item);
        }
        return out;
    }
    readonly property string bodyUrl: {
        var media = card.mediaList;
        for (var i = 0; i < media.length; i++) {
            if (media[i].kind === "link" || media[i].kind === "embed")
                return String(media[i].external_url || media[i].url || "");
        }
        var found = String(card.bodyText || "").match(/https?:\/\/[^\s<>"]+/g) || [];
        for (var j = 0; j < found.length; j++) {
            if (card.host && card.host.isEmojiLink && card.host.isEmojiLink(found[j]))
                continue;
            if (/\.gif(?:[?#]|$)/i.test(found[j]))
                continue;
            return found[j];
        }
        return "";
    }
    readonly property var bodyGifMedia: {
        var text = String(card.post.body || "");
        var known = {};
        var media = card.mediaList;
        for (var i = 0; i < media.length; i++) {
            // A link card for the same page is replaced by the real GIF; only
            // an already-visual attachment should suppress the body URL.
            if (media[i].kind !== "image" && media[i].kind !== "video")
                continue;
            if (media[i].url)
                known[String(media[i].url)] = true;
            if (media[i].external_url)
                known[String(media[i].external_url)] = true;
        }
        var out = [];
        var found = text.match(/(https?:\/\/(?:www\.)?(?:tenor\.com\/view\/|klipy\.com\/gifs\/|giphy\.com\/gifs\/)[^\s<>"']+)/gi) || [];
        for (var j = 0; j < found.length; j++) {
            var url = found[j].replace(/[),.;!?]+$/, "");
            if (known[url] === true)
                continue;
            known[url] = true;
            out.push({"kind": "video", "url": url, "external_url": url, "title": "GIF", "width": 0, "height": 0});
        }

        var direct = text.match(/https?:\/\/[^\s<>"']+\.gif(?:\?[^\s<>"']*)?/gi) || [];
        for (var g = 0; g < direct.length; g++) {
            var gif = direct[g].replace(/[),.;!?]+$/, "");
            if (card.host && card.host.isEmojiLink && card.host.isEmojiLink(gif))
                continue;
            if (known[gif] === true)
                continue;
            known[gif] = true;
            out.push({"kind": "image", "url": gif, "thumbnail_url": gif, "external_url": gif,
                      "mime": "image/gif", "width": 0, "height": 0});
        }
        return out;
    }
    readonly property var gifUrls: {
        var out = [];
        var seen = {};
        var media = card.mediaList;
        for (var i = 0; i < media.length; i++) {
            var url = String(media[i].external_url || media[i].url || "");
            if (/\.gif(?:[?#]|$)/i.test(url) && seen[url] !== true) {
                seen[url] = true;
                out.push(url);
            }
        }
        var body = String(card.post.body || "");
        var direct = body.match(/https?:\/\/[^\s<>"']+\.gif(?:\?[^\s<>"']*)?/gi) || [];
        for (var g = 0; g < direct.length; g++) {
            var gif = direct[g].replace(/[),.;!?]+$/, "");
            if (card.host && card.host.isEmojiLink && card.host.isEmojiLink(gif))
                continue;
            if (seen[gif] !== true) {
                seen[gif] = true;
                out.push(gif);
            }
        }
        return out;
    }
    // The same video arrives in more than one shape: Discord embeds carry the
    // /embed/ URL, the body carries youtu.be/…?si=… and a shared link can add
    // its own params. Compare a canonical key so one video never makes two
    // cards.
    function videoKey(value) {
        var url = String(value || "");
        var youtube = url.match(/(?:youtube\.com\/(?:watch\?[^#]*v=|shorts\/|embed\/)|youtu\.be\/)([A-Za-z0-9_-]{6,})/i);
        if (youtube)
            return "youtube:" + youtube[1].toLowerCase();
        var clean = url.split("#")[0]
            .replace(/^https?:\/\//i, "")
            .replace(/^www\./i, "")
            .replace(/([?&])(si|t|feature|utm_[^=&]*|is|ex|hm)=[^&]*/gi, "")
            .replace(/[?&]+$/, "")
            .replace(/\/+$/, "");
        return clean.toLowerCase();
    }
    readonly property var bodyVideoMedia: {
        var text = String(card.post.body || "");
        var known = {};
        var media = card.mediaList;
        for (var i = 0; i < media.length; i++) {
            if (media[i].kind === "link" || media[i].kind === "embed")
                continue;
            var key = card.videoKey(media[i].url || media[i].external_url);
            if (key !== "")
                known[key] = true;
            if (media[i].external_url) {
                var ext = card.videoKey(media[i].external_url);
                if (ext !== "")
                    known[ext] = true;
            }
        }
        var out = [];
        var pattern = /https?:\/\/(?:www\.)?(?:youtube\.com\/(?:watch\?v=|shorts\/)|youtu\.be\/|instagram\.com\/(?:reel|p|tv)\/|kkinstagram\.com\/(?:reel|p|tv)\/|tiktok\.com\/[^\s]+\/video\/|vimeo\.com\/\d+|twitch\.tv\/videos\/\d+|streamable\.com\/[a-z0-9]+)[^\s<>"']*/gi;
        var found = text.match(pattern) || [];
        for (var j = 0; j < found.length; j++) {
            var url = found[j].replace(/[),.;!?]+$/, "");
            var id = card.videoKey(url);
            if (id !== "" && known[id] === true)
                continue;
            known[id] = true;
            var youtube = url.match(/(?:youtube\.com\/(?:watch\?v=|shorts\/)|youtu\.be\/)([A-Za-z0-9_-]{6,})/i);
            var thumbnail = youtube ? "https://i.ytimg.com/vi/" + youtube[1] + "/hqdefault.jpg" : "";
            out.push({
                "kind": "video",
                "url": url,
                "external_url": url,
                "thumbnail_url": thumbnail,
                "width": 0,
                "height": 0,
                "title": youtube ? Tr.t("YouTube") : Tr.t("Video")
            });
        }
        return out;
    }
    readonly property var visualMedia: card.mediaList.filter((m) => m.kind !== "link" && m.kind !== "embed").concat(card.bodyGifMedia).concat(card.bodyVideoMedia)
    readonly property bool hideExternalLinks: card.visualMedia.some((m) => m.kind === "video")
    readonly property var linkedUrlList: {
        var out = [];
        for (var key in card.linkedUrls)
            out.push(key);
        return out;
    }
    readonly property var linkedUrls: {
        var out = {};
        var media = card.mediaList;
        for (var i = 0; i < media.length; i++) {
            if (media[i].kind !== "link" && media[i].kind !== "embed")
                continue;
            if (media[i].url)
                out[String(media[i].url)] = true;
            if (media[i].external_url)
                out[String(media[i].external_url)] = true;
        }
        return out;
    }
    readonly property string displayBody: card.hideExternalLinks ? card.shownBody.replace(/(https?:\/\/(?!cdn\.discordapp\.com\/emojis\/|media\.discordapp\.net\/emojis\/)[^\s<>"']+)/g, "").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim() : card.shownBody

    implicitHeight: column.implicitHeight + card.pad * 2
    height: implicitHeight
    width: parent ? parent.width : implicitWidth
    opacity: 0
    transform: Translate {
        x: card.swipeOffset
    }

    Component.onCompleted: {
        if (!card.host || card.host.claimIntro(card.post.id)) {
            intro.interval = Math.min(card.order, 12) * 26;
            intro.start();
        } else {
            card.opacity = 1;
        }
    }

    Timer {
        id: intro

        interval: 0
        onTriggered: fade.start()
    }

    NumberAnimation {
        id: fade

        target: card
        property: "opacity"
        to: 1
        duration: Theme.durEnter
        easing.type: Easing.Bezier
        easing.bezierCurve: Theme.curveDefaultSpatial
    }

    NumberAnimation {
        id: settle

        target: card
        property: "swipeOffset"
        to: 0
        duration: Theme.durFastSpatial
        easing.type: Easing.Bezier
        easing.bezierCurve: Theme.curveFastSpatial
    }

    function swipeAway(direction) {
        if (card.leaving)
            return ;

        card.leaving = true;
        // Hiding is immediate on release; the drag itself was the animation.
        card.dismissed();
    }

    DragHandler {
        id: swipe

        target: null
        enabled: !card.detail
        xAxis.enabled: true
        yAxis.enabled: false
        dragThreshold: Theme.dp(18)
        acceptedButtons: Qt.LeftButton

        onActiveChanged: {
            if (active) {
                card.swiping = true;
                card.didSwipe = false;
                card.leaving = false;
                settle.stop();
                return ;
            }
            if (!card.swiping)
                return ;

            var dx = card.swipeOffset;
            card.swiping = false;
            // Distance, not velocity: a vertical scroll can produce a brief
            // horizontal flick that should not dismiss the post.
            if (Math.abs(dx) > Theme.dp(72))
                card.swipeAway(dx < 0 ? -1 : 1);
            else
                settle.start();

        }

        onTranslationChanged: {
            if (!card.swiping || card.leaving)
                return ;

            card.swipeOffset = swipe.translation.x;
            if (Math.abs(swipe.translation.x) > Theme.dp(8))
                card.didSwipe = true;

        }

    }

    function previewBody(comment) {
        var body = String((comment || {}).body || "");
        // A Discord author group can contain several consecutive messages.
        // The compact preview is a "latest activity" strip, so keep the last
        // messages of that group rather than the first one it started with.
        if (String(card.post.source || "") === "discord") {
            var segments = (comment || {}).body_segments || [];
            if (segments.length > 1) {
                var tail = [];
                for (var s = segments.length - 1; s >= 0 && tail.length < 2; s--) {
                    var segment = String(segments[s] || "").trim();
                    if (segment !== "")
                        tail.unshift(segment);
                }
                if (tail.length > 0)
                    body = tail.join("\n");
            } else if (comment.grouped === true && body.indexOf("\n") >= 0) {
                var lines = body.split("\n");
                var lastLines = [];
                for (var l = lines.length - 1; l >= 0 && lastLines.length < 2; l--) {
                    if (String(lines[l] || "").trim() !== "")
                        lastLines.unshift(String(lines[l]).trim());
                }
                if (lastLines.length > 0)
                    body = lastLines.join("\n");
            }
        }
        // An image-only comment should still identify itself in the compact
        // preview instead of leaving a blank author line.
        if (body.trim() === "") {
            var media = (comment || {}).media || [];
            if (media.length > 0) {
                var kind = String(media[0].kind || "");
                body = kind === "video" ? Tr.t("Video") : (kind === "image" ? Tr.t("Image") : (kind === "audio" ? Tr.t("Audio") : Tr.t("Attachment")));
            }
        }
        return body;
    }

    function previewText(comment) {
        var who = (comment || {}).author || {};
        var author = String(who.display_name || who.handle || Tr.t("Someone"));
        var text = author + "  " + card.previewBody(comment);
        if (!card.host || !card.host.previewRich)
            return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        return card.host.previewRich(text, Theme.typeSize("bodySmall") + 2);
    }

    function rich(value) {
        var text = String(value || "");
        var linked = card.linkedUrls;
        for (var key in linked)
            text = text.split(key).join("");
        text = text.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
        text = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        text = text.replace(/(https?:\/\/[^\s<>"']+)/g, '<a href="$1">$1</a>');
        return text.replace(/\n/g, "<br>");
    }

    SquircleRect {
        anchors.fill: parent
        radius: Theme.rad(20)
        fillColor: card.hovered ? Theme.surfaceHighest : Theme.surfaceHigh
        borderWidth: 1
        borderColor: Theme.alpha(card.host ? card.host.ink : Theme.text, card.hovered ? 0.14 : 0.07)
        smoothing: Prefs.squircleF

        Behavior on fillColor {
            ColorAnimation {
                duration: Theme.durMedium
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.curveEffects
            }

        }

        Behavior on borderColor {
            ColorAnimation {
                duration: Theme.durShort
            }

        }

    }

    HoverHandler {
        id: cardHover
    }

    MouseArea {
        id: area

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPressed: card.didSwipe = false
        onClicked: {
            if (!card.didSwipe && !card.leaving)
                card.activated();

        }
    }

    ColumnLayout {
        id: column

        anchors.fill: parent
        anchors.margins: card.pad
        spacing: Theme.dp(7)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(9)

            SocialAvatar {
                Layout.alignment: Qt.AlignTop
                author: card.post.author || ({})
                source: card.post.source || ""
                size: card.detail ? Theme.dp(42) : Theme.dp(34)

                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    onTapped: {
                        if (card.host && card.host.openProfile)
                            card.host.openProfile(card.post.author || ({}), card.post.source || "", card.post);
                    }
                }

                HoverHandler {
                    cursorShape: Qt.PointingHandCursor
                }

            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(5)

                    Item {
                        Layout.fillWidth: true
                        implicitHeight: postAuthorName.implicitHeight

                        LText {
                            id: postAuthorName

                            width: Math.min(parent.width, implicitWidth)
                            role: "titleSmall"
                            text: (card.post.author || {}).display_name || (card.post.author || {}).handle || Tr.t("Someone")
                            color: card.host ? card.host.ink : Theme.text
                            elide: Text.ElideRight
                        }

                        // Only the rendered name is a profile target. The row's
                        // time, delete control and empty space stay inert.
                        MouseArea {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            width: Math.min(postAuthorName.contentWidth, postAuthorName.width)
                            height: postAuthorName.height
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (card.host && card.host.openProfile)
                                    card.host.openProfile(card.post.author || ({}), card.post.source || "", card.post);
                            }
                        }

                    }



                    Item {
                        Layout.alignment: Qt.AlignVCenter
                        width: Theme.dp(18)
                        height: Theme.dp(18)
                        visible: card.post !== null && card.post.ref !== undefined && card.post.ref.mine === true

                        Icon {
                            anchors.centerIn: parent
                            name: "delete"
                            size: Theme.dp(14)
                            color: Theme.alpha(Theme.error, 0.8)
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: card.deleteClicked()
                        }

                    }

                    LText {
                        Layout.alignment: Qt.AlignVCenter
                        role: "labelSmall"
                        text: card.host ? card.host.ago(card.host.feedTimeText(card.post)) : ""
                        color: card.host ? card.host.inkFaint : Theme.subtextDim
                    }

                }

            }

        }

        RowLayout {
            Layout.fillWidth: true
            visible: card.titleText !== "" && card.titleText !== card.bodyText
            spacing: Theme.dp(4)

            LText {
                Layout.fillWidth: true
                role: card.detail ? "titleMedium" : "titleSmall"
                text: card.titleText
                color: card.host ? card.host.ink : Theme.text
                wrapMode: Text.Wrap
            }

            IconButton {
                id: titleLinkButton

                Layout.alignment: Qt.AlignBottom
                icon: "link"
                variant: "filled"
                size: "xs"
                tooltip: Tr.t("Open link")
                visible: card.bodyText === "" && card.bodyUrl !== "" && !card.hideExternalLinks
                onClicked: card.host.openUrl(card.bodyUrl, titleLinkButton)
            }

        }

        Item {
            Layout.fillWidth: true
            implicitHeight: bodyRow.implicitHeight
            visible: card.displayBody !== "" && card.bodyText !== card.titleText

            RowLayout {
                id: bodyRow

                anchors.fill: parent
                spacing: Theme.dp(4)

                SocialBody {
                    id: bodyText

                    Layout.fillWidth: true
                    spacing: String(card.post.source || "") === "discord" ? Theme.dp(4) : Theme.dp(2)
                    segments: card.post.body_segments || []
                    fallback: card.bodyText
                    host: card.host
                    role: "bodyLarge"
                    linkify: !card.hideExternalLinks
                    stripAllUrls: card.hideExternalLinks
                    stripUrls: card.gifUrls
                    maxChars: card.detail ? 0 : 280
                    lineHeight: 1.12
                    ink: card.host ? card.host.inkDim : Theme.subtext
                    onLinkActivated: (link) => card.host.openContentLink(link, card.post.source, card.post)
                    onClicked: card.activated()
                }

                IconButton {
                    id: bodyLinkButton

                    Layout.alignment: Qt.AlignBottom
                    icon: "link"
                    variant: "filled"
                    size: "xs"
                    tooltip: Tr.t("Open link")
                    visible: card.bodyUrl !== "" && !card.hideExternalLinks
                    onClicked: card.host.openUrl(card.bodyUrl, bodyLinkButton)
                }

            }

        }

        Column {
            id: mediaColumn

            Layout.fillWidth: true
            Layout.topMargin: card.visualMedia.length > 0 ? Theme.dp(2) : 0
            spacing: Theme.dp(8)

            Repeater {
                model: card.visualMedia

                SocialMedia {
                    required property var modelData

                    width: mediaColumn.width
                    height: implicitHeight
                    value: modelData
                    host: card.host
                    maxHeight: Number.POSITIVE_INFINITY
                    ink: card.host ? card.host.ink : Theme.text
                    onExpandRequested: (value, from, previewSource, previewWidth, previewHeight) => card.host.openMediaViewer(value, from, previewSource, previewWidth, previewHeight)
                }

            }

        }

        SocialReactions {
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(2)
            target: card.post
            host: card.host
            compact: true
            showAddButton: false
        }

        // Actions sit in one row of generous targets, not tiny glyphs.
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(1)
            spacing: Theme.dp(8)

            SocialLikeButton {
                visible: card.canLike || card.likeCount >= 0
                liked: card.liked
                count: card.likeCount
                enabled: card.canLike
                ink: card.host ? card.host.inkDim : Theme.subtext
                onClicked: card.likeClicked()
            }

            Item {
                implicitWidth: commentRow.implicitWidth + Theme.dp(12)
                implicitHeight: Theme.dp(30)

                Row {
                    id: commentRow

                    anchors.centerIn: parent
                    spacing: Theme.dp(5)

                    Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chat"
                        size: Theme.dp(18)
                        color: card.host ? card.host.inkDim : Theme.subtext
                    }

                    LText {
                        anchors.verticalCenter: parent.verticalCenter
                        role: "labelMedium"
                        text: card.commentCount >= 0 ? card.commentCount : ""
                        visible: !card.detail && card.commentCount >= 0
                        color: card.host ? card.host.inkDim : Theme.subtext
                    }

                }

                StateLayer {
                    radius: Theme.pill(height)
                    tint: card.host ? card.host.inkDim : Theme.subtext
                    onClicked: card.replyClicked()
                }

            }

            Item {
                id: emojiAction

                implicitWidth: Theme.dp(30)
                implicitHeight: Theme.dp(30)
                visible: card.post.capabilities !== undefined
                    && card.post.capabilities.react === true

                Icon {
                    anchors.centerIn: parent
                    name: "mood"
                    size: Theme.dp(17)
                    color: card.host ? card.host.inkDim : Theme.subtext
                }

                StateLayer {
                    radius: Theme.pill(height)
                    tint: card.host ? card.host.inkDim : Theme.subtext
                    onClicked: {
                        if (card.host && card.host.requestEmojiCatalog)
                            card.host.requestEmojiCatalog();
                        if (!postReactionPickerLoader.active)
                            postReactionPickerLoader.active = true;
                        Qt.callLater(function () {
                            if (postReactionPickerLoader.item)
                                postReactionPickerLoader.item.open();
                        });
                    }
                }

            }

            Item {
                Layout.fillWidth: true
            }

            LText {
                role: "labelSmall"
                text: (card.post.extra || {}).views ? (card.host ? card.host.count(card.post.extra.views) + " views" : card.post.extra.views + " views") : ""
                color: card.host ? card.host.inkFaint : Theme.subtextDim
                visible: text !== ""
            }

        }

        // A compact preview makes the feed readable without opening every post.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(2)
            spacing: Theme.dp(5)
            visible: card.previewComments.length > 0

            Repeater {
                model: card.previewComments

                RowLayout {
                    required property var modelData

                    Layout.fillWidth: true
                    spacing: Theme.dp(7)

                    SocialAvatar {
                        Layout.alignment: Qt.AlignTop
                        author: modelData.author || ({})
                        source: card.post.source || ""
                        size: Theme.dp(22)

                        TapHandler {
                            acceptedButtons: Qt.LeftButton
                            onTapped: {
                                if (card.host && card.host.openProfile)
                                    card.host.openProfile(modelData.author || ({}), card.post.source || "", modelData);
                            }
                        }

                        HoverHandler {
                            cursorShape: Qt.PointingHandCursor
                        }

                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.dp(4)

                            Item {
                                Layout.fillWidth: true
                                implicitHeight: previewAuthorName.implicitHeight

                                LText {
                                    id: previewAuthorName

                                    width: Math.min(parent.width, implicitWidth)
                                    role: "labelLarge"
                                    text: (modelData.author || {}).display_name || (modelData.author || {}).handle || Tr.t("Someone")
                                    color: card.host ? card.host.ink : Theme.text
                                    elide: Text.ElideRight
                                }

                                MouseArea {
                                    anchors.left: parent.left
                                    anchors.top: parent.top
                                    width: Math.min(previewAuthorName.contentWidth, previewAuthorName.width)
                                    height: previewAuthorName.height
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (card.host && card.host.openProfile)
                                            card.host.openProfile(modelData.author || ({}), card.post.source || "", modelData);
                                    }
                                }

                            }

                        }

                        LText {
                            Layout.fillWidth: true
                            role: "bodySmall"
                            textFormat: Text.RichText
                            text: {
                                var body = card.previewBody(modelData);
                                return card.host && card.host.previewRich
                                    ? card.host.previewRich(body, Theme.typeSize("bodySmall") + 2)
                                    : body.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
                            }
                            color: card.host ? card.host.inkDim : Theme.subtext
                            wrapMode: Text.Wrap
                            maximumLineCount: card.post.source === "discord" ? 3 : 2
                            elide: Text.ElideRight
                        }

                    }

                }

            }

            Item {
                Layout.fillWidth: true
                implicitHeight: Theme.dp(22)
                visible: !card.detail && card.commentCount > card.previewComments.length

                LText {
                    anchors.verticalCenter: parent.verticalCenter
                    role: "labelMedium"
                    text: Tr.fmt(Tr.n("View all %1 comment", "View all %1 comments", card.commentCount), card.commentCount)
                    color: Theme.primary
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: card.commentsClicked()
                }

            }

        }

    }

    Behavior on scale {
        NumberAnimation {
            duration: Theme.durFastSpatial
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.curveFastSpatial
        }

    }


    Loader {
        id: postReactionPickerLoader

        active: false
        sourceComponent: ReactionPicker {
            parent: emojiAction
            x: Math.round(emojiAction.width - width)
            y: emojiAction.height + Theme.dp(4)
            catalog: card.host ? card.host.emojiCatalog : []
            usage: card.host ? card.host.emojiUsageCounts : ({})
            onPicked: (entry) => {
                if (card.host && card.host.addReaction)
                    card.host.addReaction(card.post, entry);
            }
        }
    }

}

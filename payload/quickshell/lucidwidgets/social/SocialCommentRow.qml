import QtQuick
import QtQuick.Layouts
import qs
import qs.lucidui
import "../../squircle"

// A comment in the opened thread. The chain is a flat timeline: every reply
// shares one left rail and avatar column, matching Bluesky/Twitter.
Item {
    id: row

    required property var comment
    required property var host
    property bool compact: false
    property bool context: false
    property bool firstInChain: false
    property bool lastInChain: false
    property int depth: 0

    signal replyRequested()
    signal likeClicked()
    signal deleteRequested()

    HoverHandler {
        id: rowHover
    }

    readonly property bool hovered: rowHover.hovered
    readonly property var caps: row.comment.capabilities || ({})
    readonly property var stats: row.comment.stats || ({})
    readonly property int likeCount: row.stats.likes !== null && row.stats.likes !== undefined ? Number(row.stats.likes) : -1
    readonly property bool liked: row.comment.liked === true
    readonly property bool local: row.comment.ref !== undefined && row.comment.ref.local === true
    readonly property bool continuation: Number(row.comment._group_index
        !== undefined ? row.comment._group_index : ((row.comment.ref || {})._group_index || 0)) > 0
    readonly property var segmentItems: {
        var ref = row.comment.ref || ({});
        var texts = row.comment.body_segments || [];
        var groups = ref.segment_media;
        if (Array.isArray(ref.segment_ids) && Array.isArray(groups) && groups.length === texts.length) {
            var aligned = [];
            var ids = ref.segment_ids;
            for (var i = 0; i < texts.length; i++) {
                var gap = 0;
                if (i > 0)
                    gap = String(ids[i] || "") !== String(ids[i - 1] || "") ? Theme.dp(4) : Theme.dp(4);
                aligned.push({"text": String(texts[i] || ""), "media": groups[i] || [], "gap": gap});
            }
            return aligned;
        }
        var fallbackText = texts.length > 0 ? texts.join("\n") : String(row.comment.body || "");
        return [{"text": fallbackText, "media": row.comment.media || [], "gap": 0}];
    }
    readonly property real avatarTop: Theme.dp(row.compact ? 4 : 7)
    readonly property real avatarSize: Theme.dp(row.compact ? 24 : 28)
    readonly property real avatarCenter: avatarTop + row.avatarSize / 2
    readonly property real likeTop: row.avatarTop + row.avatarSize + Theme.dp(6)
    readonly property real likeBottom: row.likeTop + Theme.dp(20)
    readonly property bool likeShown: false
    readonly property real railTop: row.firstInChain ? row.avatarCenter : 0
    readonly property real railBottom: row.lastInChain ? row.avatarCenter : row.height
    readonly property bool railVisible: !row.continuation && !(row.firstInChain && row.lastInChain)
    readonly property bool railCut: row.railVisible && row.likeShown && row.likeTop < row.railBottom
    readonly property var embedded: row.parseEmbeds()
    readonly property string displayBody: embedded.body
    // Image-only and attachment-only messages have no text body. Do not draw
    // an empty message bubble above their media.
    readonly property bool hasBody: {
        if (String(row.displayBody || "").trim() !== "")
            return true;
        for (var i = 0; i < row.segmentItems.length; i++) {
            if ((row.segmentItems[i].media || []).length > 0)
                return true;
        }
        return (row.comment.media || []).length > 0;
    }
    readonly property var allMedia: {
        var out = [];
        var media = row.comment.media || [];
        for (var i = 0; i < media.length; i++) {
            var item = media[i];
            var url = String(item.url || item.external_url || "");
            if (row.host && row.host.isEmojiLink && row.host.isEmojiLink(url))
                continue;
            if ((item.kind === "link" || item.kind === "embed") && /\.gif(?:[?#]|$)/i.test(url)) {
                out.push({"kind": "image", "url": url, "thumbnail_url": url, "external_url": url,
                          "mime": "image/gif", "width": item.width, "height": item.height, "title": item.title || ""});
                continue;
            }
            if ((item.kind === "link" || item.kind === "embed")
                && (row.embedded.embedUrls.indexOf(url) >= 0 || row.embedded.plainUrls.indexOf(url) >= 0))
                continue;
            out.push(item);
        }
        return out.concat(row.embedded.media);
    }

    function mediaForUrl(value) {
        var url = String(value || "");
        if (row.host && row.host.isEmojiLink && row.host.isEmojiLink(url))
            return null;
        var lower = url.toLowerCase();
        var youtube = url.match(/(?:youtube\.com\/(?:watch\?v=|shorts\/|embed\/)|youtu\.be\/)([A-Za-z0-9_-]{6,})/i);
        if (youtube)
            return {"kind": "video", "url": "https://www.youtube.com/watch?v=" + youtube[1], "external_url": "https://www.youtube.com/watch?v=" + youtube[1], "thumbnail_url": "https://i.ytimg.com/vi/" + youtube[1] + "/hqdefault.jpg", "width": 1280, "height": 720, "title": Tr.t("YouTube")};
        if (/\.(png|jpe?g|gif|webp|avif)(\?|$)/.test(lower))
            return {"kind": "image", "url": url, "thumbnail_url": url, "width": 0, "height": 0};
        if (/\.(mp4|webm|mov|mkv|ogv|m3u8)(\?|$)/.test(lower))
            return {"kind": "video", "url": url, "external_url": url, "width": 0, "height": 0};
        if (/(vimeo\.com|twitch\.tv|streamable\.com)\//.test(lower))
            return {"kind": "video", "url": url, "external_url": url, "width": 0, "height": 0};
        if (/(tenor\.com\/view\/|klipy\.com\/gifs\/|giphy\.com\/gifs\/)/.test(lower))
            return {"kind": "video", "url": url, "external_url": url, "title": "GIF", "width": 0, "height": 0};
        return null;
    }

    function parseEmbeds() {
        var body = String(row.comment.body || "");
        var known = {};
        var links = {};
        var plain = {};
        var media = row.comment.media || [];
        for (var m = 0; m < media.length; m++) {
            if (row.host && row.host.isEmojiLink && (row.host.isEmojiLink(media[m].url) || row.host.isEmojiLink(media[m].external_url)))
                continue;
            if ((media[m].kind === "link" || media[m].kind === "embed") && /\.gif(?:[?#]|$)/i.test(String(media[m].url || media[m].external_url || ""))) {
                if (media[m].url)
                    known[String(media[m].url)] = true;
                if (media[m].external_url)
                    known[String(media[m].external_url)] = true;
                continue;
            }
            var visual = media[m].kind === "image" || media[m].kind === "video";
            var linked = media[m].kind === "link" || media[m].kind === "embed";
            var rich = linked && (media[m].title || media[m].thumbnail_url || media[m].alt);
            if (media[m].url) {
                var mediaUrl = String(media[m].url);
                if (visual)
                    known[mediaUrl] = true;
                else if (rich)
                    links[mediaUrl] = true;
                else if (linked)
                    plain[mediaUrl] = true;
            }
            if (media[m].external_url) {
                var external = String(media[m].external_url);
                if (visual)
                    known[external] = true;
                else if (rich)
                    links[external] = true;
                else if (linked)
                    plain[external] = true;
            }
        }
        var found = body.match(/https?:\/\/[^\s<>"']+/g) || [];
        var add = [];
        var remove = [];
        var embedUrls = [];
        var plainUrls = Object.keys(plain);
        var seen = {};
        for (var i = 0; i < found.length && add.length < 4; i++) {
            var raw = found[i];
            var url = raw.replace(/[),.;!?]+$/, "");
            if (seen[url] === true)
                continue;
            seen[url] = true;
            // A video/image attachment for this URL is already in the media
            // list; still remove the URL from the text so it does not appear
            // twice next to its embed.
            if (known[url] === true) {
                remove.push(url);
                continue;
            }
            var item = row.mediaForUrl(url);
            if (item !== null) {
                add.push(item);
                remove.push(url);
                embedUrls.push(url);
                continue;
            }
            // A regular link card already represents this URL; hide the raw
            // text and keep the card.
            if (links[url] === true)
                remove.push(url);
        }
        var display = body;
        for (var r = 0; r < remove.length; r++)
            display = display.split(remove[r]).join("");
        display = display.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
        return {"body": display, "media": add, "urls": remove, "embedUrls": embedUrls, "plainUrls": plainUrls};
    }

    implicitHeight: content.implicitHeight + Theme.dp(row.continuation ? 1 : (row.compact ? 8 : 14))
    height: implicitHeight
    x: 0
    width: parent ? parent.width : implicitWidth

    Item {
        id: emojiButton

        x: (Theme.dp(row.compact ? 24 : 28) - width) / 2
        y: row.continuation ? 0 : row.avatarTop + row.avatarSize + Theme.dp(23)
        width: Theme.dp(20)
        height: Theme.dp(20)
        z: 4
        visible: row.hovered && !row.local
            && row.comment.capabilities !== undefined
            && row.comment.capabilities.react === true

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Theme.surfaceHigh
            border.width: 1
            border.color: Theme.alpha(row.host ? row.host.ink : Theme.text, 0.12)
        }

        Icon {
            anchors.centerIn: parent
            name: "mood"
            size: Theme.dp(14)
            color: row.host ? row.host.inkDim : Theme.subtext
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (row.host && row.host.requestEmojiCatalog)
                    row.host.requestEmojiCatalog();
                reactionPickerLoader.active = true;
                Qt.callLater(function () {
                    if (reactionPickerLoader.item)
                        reactionPickerLoader.item.open();
                });
            }
        }

    }

    // One continuous timeline against the avatar column; no per-depth indents.
    // The rail is split around the like control rather than painting an opaque
    // background behind the hollow heart.
    Rectangle {
        x: Theme.dp(15)
        y: row.railTop
        width: 1
        height: Math.max(0, (row.railCut ? row.likeTop : row.railBottom) - row.railTop)
        visible: row.railVisible
        color: Theme.alpha(row.host ? row.host.ink : Theme.text, 0.16)
    }

    Rectangle {
        x: Theme.dp(15)
        y: row.likeBottom
        width: 1
        height: row.railCut ? Math.max(0, row.railBottom - row.likeBottom) : 0
        visible: row.railCut
        color: Theme.alpha(row.host ? row.host.ink : Theme.text, 0.16)
    }

    ColumnLayout {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: 0
        anchors.rightMargin: 0
        anchors.topMargin: Theme.dp(row.continuation ? 0 : (row.compact ? 4 : 7))
        spacing: Theme.dp(2)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(7)

            Column {
                Layout.alignment: Qt.AlignTop
                Layout.preferredWidth: Theme.dp(row.compact ? 24 : 28)
                visible: !row.continuation
                spacing: Theme.dp(6)

                SocialAvatar {
                    anchors.horizontalCenter: parent.horizontalCenter
                    author: row.comment.author || ({})
                    source: row.host && row.host.detailPost ? String(row.host.detailPost.source || "") : ""
                    size: Theme.dp(row.compact ? 24 : 28)
                    opacity: row.continuation ? 0 : 1
                    visible: row.continuation || true
                }

                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Theme.dp(20)
                    height: Theme.dp(20)
                    visible: row.caps.like === true || row.likeCount >= 0
                    opacity: row.caps.like === true ? 1 : 0.45

                    Icon {
                        anchors.centerIn: parent
                        name: "favorite"
                        size: Theme.dp(15)
                        fill: row.liked ? 1 : 0
                        color: row.liked ? Theme.primary : (row.host ? row.host.inkDim : Theme.subtext)
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: row.caps.like === true ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: {
                            if (row.caps.like === true)
                                row.likeClicked();
                        }
                    }

                }





            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: row.continuation ? Theme.dp(row.compact ? 31 : 35) : 0
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    visible: !row.continuation
                    spacing: Theme.dp(6)

                    Item {
                        Layout.fillWidth: true
                        implicitHeight: commentAuthorName.implicitHeight

                        LText {
                            id: commentAuthorName

                            width: Math.min(parent.width, implicitWidth)
                            role: "labelLarge"
                            textFormat: Text.StyledText
                            text: row.host && row.host.emojiLabel
                                ? row.host.emojiLabel((row.comment.author || {}).display_name || (row.comment.author || {}).handle || Tr.t("Someone"),
                                    Theme.typeSize("labelLarge") + 2)
                                : ((row.comment.author || {}).display_name || (row.comment.author || {}).handle || "Someone")
                            color: row.host ? row.host.ink : Theme.text
                            elide: Text.ElideRight
                        }

                        MouseArea {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            width: Math.min(commentAuthorName.contentWidth, commentAuthorName.width)
                            height: commentAuthorName.height
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (row.host && row.host.openProfile)
                                    row.host.openProfile(row.comment.author || ({}),
                                        row.host.detailPost ? row.host.detailPost.source : "", row.comment);
                            }
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



                    Item {
                        Layout.alignment: Qt.AlignVCenter
                        width: Theme.dp(18)
                        height: Theme.dp(18)
                        visible: !row.local

                        Icon {
                            anchors.centerIn: parent
                            name: "reply"
                            size: Theme.dp(14)
                            color: row.host ? row.host.inkFaint : Theme.subtextDim
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: row.replyRequested()
                        }

                    }

                    Item {
                        Layout.alignment: Qt.AlignVCenter
                        width: Theme.dp(18)
                        height: Theme.dp(18)
                        visible: row.comment.pending !== true && row.comment.ref !== undefined && row.comment.ref.mine === true && !row.local

                        Icon {
                            anchors.centerIn: parent
                            name: "delete"
                            size: Theme.dp(14)
                            color: Theme.alpha(Theme.error, 0.75)
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: row.deleteRequested()
                        }

                    }

                    LText {
                        Layout.alignment: Qt.AlignVCenter
                        role: "labelSmall"
                        text: row.host ? row.host.ago(row.comment.created_at) : ""
                        color: row.host ? row.host.inkFaint : Theme.subtextDim
                    }

                }

                Item {
                    Layout.fillWidth: true
                    Layout.topMargin: row.hasBody ? Theme.dp(row.continuation ? 4 : 1) : 0
                    Layout.preferredHeight: row.hasBody ? bodyBox.implicitHeight + Theme.dp(row.compact ? 16 : 20) : 0
                    visible: row.hasBody

                    SquircleRect {
                        anchors.fill: parent
                        radius: Theme.rad(20)
                        fillColor: Theme.surfaceHigh
                        borderWidth: 1
                        borderColor: Theme.alpha(row.host ? row.host.ink : Theme.text, 0.07)
                        smoothing: Prefs.squircleF
                    }

                    ColumnLayout {
                        id: bodyBox

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.dp(row.compact ? 8 : 10)
                        spacing: 0

                        Repeater {
                            model: row.segmentItems

                            ColumnLayout {
                                required property var modelData

                                Layout.fillWidth: true
                                Layout.topMargin: Number(modelData.gap || 0)
                                spacing: 0

                                SocialBody {
                                    Layout.fillWidth: true
                                    visible: String(modelData.text || "") !== ""
                                    segments: String(modelData.text || "") !== "" ? [String(modelData.text)] : []
                                    fallback: ""
                                    host: row.host
                                    linkify: true
                                    role: row.compact ? "bodySmall" : "bodyLarge"
                                    stripUrls: row.embedded.urls
                                    maxLines: row.compact ? 3 : 1000
                                    ink: row.host ? row.host.inkDim : Theme.subtext
                                    onLinkActivated: (link) => row.host.openContentLink(link,
                                        row.host.detailPost ? row.host.detailPost.source : "", row.comment)
                                }

                                Repeater {
                                    model: modelData.media || []

                                    SocialMedia {
                                        required property var modelData

                                        Layout.fillWidth: true
                                        width: bodyBox.width
                                        height: implicitHeight
                                        value: modelData
                                        host: row.host
                                        maxHeight: Number.POSITIVE_INFINITY
                                        ink: row.host ? row.host.ink : Theme.text
                                        onExpandRequested: (value, from, previewSource, previewWidth, previewHeight) => row.host.openMediaViewer(value, from, previewSource, previewWidth, previewHeight)
                                    }

                                }

                            }

                        }

                    }

                }

                SocialReactions {
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.dp(4)
                    target: row.comment
                    host: row.host
                    compact: row.compact
                    showAddButton: false
                }

            }

        }




    }


    Loader {
        id: reactionPickerLoader

        active: false
        sourceComponent: ReactionPicker {
            parent: emojiButton
            x: emojiButton.width + Theme.dp(4)
            y: 0
            catalog: row.host ? row.host.emojiCatalog : []
            usage: row.host ? row.host.emojiUsageCounts : ({})
            onPicked: (entry) => {
                if (row.host && row.host.addReaction)
                    row.host.addReaction(row.comment, entry);
            }
        }
    }

}

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

    readonly property var caps: row.comment.capabilities || ({})
    readonly property var stats: row.comment.stats || ({})
    readonly property int likeCount: row.stats.likes !== null && row.stats.likes !== undefined ? Number(row.stats.likes) : -1
    readonly property bool liked: row.comment.liked === true
    readonly property bool local: row.comment.ref !== undefined && row.comment.ref.local === true
    readonly property real avatarTop: Theme.dp(row.compact ? 4 : 7)
    readonly property real avatarSize: Theme.dp(row.compact ? 24 : 28)
    readonly property real avatarCenter: avatarTop + row.avatarSize / 2
    readonly property real likeTop: row.avatarTop + row.avatarSize + Theme.dp(6)
    readonly property real likeBottom: row.likeTop + Theme.dp(20)
    readonly property bool likeShown: row.caps.like === true || row.likeCount >= 0
    readonly property real railTop: row.firstInChain ? row.avatarCenter : 0
    readonly property real railBottom: row.lastInChain ? row.avatarCenter : row.height
    readonly property bool railVisible: !(row.firstInChain && row.lastInChain)
    readonly property bool railCut: row.railVisible && row.likeShown && row.likeTop < row.railBottom
    readonly property var embedded: row.parseEmbeds()
    readonly property string displayBody: embedded.body
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
            return {"kind": "video", "url": "https://www.youtube.com/watch?v=" + youtube[1], "external_url": "https://www.youtube.com/watch?v=" + youtube[1], "thumbnail_url": "https://i.ytimg.com/vi/" + youtube[1] + "/hqdefault.jpg", "width": 1280, "height": 720, "title": "YouTube"};
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

    implicitHeight: content.implicitHeight + Theme.dp(row.compact ? 8 : 14)
    height: implicitHeight
    x: Theme.dp(12)
    width: parent ? parent.width - x - Theme.dp(12) : implicitWidth

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
        anchors.leftMargin: Theme.dp(2)
        anchors.rightMargin: Theme.dp(2)
        anchors.topMargin: Theme.dp(row.compact ? 4 : 7)
        spacing: Theme.dp(2)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(7)

            Column {
                Layout.alignment: Qt.AlignTop
                Layout.preferredWidth: Theme.dp(row.compact ? 24 : 28)
                spacing: Theme.dp(6)

                SocialAvatar {
                    anchors.horizontalCenter: parent.horizontalCenter
                    author: row.comment.author || ({})
                    size: Theme.dp(row.compact ? 24 : 28)
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

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.durDefaultEffects
                            }

                        }

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
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(6)

                    LText {
                        role: "labelLarge"
                        text: (row.comment.author || {}).display_name || (row.comment.author || {}).handle || Tr.t("Someone")
                        color: row.host ? row.host.ink : Theme.text
                        elide: Text.ElideRight
                        Layout.fillWidth: true
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
                        visible: !row.context && !row.local

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
                        visible: !row.context && row.comment.pending !== true && row.comment.ref !== undefined && row.comment.ref.mine === true && !row.local

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
                    Layout.topMargin: Theme.dp(1)
                    Layout.preferredHeight: bodyBox.implicitHeight + Theme.dp(row.compact ? 16 : 20)

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

                        SocialBody {
                            Layout.fillWidth: true
                            segments: row.comment.body_segments || []
                            fallback: row.comment.body || ""
                            host: row.host
                            role: row.compact ? "bodySmall" : "bodyLarge"
                            stripUrls: row.embedded.urls
                            maxLines: row.compact ? 3 : 1000
                            ink: row.host ? row.host.inkDim : Theme.subtext
                        }

                    }

                }

                Flow {
                    id: reactionFlow

                    Layout.fillWidth: true
                    Layout.topMargin: Theme.dp(4)
                    spacing: Theme.dp(4)
                    visible: (row.comment.reactions || []).length > 0

                    Repeater {
                        model: row.comment.reactions || []

                        Rectangle {
                            id: reactionChip

                            required property var modelData

                            width: reactionRow.implicitWidth + Theme.dp(10)
                            height: Theme.dp(24)
                            radius: Theme.dp(12)
                            color: modelData.me === true ? Theme.primaryContainer : Theme.surfaceHigh
                            border.width: 1
                            border.color: Theme.alpha(row.host ? row.host.ink : Theme.text, 0.07)

                            RowLayout {
                                id: reactionRow

                                anchors.centerIn: parent
                                spacing: Theme.dp(3)

                                Twemoji {
                                    size: Theme.dp(14)
                                    emoji: String(reactionChip.modelData.emoji || "")
                                    imageSource: String(reactionChip.modelData.image || "")
                                    animated: reactionChip.modelData.animated === true
                                    fallbackColor: row.host ? row.host.ink : Theme.text
                                }

                                LText {
                                    visible: Number(reactionChip.modelData.count || 0) > 0
                                    role: "labelSmall"
                                    text: String(reactionChip.modelData.count || 0)
                                    color: reactionChip.modelData.me === true
                                        ? Theme.fgPrimaryContainer
                                        : (row.host ? row.host.inkDim : Theme.subtext)
                                }

                            }

                        }

                    }

                }

            }

        }

        Column {
            id: commentMedia

            Layout.fillWidth: true
            Layout.leftMargin: Theme.dp(row.compact ? 31 : 35)
            spacing: Theme.dp(6)

            Repeater {
                model: row.allMedia

                SocialMedia {
                    required property var modelData

                    width: commentMedia.width
                    height: implicitHeight
                    value: modelData
                    host: row.host
                    maxHeight: Theme.dp(260)
                    ink: row.host ? row.host.ink : Theme.text
                    onExpandRequested: (value, from, previewSource, previewWidth, previewHeight) => row.host.openMediaViewer(value, from, previewSource, previewWidth, previewHeight)
                }

            }

        }


    }

}

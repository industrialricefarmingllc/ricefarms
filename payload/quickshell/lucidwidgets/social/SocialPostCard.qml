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
    signal externalClicked()
    signal dismissed()

    property real swipeOffset: 0
    property bool swiping: false
    property bool didSwipe: false
    property bool leaving: false

    readonly property real pad: Theme.dp(card.detail ? 18 : 14)
    readonly property var stats: card.post.stats || ({})
    readonly property var caps: card.post.capabilities || ({})
    readonly property bool canLike: card.caps.like === true
    readonly property int commentCount: card.post.comment_count !== null && card.post.comment_count !== undefined ? Number(card.post.comment_count) : (card.stats.comments !== null && card.stats.comments !== undefined ? Number(card.stats.comments) : -1)
    readonly property int likeCount: card.stats.likes !== null && card.stats.likes !== undefined ? Number(card.stats.likes) : -1
    readonly property bool liked: card.post.liked === true
    readonly property string sourceTitle: card.host ? (card.host.sourceTitle(card.post.source || "") || "Social") : String(card.post.source || "")
    readonly property string sourceGlyph: card.host ? card.host.sourceGlyph(card.post.source) : "public"
    readonly property string bodyText: card.post.body || ""
    readonly property string titleText: card.post.title || ""
    readonly property bool longBody: card.bodyText.length > 280
    readonly property string shownBody: card.detail || !card.longBody ? card.bodyText : card.bodyText.slice(0, 280).replace(/\s+$/, "") + "…"
    readonly property string bodyUrl: {
        var media = card.post.media || [];
        for (var i = 0; i < media.length; i++) {
            if (media[i].kind === "link" || media[i].kind === "embed")
                return String(media[i].external_url || media[i].url || "");
        }
        var match = String(card.bodyText || "").match(/https?:\/\/[^\s<>"]+/);
        return match ? match[0] : "";
    }
    readonly property var visualMedia: (card.post.media || []).filter((m) => m.kind !== "link" && m.kind !== "embed")
    readonly property bool hideExternalLinks: String(card.post.source || "") === "youtube" && card.visualMedia.some((m) => m.kind === "video")

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
            var speed = swipe.centroid.velocity.x;
            card.swiping = false;
            if (Math.abs(dx) > Theme.dp(72) || Math.abs(speed) > 700)
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

    function rich(value) {
        var text = String(value || "");
        text = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        text = text.replace(/(https?:\/\/[^\s<>"']+)/g, '<a href="$1">$1</a>');
        return text.replace(/\n/g, "<br>");
    }

    SquircleRect {
        anchors.fill: parent
        radius: Theme.rad(20)
        fillColor: area.containsMouse ? Theme.surfaceHighest : Theme.surfaceHigh
        borderWidth: 1
        borderColor: Theme.alpha(card.host ? card.host.ink : Theme.text, area.containsMouse ? 0.14 : 0.07)
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
                size: card.detail ? Theme.dp(42) : Theme.dp(34)
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(5)

                    LText {
                        role: "titleSmall"
                        text: (card.post.author || {}).display_name || (card.post.author || {}).handle || "Someone"
                        color: card.host ? card.host.ink : Theme.text
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        width: Theme.dp(18)
                        height: Theme.dp(18)
                        radius: width / 2
                        color: Theme.primaryContainer
                        visible: card.width > Theme.dp(300)

                        Icon {
                            anchors.centerIn: parent
                            name: card.sourceGlyph
                            size: Theme.dp(12)
                            color: Theme.primary
                        }

                    }

                    LText {
                        Layout.alignment: Qt.AlignVCenter
                        role: "labelSmall"
                        text: card.host ? card.host.ago(card.post.created_at) : ""
                        color: card.host ? card.host.inkFaint : Theme.subtextDim
                    }

                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(6)

                    LText {
                        role: "labelSmall"
                        text: (card.post.author || {}).handle || ""
                        color: card.host ? card.host.inkFaint : Theme.subtextDim
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }

                    LText {
                        role: "labelSmall"
                        text: card.sourceTitle
                        color: Theme.alpha(Theme.primary, 0.85)
                        elide: Text.ElideRight
                        visible: card.width > Theme.dp(260)
                    }

                }

            }

            IconButton {
                Layout.alignment: Qt.AlignTop
                icon: "open_in_new"
                size: "xs"
                tooltip: "Open source"
                visible: String(card.post.url || "") !== "" && !card.hideExternalLinks
                onClicked: card.externalClicked()
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
                Layout.alignment: Qt.AlignBottom
                icon: "link"
                size: "xs"
                tooltip: "Open link"
                visible: card.bodyText === "" && card.bodyUrl !== "" && !card.hideExternalLinks
                onClicked: Qt.openUrlExternally(card.bodyUrl)
            }

        }

        Item {
            Layout.fillWidth: true
            implicitHeight: bodyRow.implicitHeight
            visible: card.bodyText !== "" && card.bodyText !== card.titleText

            RowLayout {
                id: bodyRow

                anchors.fill: parent
                spacing: Theme.dp(4)

                LText {
                    Layout.fillWidth: true
                    role: card.detail ? "bodyLarge" : "bodyMedium"
                    text: card.rich(card.shownBody)
                    textFormat: Text.StyledText
                    color: card.host ? card.host.inkDim : Theme.subtext
                    wrapMode: Text.Wrap
                    lineHeight: 1.12
                    onLinkActivated: (link) => Qt.openUrlExternally(link)
                }

                IconButton {
                    Layout.alignment: Qt.AlignBottom
                    icon: "link"
                    size: "xs"
                    tooltip: "Open link"
                    visible: card.bodyUrl !== "" && !card.hideExternalLinks
                    onClicked: Qt.openUrlExternally(card.bodyUrl)
                }

            }

        }

        Column {
            id: mediaColumn

            Layout.fillWidth: true
            Layout.topMargin: (card.post.media || []).length > 0 ? Theme.dp(2) : 0
            spacing: Theme.dp(8)

            Repeater {
                model: card.visualMedia

                SocialMedia {
                    required property var modelData

                    width: mediaColumn.width
                    height: implicitHeight
                    value: modelData
                    host: card.host
                    maxHeight: card.detail ? Theme.dp(620) : Theme.dp(430)
                    ink: card.host ? card.host.ink : Theme.text
                }

            }

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
                        color: card.host ? card.host.inkDim : Theme.subtext
                    }

                }

                StateLayer {
                    radius: Theme.pill(height)
                    tint: card.host ? card.host.inkDim : Theme.subtext
                    onClicked: card.commentsClicked()
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
            visible: (card.post.comments_preview || []).length > 0

            Repeater {
                model: (card.post.comments_preview || []).slice(0, card.detail ? 0 : 2)

                RowLayout {
                    required property var modelData

                    Layout.fillWidth: true
                    spacing: Theme.dp(7)

                    SocialAvatar {
                        Layout.alignment: Qt.AlignTop
                        author: modelData.author || ({})
                        size: Theme.dp(22)
                    }

                    LText {
                        Layout.fillWidth: true
                        role: "bodySmall"
                        text: ((modelData.author || {}).display_name || "Someone") + "  " + (modelData.body || "")
                        color: card.host ? card.host.inkDim : Theme.subtext
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }

                    LText {
                        Layout.alignment: Qt.AlignTop
                        role: "labelSmall"
                        text: modelData.grouped ? "grouped" : ""
                        color: card.host ? card.host.inkFaint : Theme.subtextDim
                        visible: text !== ""
                    }

                }

            }

            Item {
                Layout.fillWidth: true
                implicitHeight: Theme.dp(22)
                visible: card.commentCount > (card.post.comments_preview || []).length

                LText {
                    anchors.verticalCenter: parent.verticalCenter
                    role: "labelMedium"
                    text: "View all " + card.commentCount + " comments"
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

}

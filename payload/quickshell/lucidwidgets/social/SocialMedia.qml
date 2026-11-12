import QtQuick
import QtQuick.Layouts
import QtMultimedia
import Quickshell.Io
import qs
import qs.lucidui
import "../../squircle"

// One attachment.  The rule is absolute: pictures and video are fitted, never
// cropped.  A tall image letterboxes; it does not get its edges cut off.
Item {
    id: media

    required property var value
    property var host: null
    property real maxHeight: Theme.dp(420)
    property color ink: Theme.text
    property bool resolving: false
    // For embeds without width/height metadata, learn the real aspect from the
    // decoded image. Otherwise a square picture is letterboxed inside a 16:9
    // card and looks much smaller than it is.
    property real loadedRatio: 0

    signal expandRequested(var value, rect from, string previewSource, real previewWidth, real previewHeight)

    readonly property var m: media.value || ({})
    readonly property string kind: String(media.m.kind || "file")
    readonly property string url: String(media.m.url || media.m.external_url || "")
    readonly property string link: String(media.m.external_url || media.m.url || "")
    readonly property string poster: String(media.m.thumbnail_url || "")
    readonly property real ratio: {
        var width = Number(media.m.width || 0);
        var height = Number(media.m.height || 0);
        if (width > 0 && height > 0)
            return height / width;
        return media.loadedRatio > 0 ? media.loadedRatio : 9 / 16;
    }
    readonly property bool inlineVideo: {
        var target = media.url.toLowerCase().split("?")[0];
        return target.startsWith("file://") || /\.(mp4|webm|m3u8|mov|mkv|ogv)$/.test(target);
    }
    readonly property bool youtube: {
        var target = media.link.toLowerCase();
        return target.indexOf("youtube.com/watch") >= 0 || target.indexOf("youtu.be/") >= 0;
    }
    readonly property bool gifLike: {
        var target = (media.url + " " + media.link + " " + String(media.m.mime || "")).toLowerCase();
        return target.indexOf("tenor.com") >= 0
            || target.indexOf("klipy.com") >= 0
            || target.indexOf("giphy.com") >= 0
            || String(media.m.mime || "").toLowerCase() === "image/gif"
            || /\.gif(\?|$)/.test(media.url.toLowerCase());
    }
    readonly property bool animatedImage: {
        if (media.kind !== "image")
            return false;

        var mime = String(media.m.mime || "").toLowerCase();
        var imageUrl = String(media.m.url || "").toLowerCase();
        var thumbUrl = String(media.m.thumbnail_url || "").toLowerCase();
        return mime === "image/gif"
            || /\.gif(?:[?#]|$)/.test(imageUrl)
            || /\.gif(?:[?#]|$)/.test(thumbUrl);
    }
    readonly property bool canResolve: media.kind === "video" && !media.inlineVideo && media.host !== null && media.host.service !== undefined
    readonly property real pictureHeight: Math.max(Theme.dp(96), Math.min(media.maxHeight, media.width * media.ratio))

    implicitHeight: media.kind === "image" || media.kind === "video" ? media.pictureHeight : media.kind === "file" ? Theme.dp(68) : Theme.dp(84)
    implicitWidth: Theme.dp(240)

    function noteSourceSize(width, height) {
        if (Number(media.m.width || 0) > 0 && Number(media.m.height || 0) > 0)
            return ;
        if (width <= 0 || height <= 0)
            return ;
        var value = height / width;
        if (Math.abs(value - media.loadedRatio) > 0.0001)
            media.loadedRatio = value;
    }

    function startGif() {
        // Tenor/Klipy embeds are GIFs delivered as short mp4s: start them at
        // once and loop instead of waiting for a click on a video card.
        if (!media.gifLike || !media.inlineVideo || !video || !videoPlayer)
            return ;

        video.started = true;
        videoPlayer.source = media.url;
        videoPlayer.play();
    }

    Component.onCompleted: media.startGif()
    onMChanged: {
        media.loadedRatio = 0;
        Qt.callLater(media.startGif);
    }

    function expand() {
        if (!media.host || !media.host.host) {
            media.openExternal();
            return ;
        }
        if (media.host.preview) {
            media.openExternal();
            return ;
        }
        if (!media.host.live)
            return ;

        if (videoPlayer.playbackState === MediaPlayer.PlayingState)
            videoPlayer.pause();

        var board = media.host.host.board;
        if (!board) {
            media.openExternal();
            return ;
        }

        // The item can be wider or taller than the picture it fits, so start
        // from the painted rect, not the component's box: that is the spot on
        // the widget the picture actually occupies.
        var boxW = media.width;
        var boxH = media.height;
        var pictureW = boxW;
        var pictureH = boxH;
        if (media.kind === "image" || media.kind === "video") {
            // `ratio` already falls back to the decoded image's real aspect
            // for embeds that did not provide width/height.
            var aspect = media.ratio > 0 ? 1 / media.ratio : 1;
            pictureW = boxW;
            pictureH = boxW / aspect;
            if (pictureH > boxH) {
                pictureH = boxH;
                pictureW = boxH * aspect;
            }
        }
        var insetX = (boxW - pictureW) / 2;
        var insetY = (boxH - pictureH) / 2;
        var topLeft = media.mapToItem(board, insetX, insetY);
        var bottomRight = media.mapToItem(board, insetX + pictureW, insetY + pictureH);
        // Hand the lightbox the exact texture the card already decoded, so it
        // can paint immediately while the original loads at viewer resolution.
        media.expandRequested(media.m, Qt.rect(topLeft.x, topLeft.y, bottomRight.x - topLeft.x, bottomRight.y - topLeft.y),
                              String(media.m.thumbnail_url || media.m.url || ""),
                              Math.max(1, Math.round(media.width * 2)),
                              Math.max(1, Math.round(media.height * 2)));
    }

    function openExternal() {
        if (media.link === "")
            return ;

        if (media.host && media.host.openUrl)
            media.host.openUrl(media.link, media);
        else
            Launch.openUrl(media.link);
    }

    function formatBytes(value) {
        var size = Number(value || 0);
        if (size <= 0)
            return "";

        if (size >= 1073741824)
            return (size / 1073741824).toFixed(1) + " GB";

        if (size >= 1048576)
            return (size / 1048576).toFixed(1) + " MB";

        if (size >= 1024)
            return Math.round(size / 1024) + " KB";

        return size + " B";
    }

    function clock(ms) {
        var total = Math.max(0, Math.round(Number(ms || 0) / 1000));
        var minutes = Math.floor(total / 60);
        var seconds = total % 60;
        return minutes + ":" + (seconds < 10 ? "0" : "") + seconds;
    }

    // ------------------------------------------------------------------ image
    Item {
        anchors.fill: parent
        visible: media.kind === "image"

        SquircleClip {
            anchors.fill: parent
            radius: Theme.rad(20)
            smoothing: Prefs.squircleF
            color: Theme.surfaceHighest

            Image {
                id: image

                anchors.fill: parent
                source: media.kind === "image" && !media.animatedImage ? (media.m.thumbnail_url || media.m.url) : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
                mipmap: true
                sourceSize.width: Math.max(1, Math.round(media.width * 2))
                // Height 0 lets Qt preserve the source aspect. Using the
                // computed card height here feeds back into `ratio` when an
                // embed has no dimensions and creates a binding loop.
                sourceSize.height: 0
                visible: status === Image.Ready
                onStatusChanged: if (status === Image.Ready) media.noteSourceSize(implicitWidth, implicitHeight)
                onImplicitWidthChanged: if (status === Image.Ready) media.noteSourceSize(implicitWidth, implicitHeight)
                onImplicitHeightChanged: if (status === Image.Ready) media.noteSourceSize(implicitWidth, implicitHeight)
            }

            AnimatedImage {
                anchors.fill: parent
                source: media.animatedImage ? (media.m.url || media.m.thumbnail_url) : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
                mipmap: true
                sourceSize.width: Math.max(1, Math.round(media.width * 2))
                sourceSize.height: 0
                playing: media.animatedImage
                loops: AnimatedImage.Infinite
                cache: true
                visible: status === Image.Ready
                onStatusChanged: if (status === Image.Ready) media.noteSourceSize(implicitWidth, implicitHeight)
                onImplicitWidthChanged: if (status === Image.Ready) media.noteSourceSize(implicitWidth, implicitHeight)
                onImplicitHeightChanged: if (status === Image.Ready) media.noteSourceSize(implicitWidth, implicitHeight)
            }

            Icon {
                anchors.centerIn: parent
                visible: image.status !== Image.Ready
                name: "image"
                size: Theme.dp(28)
                color: Theme.alpha(media.ink, 0.38)
            }

            Rectangle {
                anchors.fill: parent
                radius: Theme.rad(20)
                color: Theme.text
                opacity: openArea.containsMouse ? 0.12 : 0

                Behavior on opacity {
                    NumberAnimation {
                        duration: Theme.durShort
                    }

                }

            }

            Rectangle {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: Theme.dp(10)
                width: Theme.dp(28)
                height: Theme.dp(28)
                radius: width / 2
                color: Theme.surfaceContainer
                visible: openArea.containsMouse

                Icon {
                    anchors.centerIn: parent
                    name: "open_in_full"
                    size: Theme.dp(15)
                    color: Theme.text
                }

            }

        }

        MouseArea {
            id: openArea

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: media.expand()
        }

    }

    // ------------------------------------------------------------------ video
    Item {
        id: video

        anchors.fill: parent
        visible: media.kind === "video"

        readonly property bool failed: videoFailed

        property bool started: false
        property bool videoFailed: false

        SquircleClip {
            anchors.fill: parent
            radius: Theme.rad(20)
            smoothing: Prefs.squircleF
            color: Theme.surfaceContainer

            Image {
                id: videoPoster

                anchors.fill: parent
                source: media.gifLike ? "" : media.poster
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                visible: !media.gifLike && media.poster !== "" && !video.started
            }

            VideoOutput {
                id: videoOutput

                anchors.fill: parent
                fillMode: VideoOutput.PreserveAspectFit
                visible: video.started
            }

            // The poster is the interaction surface until playback starts.
            Item {
                anchors.centerIn: parent
                width: Theme.dp(56)
                height: Theme.dp(56)
                visible: !video.started || videoPlayer.playbackState !== MediaPlayer.PlayingState

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: Theme.inverseSurface
                    scale: videoMouse.pressed ? 0.92 : 1

                    Behavior on scale {
                        NumberAnimation {
                            duration: Theme.durQuick
                            easing.type: Easing.Bezier
                            easing.bezierCurve: Theme.curveFastSpatial
                        }

                    }

                }

                Icon {
                    anchors.centerIn: parent
                    name: media.resolving ? "hourglass_top" : (video.started ? (videoPlayer.playbackState === MediaPlayer.PlayingState ? "pause" : "play_arrow") : "play_arrow")
                    size: Theme.dp(26)
                    color: Theme.fgInverseSurface
                }

            }

            // inline controls
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Theme.dp(34)
                visible: video.started && !media.gifLike
                color: Theme.inverseSurface

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.dp(8)
                    anchors.rightMargin: Theme.dp(8)
                    spacing: Theme.dp(6)

                    Icon {
                        Layout.alignment: Qt.AlignVCenter
                        name: videoPlayer.playbackState === MediaPlayer.PlayingState ? "pause" : "play_arrow"
                        size: Theme.dp(17)
                        color: Theme.fgInverseSurface
                    }

                    LText {
                        Layout.fillWidth: true
                        role: "labelSmall"
                        text: media.m.title || media.m.filename || ""
                        color: Theme.fgInverseSurface
                        elide: Text.ElideRight
                    }

                    LText {
                        role: "labelSmall"
                        tabular: true
                        text: media.clock(videoPlayer.duration)
                        color: Theme.alpha(Theme.fgInverseSurface, 0.8)
                    }

                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (videoPlayer.playbackState === MediaPlayer.PlayingState)
                            videoPlayer.pause();
                        else if (video.started)
                            videoPlayer.play();
                    }
                }

            }

            // error/unplayable fallback
            Rectangle {
                anchors.fill: parent
                visible: video.failed && !video.started
                color: Theme.surfaceHighest

                Column {
                    anchors.centerIn: parent
                    spacing: Theme.dp(4)

                    Icon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: "open_in_new"
                        size: Theme.dp(22)
                        color: Theme.subtext
                    }

                    LText {
                        role: "labelSmall"
                        text: "Open video"
                        color: Theme.subtext
                    }

                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: media.openExternal()
                }

            }

        }

        MouseArea {
            id: videoMouse

            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: media.expand()
        }

        Process {
            id: resolveProc

            running: false
            command: []

            stdout: StdioCollector {
                onStreamFinished: {
                    media.resolving = false;
                    try {
                        var value = JSON.parse(this.text);
                        if (value.ok === true && String(value.url || "") !== "") {
                            video.started = true;
                            video.videoFailed = false;
                            videoPlayer.source = value.url;
                            videoPlayer.play();
                        } else {
                            video.videoFailed = true;
                        }
                    } catch (error) {
                        video.videoFailed = true;
                    }
                }
            }

            onExited: (code) => {
                if (code !== 0) {
                    media.resolving = false;
                    video.videoFailed = true;
                }
            }
        }

        MediaPlayer {
            id: videoPlayer

            source: ""
            autoPlay: false
            loops: media.gifLike ? MediaPlayer.Infinite : 1
            videoOutput: videoOutput
            audioOutput: AudioOutput {
                muted: media.gifLike
            }
            onErrorOccurred: (error, errorString) => {
                if (error !== MediaPlayer.NoError)
                    video.videoFailed = true;

            }
        }

    }

    // ------------------------------------------------------------------ audio
    Rectangle {
        anchors.fill: parent
        visible: media.kind === "audio"
        radius: Theme.rad(18)
        color: Theme.surfaceHigh
        border.width: 1
        border.color: Theme.alpha(media.ink, 0.1)

        RowLayout {
            anchors.fill: parent
            anchors.margins: Theme.dp(12)
            spacing: Theme.dp(10)

            Rectangle {
                Layout.preferredWidth: Theme.dp(38)
                Layout.preferredHeight: Theme.dp(38)
                radius: Theme.dp(19)
                color: Theme.primaryContainer

                Icon {
                    anchors.centerIn: parent
                    name: "music_note"
                    size: Theme.dp(19)
                    color: Theme.primary
                }

            }

            Column {
                Layout.fillWidth: true
                spacing: 1

                LText {
                    width: parent.width
                    role: "labelLarge"
                    text: media.m.title || media.m.filename || "Audio"
                    color: media.ink
                    elide: Text.ElideMiddle
                }

                LText {
                    width: parent.width
                    role: "labelSmall"
                    text: media.formatBytes(media.m.size_bytes)
                    color: Theme.alpha(media.ink, 0.62)
                }

            }

            Icon {
                Layout.alignment: Qt.AlignVCenter
                name: "open_in_new"
                size: Theme.dp(18)
                color: Theme.primary
            }

        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: media.openExternal()
        }

    }

    // ------------------------------------------------------------------- file
    Rectangle {
        anchors.fill: parent
        visible: media.kind === "file"
        radius: Theme.rad(18)
        color: Theme.surfaceHigh
        border.width: 1
        border.color: Theme.alpha(media.ink, 0.1)

        RowLayout {
            anchors.fill: parent
            anchors.margins: Theme.dp(12)
            spacing: Theme.dp(10)

            Rectangle {
                Layout.preferredWidth: Theme.dp(38)
                Layout.preferredHeight: Theme.dp(38)
                radius: Theme.rad(12)
                color: Theme.primaryContainer

                Icon {
                    anchors.centerIn: parent
                    name: "description"
                    size: Theme.dp(20)
                    color: Theme.primary
                }

            }

            Column {
                Layout.fillWidth: true
                spacing: 1

                LText {
                    width: parent.width
                    role: "labelLarge"
                    text: media.m.filename || media.m.title || "Attachment"
                    color: media.ink
                    elide: Text.ElideMiddle
                }

                LText {
                    width: parent.width
                    role: "labelSmall"
                    text: [media.m.title && media.m.title !== media.m.filename ? media.m.title : "", media.formatBytes(media.m.size_bytes)].filter((s) => s !== "").join(" · ")
                    color: Theme.alpha(media.ink, 0.62)
                    elide: Text.ElideRight
                }

            }

            Icon {
                Layout.alignment: Qt.AlignVCenter
                name: "open_in_new"
                size: Theme.dp(18)
                color: Theme.primary
            }

        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            onClicked: media.openExternal()
        }

    }

    // ------------------------------------------------------------------- link
    Rectangle {
        anchors.fill: parent
        visible: media.kind === "link" || media.kind === "embed"
        radius: Theme.rad(18)
        color: Theme.surfaceHigh
        border.width: 1
        border.color: Theme.alpha(media.ink, 0.1)

        RowLayout {
            anchors.fill: parent
            anchors.margins: Theme.dp(10)
            spacing: Theme.dp(10)

            SquircleClip {
                Layout.preferredWidth: Theme.dp(62)
                Layout.preferredHeight: parent.height - Theme.dp(4)
                radius: Theme.rad(12)
                smoothing: Prefs.squircleF
                color: Theme.surfaceHighest
                visible: media.poster !== ""

                Image {
                    anchors.fill: parent
                    source: media.kind === "link" || media.kind === "embed" ? media.poster : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                }

            }

            Column {
                Layout.fillWidth: true
                spacing: 2

                LText {
                    width: parent.width
                    role: "labelLarge"
                    text: media.m.title || media.m.alt || media.m.url
                    color: media.ink
                    elide: Text.ElideRight
                }

                LText {
                    width: parent.width
                    role: "labelSmall"
                    text: media.m.alt && media.m.title ? media.m.alt : String(media.m.url || "").replace(/^https?:\/\//, "").split("/")[0]
                    color: Theme.alpha(media.ink, 0.6)
                    elide: Text.ElideRight
                }

            }

            Icon {
                Layout.alignment: Qt.AlignVCenter
                name: "open_in_new"
                size: Theme.dp(18)
                color: Theme.primary
            }

        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            onClicked: media.openExternal()
        }

    }

}

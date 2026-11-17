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
    // WebP is not decodable in this Qt build. A failed image asks the service
    // for a converted local file once, then paints from that.
    property string fallbackUrl: ""
    property bool fallbackTried: false
    property bool transcoding: false
    readonly property string imageUrl: media.fallbackUrl !== "" ? media.fallbackUrl : String(media.m.url || "")
    readonly property string imageThumb: media.fallbackUrl !== "" ? media.fallbackUrl : String(media.m.thumbnail_url || "")
    // The URL this item last represented. List views recycle delegates, so a
    // card that scrolls away from a playing recording must stop it.
    property string boundAudioUrl: ""
    property bool resolvingAudio: false
    property bool audioResolveFailed: false
    property string resolvedAudioUrl: ""
    readonly property string audioUrl: media.resolvedAudioUrl !== "" ? media.resolvedAudioUrl : media.url
    readonly property bool directAudio: {
        var target = String(media.url || "").toLowerCase().split("?")[0];
        var mime = String(media.m.mime || "").toLowerCase();
        var page = target.includes("spotify.com") || target.includes("soundcloud.com")
            || target.includes("bandcamp.com") || target.includes("mixcloud.com");
        return target.startsWith("file://") || /\.(mp3|m4a|aac|ogg|oga|opus|flac|wav)(?:[?#]|$)/.test(target)
            || (mime.startsWith("audio/") && !page);
    }

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
        var mime = String(media.m.mime || "").toLowerCase();
        return target.startsWith("file://") || /\.(mp4|webm|m3u8|mov|mkv|ogv)$/.test(target)
            || mime.startsWith("video/");
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
    readonly property bool gifPoster: /\.gif(?:[?#]|$)/i.test(media.poster)
        || String(media.m.mime || "").toLowerCase() === "image/gif"
    readonly property bool animatedImage: {
        if (media.kind !== "image")
            return false;

        var mime = String(media.m.mime || "").toLowerCase();
        var imageUrl = media.imageUrl.toLowerCase();
        var thumbUrl = media.imageThumb.toLowerCase();
        return mime === "image/gif"
            || /\.gif(?:[?#]|$)/.test(imageUrl)
            || /\.gif(?:[?#]|$)/.test(thumbUrl);
    }
    readonly property bool imageLoading: media.kind === "image" && (
        media.transcoding
        || image.status === Image.Loading
        || (media.animatedImage && animatedImage.status === AnimatedImage.Loading))
    readonly property bool imageFailed: media.kind === "image" && !media.transcoding && (image.status === Image.Error
        || (media.animatedImage && animatedImage.status === AnimatedImage.Error))
    readonly property bool richImage: media.kind === "image"
        && String(media.m.filename || "") === ""
        && !(Number(media.m.size_bytes || 0) > 0)
    visible: !(media.richImage && media.imageFailed)
    readonly property bool canResolve: media.kind === "video" && !media.inlineVideo && media.host !== null && media.host.service !== undefined
    readonly property real pictureHeight: {
        return Math.max(Theme.dp(96), Math.min(media.maxHeight, media.width * media.ratio));
    }

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

    function tryImageFallback() {
        if (media.kind !== "image" || media.fallbackTried || media.transcoding)
            return ;
        var target = String(media.m.url || media.m.thumbnail_url || "");
        if (!/^https?:/i.test(target))
            return ;
        // Only the live card may spawn processes; a preview renders passive
        // media and would double-fetch (and double-convert) the image.
        if (!media.host || media.host.live !== true || media.host.service === undefined)
            return ;
        media.fallbackTried = true;
        media.transcoding = true;
        imageFallbackProc.command = [media.host.service, "resolve", "--json", "--image", "--url", target];
        imageFallbackProc.running = true;
    }

    Component.onCompleted: media.startGif()
    onMChanged: {
        var previous = media.boundAudioUrl;
        if (previous !== "" && previous !== media.url)
            SocialAudio.stopIfCurrent(previous);
        media.boundAudioUrl = media.kind === "audio" ? media.url : "";
        if (previous !== "" && previous !== media.url) {
            media.resolvingAudio = false;
            media.audioResolveFailed = false;
            media.resolvedAudioUrl = "";
        }
        media.loadedRatio = 0;
        media.fallbackUrl = "";
        media.fallbackTried = false;
        media.transcoding = false;
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
        // A converted local file is the only decodable copy when WebP was the
        // source, so open that instead of failing at full resolution.
        var payload = media.m;
        if (media.fallbackUrl !== "") {
            payload = {
                "kind": "image",
                "url": media.fallbackUrl,
                "external_url": media.m.external_url || media.fallbackUrl,
                "thumbnail_url": media.fallbackUrl,
                "mime": media.fallbackUrl.toLowerCase().endsWith(".gif") ? "image/gif" : "image/jpeg",
                "width": media.m.width,
                "height": media.m.height,
                "alt": media.m.alt,
                "title": media.m.title
            };
        }
        var preview = media.fallbackUrl !== "" ? media.fallbackUrl : String(media.m.thumbnail_url || "");
        if (preview === "" && media.kind !== "video")
            preview = String(media.m.url || "");
        media.expandRequested(payload, Qt.rect(topLeft.x, topLeft.y, bottomRight.x - topLeft.x, bottomRight.y - topLeft.y),
                              preview,
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
            return (size / 1073741824).toFixed(1) + Tr.t(" GB");

        if (size >= 1048576)
            return (size / 1048576).toFixed(1) + Tr.t(" MB");

        if (size >= 1024)
            return Math.round(size / 1024) + Tr.t(" KB");

        return size + Tr.t(" B");
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
                source: media.kind === "image" && !media.animatedImage ? (media.imageThumb || media.imageUrl) : ""
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
                onStatusChanged: {
                    if (status === Image.Ready)
                        media.noteSourceSize(implicitWidth, implicitHeight);
                    else if (status === Image.Error)
                        media.tryImageFallback();
                }
                onImplicitWidthChanged: if (status === Image.Ready) media.noteSourceSize(implicitWidth, implicitHeight)
                onImplicitHeightChanged: if (status === Image.Ready) media.noteSourceSize(implicitWidth, implicitHeight)
            }

            AnimatedImage {
                anchors.fill: parent
                source: media.animatedImage ? (media.fallbackUrl || media.m.url || media.m.thumbnail_url) : ""
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
                onStatusChanged: {
                    if (status === Image.Ready)
                        media.noteSourceSize(implicitWidth, implicitHeight);
                    else if (status === Image.Error)
                        media.tryImageFallback();
                }
                onImplicitWidthChanged: if (status === Image.Ready) media.noteSourceSize(implicitWidth, implicitHeight)
                onImplicitHeightChanged: if (status === Image.Ready) media.noteSourceSize(implicitWidth, implicitHeight)
            }

            Column {
                anchors.centerIn: parent
                spacing: Theme.dp(6)
                visible: media.imageLoading || media.imageFailed

                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Theme.dp(58)
                    height: width

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: Theme.alpha(Theme.surfaceContainer, 0.88)
                    }

                    Icon {
                        anchors.centerIn: parent
                        visible: media.imageLoading
                        name: "image"
                        size: Theme.dp(24)
                        color: Theme.alpha(Theme.text, 0.35)
                    }

                    LoadingIndicator {
                        anchors.centerIn: parent
                        width: Theme.dp(40)
                        height: width
                        visible: running
                        running: media.imageLoading
                        color: Theme.primary
                    }

                    Icon {
                        anchors.centerIn: parent
                        visible: !media.imageLoading
                        name: "broken_image"
                        size: Theme.dp(27)
                        color: Theme.error
                    }

                }

                LText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: media.imageFailed
                    role: "labelSmall"
                    text: Tr.t("Could not load media")
                    color: Theme.error
                }

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
                    name: "fullscreen"
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
        // Keep the poster visible until the player really has a frame. A
        // GIF-like embed uses that time to animate its thumbnail instead of
        // flashing an empty card while the mp4 loads.
        readonly property bool frameReady: video.started && !video.videoFailed
            && (videoPlayer.playbackState === MediaPlayer.PlayingState
                || videoPlayer.playbackState === MediaPlayer.PausedState
                || videoPlayer.mediaStatus === MediaPlayer.EndOfMedia)
        readonly property bool showPoster: !video.frameReady && media.poster !== ""
        // Only real loading work counts. A video that has not started has no
        // poster to decode and nothing to buffer, so it should show its play
        // button instead of a permanent spinner.
        readonly property bool loading: media.kind === "video" && !video.frameReady && !video.videoFailed
            && (media.resolving
                || (video.started && (videoPlayer.playbackState !== MediaPlayer.PlayingState
                    || videoPlayer.mediaStatus === MediaPlayer.LoadingMedia
                    || videoPlayer.mediaStatus === MediaPlayer.BufferingMedia
                    || videoPlayer.mediaStatus === MediaPlayer.StalledMedia))
                || (video.showPoster && (videoPoster.status === Image.Loading
                    || videoPoster.status === Image.Error
                    || (media.gifPoster && videoPosterAnimation.status === Image.Error))))

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
                source: video.showPoster && !media.gifPoster ? media.poster : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                visible: video.showPoster && !media.gifPoster
            }

            AnimatedImage {
                id: videoPosterAnimation

                anchors.fill: parent
                source: video.showPoster && media.gifPoster ? media.poster : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
                playing: true
                loops: AnimatedImage.Infinite
                cache: true
                visible: video.showPoster && media.gifPoster
            }

            VideoOutput {
                id: videoOutput

                anchors.fill: parent
                fillMode: VideoOutput.PreserveAspectFit
                visible: video.frameReady
            }

            LoadingIndicator {
                anchors.centerIn: parent
                width: Theme.dp(48)
                height: width
                visible: running
                running: video.loading
                color: Theme.primary
            }

            Icon {
                anchors.centerIn: parent
                visible: media.kind === "video" && video.videoFailed && !video.frameReady
                name: "broken_image"
                size: Theme.dp(30)
                color: Theme.error
            }

            // The poster is the interaction surface until playback starts.
            Item {
                anchors.centerIn: parent
                width: Theme.dp(56)
                height: Theme.dp(56)
                visible: !video.loading
                    && (!video.started || videoPlayer.playbackState !== MediaPlayer.PlayingState)

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
                    name: video.started ? (videoPlayer.playbackState === MediaPlayer.PlayingState ? "pause" : "play_arrow") : "play_arrow"
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
                visible: video.failed && !video.frameReady && (!media.gifLike || media.poster === "")
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
                        text: Tr.t("Open video")
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
            onPlaybackStateChanged: {
                // A real video carries its own sound; mute the attachment player
                // instead of letting both tracks run together. GIF-like mp4s
                // are muted and should not interrupt a recording.
                if (videoPlayer.playbackState === MediaPlayer.PlayingState && !media.gifLike)
                    SocialAudio.pause();
            }
        }

    }

    // ------------------------------------------------------------------ audio
    Rectangle {
        id: audio

        anchors.fill: parent
        visible: media.kind === "audio"
        radius: Theme.rad(18)
        color: Theme.surfaceHigh
        border.width: 1
        border.color: Theme.alpha(media.ink, 0.1)

        readonly property bool current: media.kind === "audio" && SocialAudio.isCurrent(media.audioUrl)
        readonly property bool playing: audio.current && SocialAudio.playing
        readonly property bool failed: (audio.current && SocialAudio.failed) || media.audioResolveFailed
        readonly property bool started: audio.current && SocialAudio.started
        readonly property real progress: audio.current ? SocialAudio.progress : 0
        readonly property int shownDuration: audio.current && SocialAudio.duration > 0
            ? SocialAudio.duration
            : Number(media.m.duration_ms || 0)

        RowLayout {
            anchors.fill: parent
            anchors.margins: Theme.dp(12)
            spacing: Theme.dp(10)

            Rectangle {
                id: audioButton

                Layout.preferredWidth: Theme.dp(38)
                Layout.preferredHeight: Theme.dp(38)
                radius: Theme.dp(19)
                color: audio.playing ? Theme.primary : Theme.primaryContainer
                clip: true

                Image {
                    anchors.fill: parent
                    source: String(media.m.thumbnail_url || "")
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    cache: true
                    visible: source !== "" && !audio.playing
                }

                Rectangle {
                    anchors.fill: parent
                    color: Theme.alpha(Theme.scrim, 0.35)
                    visible: String(media.m.thumbnail_url || "") !== ""
                }

                LoadingIndicator {
                    anchors.centerIn: parent
                    width: Theme.dp(20)
                    height: width
                    visible: running
                    running: media.resolvingAudio
                    color: Theme.primary
                }

                Icon {
                    anchors.centerIn: parent
                    visible: !media.resolvingAudio
                    name: audio.failed ? "open_in_new" : (audio.playing ? "pause" : "play_arrow")
                    size: Theme.dp(19)
                    color: audio.playing ? Theme.fgPrimary : Theme.primary
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (media.url === "" || media.audioResolveFailed) {
                            media.openExternal();
                            return ;
                        }
                        if (media.directAudio || media.resolvedAudioUrl !== "" || media.host === null || media.host.service === undefined) {
                            SocialAudio.toggle(media.audioUrl, media.m.title || media.m.filename || Tr.t("Audio"));
                            return ;
                        }
                        if (media.resolvingAudio)
                            return ;
                        media.resolvingAudio = true;
                        media.audioResolveFailed = false;
                        audioResolveProc.command = [media.host.service, "resolve", "--json", "--url", media.url];
                        audioResolveProc.running = true;
                    }
                }

                Behavior on color {
                    ColorAnimation {
                        duration: Theme.durFastEffects
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(4)

                LText {
                    Layout.fillWidth: true
                    role: "labelLarge"
                    text: media.m.title || media.m.filename || Tr.t("Audio")
                    color: media.ink
                    elide: Text.ElideMiddle
                }

                LText {
                    Layout.fillWidth: true
                    role: "labelSmall"
                    visible: text !== ""
                    text: String(media.m.alt || media.m.external_url || "").replace(/^https?:\/\//, "").split("/")[0]
                    color: Theme.alpha(media.ink, 0.58)
                    elide: Text.ElideRight
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.dp(3)
                    radius: height / 2
                    color: Theme.alpha(media.ink, 0.14)

                    Rectangle {
                        width: parent.width * audio.progress
                        height: parent.height
                        radius: parent.radius
                        color: Theme.primary
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (audio.current)
                                SocialAudio.seek(mouse.x / width);
                        }
                    }
                }
            }

            Column {
                Layout.alignment: Qt.AlignVCenter
                spacing: 1

                LText {
                    role: "labelSmall"
                    tabular: true
                    text: audio.shownDuration > 0
                        ? (audio.started
                            ? media.clock(SocialAudio.position) + " / " + media.clock(audio.shownDuration)
                            : media.clock(audio.shownDuration))
                        : "--:--"
                    color: Theme.alpha(media.ink, 0.72)
                }

                LText {
                    role: "labelSmall"
                    text: media.formatBytes(media.m.size_bytes)
                    color: Theme.alpha(media.ink, 0.52)
                    visible: text !== ""
                }

            }

            Item {
                Layout.preferredWidth: Theme.dp(18)
                Layout.preferredHeight: Theme.dp(18)
                Layout.alignment: Qt.AlignVCenter

                Icon {
                    anchors.centerIn: parent
                    name: "open_in_new"
                    size: Theme.dp(16)
                    color: Theme.alpha(media.ink, 0.55)
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: media.openExternal()
                }
            }

        }

    }

    Process {
        id: imageFallbackProc

        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: {
                media.transcoding = false;
                try {
                    var value = JSON.parse(this.text);
                    var target = String(value.url || "");
                    if (value.ok === true && target !== ""
                            && target !== String(media.m.url || "")
                            && target !== String(media.m.thumbnail_url || ""))
                        media.fallbackUrl = target;
                } catch (error) {
                }
            }
        }

        onExited: (code) => {
            if (code !== 0)
                media.transcoding = false;
        }
    }

    Process {
        id: audioResolveProc

        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: {
                media.resolvingAudio = false;
                try {
                    var value = JSON.parse(this.text);
                    if (value.ok === true && String(value.url || "") !== "") {
                        media.resolvedAudioUrl = String(value.url);
                        SocialAudio.toggle(media.audioUrl, media.m.title || media.m.filename || Tr.t("Audio"));
                    } else {
                        media.audioResolveFailed = true;
                    }
                } catch (error) {
                    media.audioResolveFailed = true;
                }
            }
        }

        onExited: (code) => {
            if (code !== 0) {
                media.resolvingAudio = false;
                media.audioResolveFailed = true;
            }
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
                    text: media.m.filename || media.m.title || Tr.t("Attachment")
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
                visible: media.poster !== "" && linkPoster.status !== Image.Error

                Image {
                    id: linkPoster

                    anchors.fill: parent
                    source: media.kind === "link" || media.kind === "embed" ? media.poster : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    visible: status !== Image.Error
                }

                LoadingIndicator {
                    anchors.centerIn: parent
                    width: Theme.dp(22)
                    height: width
                    visible: running
                    running: linkPoster.status === Image.Loading
                    color: Theme.primary
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


    // Copy/download for video, audio, files and embeds. Images keep their
    // expand control; the lightbox has the same cluster in its top-right.
    MediaActions {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Theme.dp(8)
        z: 20
        visible: media.kind !== "image" && media.kind !== "link" && media.kind !== "embed"
        copyUrl: media.kind === "link" || media.kind === "embed" ? media.link : media.url
        downloadUrl: media.url
        filename: String(media.m.filename || "")
        mediaKind: media.kind
        posterUrl: media.poster
        buttonVariant: "filled"
        buttonSize: "s"
        compact: false
    }

}

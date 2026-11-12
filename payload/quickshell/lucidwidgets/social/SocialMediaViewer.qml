import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs
import qs.lucidui
import "../../squircle"

// A full-screen lightbox for one picture or video. It grows from the card's
// own screen rectangle into the middle of the screen and shrinks back into it,
// with M3's spatial curve and generous breathing room around the media.
PanelWindow {
    id: viewer

    property var value: null
    property rect from: Qt.rect(0, 0, 0, 0)
    property bool open: false
    property var screenObj: null
    property string service: ""
    // The card's already-decoded image and its decode size. Painting it under
    // the full-res image hides the second load behind the reveal.
    property string previewSource: ""
    property real previewWidth: 0
    property real previewHeight: 0
    // The visible feed/thread viewport in the same coordinates as `from`.
    // Once the return animation reaches 20% of the opened size, the shrinking
    // media is clipped to this rectangle so it cannot spill over the widget.
    property rect clipRect: Qt.rect(0, 0, 0, 0)
    property bool returning: false

    property bool shown: false
    property real reveal: 0
    property bool resolving: false
    property bool failed: false
    // True while playback should be running. A resolved source can finish
    // loading after start() returns, so this keeps the player honest until the
    // media is ready instead of needing a second click.
    property bool wantsPlay: false
    // Loading a resolved stream (or an HLS playlist) can take a moment; keep
    // showing progress until it can actually play so the play glyph does not
    // look like a prompt for a second click.
    readonly property bool loading: viewer.resolving
        || player.mediaStatus === MediaPlayer.LoadingMedia
        || player.mediaStatus === MediaPlayer.StalledMedia

    signal closeRequested()
    signal dismissed()

    readonly property var m: viewer.value || ({})
    readonly property bool isVideo: String(m.kind || "") === "video"
    readonly property bool inlineVideo: {
        var target = String(m.url || "").toLowerCase().split("?")[0];
        return target.startsWith("file://") || /\.(mp4|webm|m3u8|mov|mkv|ogv)$/.test(target);
    }
    readonly property bool gifLike: {
        var target = (String(m.url || "") + " " + String(m.external_url || "") + " " + String(m.mime || "")).toLowerCase();
        return target.indexOf("tenor.com") >= 0
            || target.indexOf("klipy.com") >= 0
            || target.indexOf("giphy.com") >= 0
            || String(m.mime || "").toLowerCase() === "image/gif"
            || /\.gif(\?|$)/.test(target);
    }
    readonly property real aspect: {
        var w = Number(m.width || 0);
        var h = Number(m.height || 0);
        if (w > 0 && h > 0)
            return w / h;
        // The card learns the real aspect from the decoded image when the
        // embed has no metadata; use the preview box it handed us.
        if (viewer.previewWidth > 0 && viewer.previewHeight > 0)
            return viewer.previewWidth / viewer.previewHeight;
        return 16 / 9;
    }
    readonly property rect targetRect: {
        var sw = viewer.screenObj ? viewer.screenObj.width : 1920;
        var sh = viewer.screenObj ? viewer.screenObj.height : 1080;
        // Very generous gutters: 10% of the screen on each side, never less
        // than 64 logical pixels.
        var side = Math.max(Theme.dp(64), Math.floor(sw * 0.10));
        var top = Math.max(Theme.dp(64), Math.floor(sh * 0.10));
        var maxW = Math.max(1, sw - side * 2);
        var maxH = Math.max(1, sh - top * 2);
        var w = maxW;
        var h = w / viewer.aspect;
        if (h > maxH) {
            h = maxH;
            w = h * viewer.aspect;
        }
        return Qt.rect(Math.round((sw - w) / 2), Math.round((sh - h) / 2), Math.round(w), Math.round(h));
    }
    readonly property rect startRect: viewer.from.width > 1 && viewer.from.height > 1 ? viewer.from : viewer.targetRect
    readonly property string imageSource: String(viewer.m.url || viewer.m.thumbnail_url || "")
    readonly property string videoSource: String(viewer.m.url || viewer.m.external_url || "")
    readonly property string resolveSource: String(viewer.m.external_url || viewer.m.url || "")

    screen: viewer.screenObj
    color: "transparent"
    visible: viewer.shown
    anchors.top: true
    anchors.bottom: true
    anchors.left: true
    anchors.right: true
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "lucid-media-viewer"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    onOpenChanged: {
        if (viewer.open) {
            viewer.failed = false;
            viewer.returning = false;
            viewer.shown = true;
            viewer.reveal = 0;
            revealAnim.stop();
            revealAnim.to = 1;
            revealAnim.restart();
            Qt.callLater(viewer.start);
        } else if (viewer.shown) {
            viewer.returning = true;
            revealAnim.stop();
            revealAnim.to = 0;
            revealAnim.restart();
        }
    }
    onValueChanged: {
        viewer.failed = false;
        if (viewer.open && viewer.shown) {
            viewer.reveal = 0;
            revealAnim.stop();
            revealAnim.to = 1;
            revealAnim.restart();
            Qt.callLater(viewer.start);
        }
    }

    function start() {
        if (!viewer.open)
            return ;
        if (!viewer.isVideo) {
            viewer.resolving = false;
            viewer.wantsPlay = false;
            return ;
        }
        viewer.failed = false;
        viewer.wantsPlay = true;
        if (viewer.inlineVideo) {
            player.source = viewer.videoSource;
            player.play();
            return ;
        }
        if (viewer.service === "" || viewer.resolveSource === "") {
            viewer.failed = true;
            return ;
        }
        viewer.resolving = true;
        resolveProc.command = [viewer.service, "resolve", "--json", "--url", viewer.resolveSource];
        resolveProc.running = true;
    }

    function stop() {
        viewer.wantsPlay = false;
        player.pause();
        player.source = "";
        viewer.resolving = false;
        resolveProc.running = false;
    }

    function togglePlay() {
        if (!viewer.isVideo || viewer.resolving || viewer.failed)
            return ;
        if (player.playbackState === MediaPlayer.PlayingState) {
            viewer.wantsPlay = false;
            player.pause();
        } else {
            viewer.wantsPlay = true;
            player.play();
        }
    }

    NumberAnimation {
        id: revealAnim

        target: viewer
        property: "reveal"
        duration: Theme.durLong
        easing.type: Easing.Bezier
        easing.bezierCurve: Theme.curveDefaultSpatial
        onFinished: {
            if (!viewer.open) {
                viewer.shown = false;
                viewer.returning = false;
                viewer.stop();
                viewer.dismissed();
            }
        }
    }

    // The scrim dims the desktop and is the click-outside target.
    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
        opacity: viewer.reveal

        MouseArea {
            anchors.fill: parent
            onClicked: viewer.closeRequested()
        }
    }

    // The return is clipped to the card viewport once the media has shrunk to
    // 20% of its opened size, so a feed image cut off by the viewport is cut
    // off the same way while it flies back.
    Item {
        id: clipBox

        readonly property bool clipping: viewer.returning && cardBox.s <= 0.2
            && viewer.clipRect.width > 1 && viewer.clipRect.height > 1

        x: clipping ? viewer.clipRect.x : 0
        y: clipping ? viewer.clipRect.y : 0
        width: clipping ? viewer.clipRect.width : parent.width
        height: clipping ? viewer.clipRect.height : parent.height
        clip: true
        visible: viewer.shown

        // The growing container. Its size is fixed at the lightbox's final rect;
        // only its centre and scale animate. Scaling around the container's own
        // centre puts the transform's origin at the picture's centre on the widget,
        // so at reveal 0 the container sits exactly over the inline media and the
        // picture grows out of the spot the user tapped.
        Item {
            id: cardBox

        width: Math.max(1, viewer.targetRect.width)
        height: Math.max(1, viewer.targetRect.height)
        visible: viewer.shown
        transformOrigin: Item.Center

        readonly property real startScale: {
            if (viewer.startRect.width < 1 || viewer.targetRect.width < 1)
                return 1;
            return Math.max(0.02, viewer.startRect.width / viewer.targetRect.width);
        }
        readonly property real startCX: viewer.startRect.x + viewer.startRect.width / 2
        readonly property real startCY: viewer.startRect.y + viewer.startRect.height / 2
        readonly property real endCX: viewer.targetRect.x + viewer.targetRect.width / 2
        readonly property real endCY: viewer.targetRect.y + viewer.targetRect.height / 2
        readonly property real cx: startCX + (endCX - startCX) * viewer.reveal
        readonly property real cy: startCY + (endCY - startCY) * viewer.reveal
        readonly property real s: startScale + (1 - startScale) * viewer.reveal
        readonly property real visualW: width * s
        readonly property real visualH: height * s
        // the corner should look 20 px at the source and 32 px at rest, so
        // compensate for the container's own scale while it grows
        readonly property real visualRadius: Theme.rad(20 + 12 * viewer.reveal)

        x: Math.round(cx - width / 2) - clipBox.x
        y: Math.round(cy - height / 2) - clipBox.y
        scale: s

        SquircleRect {
            id: card

            anchors.fill: parent
            radius: cardBox.visualRadius / Math.max(0.01, cardBox.s)
            fillColor: Theme.surfaceContainer
            borderWidth: 1
            borderColor: Theme.alpha(Theme.text, 0.12)
            smoothing: Prefs.squircleF
        }

        SquircleClip {
            id: clip

            anchors.fill: card
            radius: card.radius
            color: Theme.surfaceContainer
            smoothing: Prefs.squircleF

            Image {
                // The exact texture the card decoded. Same URL and same sourceSize,
                // so this is a pixmap-cache hit, not another download.
                anchors.fill: parent
                visible: !viewer.isVideo && (viewer.gifLike ? fullGif.status !== Image.Ready : fullImage.status !== Image.Ready) && source !== ""
                source: viewer.isVideo ? "" : viewer.previewSource
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: true
                smooth: true
                mipmap: true
                sourceSize.width: viewer.previewWidth > 0 ? Math.round(viewer.previewWidth) : Math.max(1, Math.round(viewer.targetRect.width * 2))
                sourceSize.height: viewer.previewHeight > 0 ? Math.round(viewer.previewHeight) : Math.max(1, Math.round(viewer.targetRect.height * 2))
            }

            Image {
                id: fullImage

                anchors.fill: parent
                visible: !viewer.isVideo && !viewer.gifLike
                source: viewer.isVideo || viewer.gifLike ? "" : viewer.imageSource
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
                mipmap: true
                opacity: status === Image.Ready ? 1 : 0
                sourceSize.width: Math.max(1, Math.round(viewer.targetRect.width * 2))
                sourceSize.height: Math.max(1, Math.round(viewer.targetRect.height * 2))

                Behavior on opacity {
                    NumberAnimation {
                        duration: Theme.durShort
                    }

                }

            }

            AnimatedImage {
                id: fullGif

                anchors.fill: parent
                visible: !viewer.isVideo && viewer.gifLike
                source: !viewer.isVideo && viewer.gifLike ? viewer.imageSource : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
                mipmap: true
                playing: visible
                loops: AnimatedImage.Infinite
                cache: true
                opacity: status === Image.Ready ? 1 : 0
                sourceSize.width: Math.max(1, Math.round(viewer.targetRect.width * 2))
                sourceSize.height: Math.max(1, Math.round(viewer.targetRect.height * 2))

                Behavior on opacity {
                    NumberAnimation {
                        duration: Theme.durShort
                    }

                }

            }

            VideoOutput {
                id: output

                anchors.fill: parent
                visible: viewer.isVideo
                fillMode: VideoOutput.PreserveAspectFit
            }

            Icon {
                anchors.centerIn: parent
                visible: viewer.isVideo && (viewer.loading || viewer.failed || player.playbackState !== MediaPlayer.PlayingState)
                name: viewer.loading ? "hourglass_top" : (viewer.failed ? "open_in_new" : "play_arrow")
                size: Theme.dp(48) / Math.max(0.2, cardBox.s)
                color: Theme.text
            }

            LText {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: Theme.dp(16) / Math.max(0.2, cardBox.s)
                visible: viewer.failed
                horizontalAlignment: Text.AlignHCenter
                role: "labelLarge"
                text: Tr.t("This video could not be opened")
                color: Theme.text
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (viewer.failed) {
                        if (viewer.resolveSource !== "" && viewer.service !== "") {
                            viewer.failed = false;
                            viewer.start();
                        } else {
                            var r = viewer.from;
                            var s = viewer.screenObj;
                            var rect = null;
                            if (r && r.width > 0 && r.height > 0)
                                rect = {
                                    "x": (s ? s.x : 0) + r.x,
                                    "y": (s ? s.y : 0) + r.y,
                                    "width": r.width,
                                    "height": r.height
                                };
                            Launch.openUrl(viewer.resolveSource, {
                                "rect": rect,
                                "screen": s,
                                "timeoutMs": 2500
                            });
                        }
                        return ;
                    }
                    viewer.togglePlay();
                }
            }
        }
    }
    }

    // A close control that rides just inside the media's top-right corner.
    IconButton {
        icon: "close"
        variant: "filled"
        size: "s"
        width: implicitWidth
        height: implicitHeight
        x: Math.round(cardBox.cx + cardBox.visualW / 2 - width - Theme.dp(12))
        y: Math.round(cardBox.cy - cardBox.visualH / 2 + Theme.dp(12))
        z: 10
        opacity: Math.max(0, Math.min(1, (viewer.reveal - 0.25) / 0.4))
        visible: viewer.shown && opacity > 0
        onClicked: viewer.closeRequested()
    }

    MediaPlayer {
        id: player

        source: ""
        autoPlay: true
        loops: viewer.gifLike ? MediaPlayer.Infinite : 1
        videoOutput: output
        audioOutput: AudioOutput {
            muted: viewer.gifLike
        }
        // Some streams (HLS manifests in particular) finish loading after the
        // source is assigned, and a play() issued at that moment is dropped.
        // Once the media is ready, resume if the viewer still wants playback.
        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.EndOfMedia) {
                if (!viewer.gifLike)
                    viewer.wantsPlay = false;
                return ;
            }
            if (!viewer.wantsPlay || viewer.resolving)
                return ;
            if (mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia || mediaStatus === MediaPlayer.BufferingMedia) {
                if (playbackState !== MediaPlayer.PlayingState)
                    player.play();
            }
        }
        onErrorOccurred: (error, errorString) => {
            if (error !== MediaPlayer.NoError)
                viewer.failed = true;
        }
    }

    Process {
        id: resolveProc

        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: {
                viewer.resolving = false;
                try {
                    var value = JSON.parse(this.text);
                    if (value.ok === true && String(value.url || "") !== "") {
                        viewer.failed = false;
                        player.source = String(value.url);
                        player.play();
                    } else {
                        viewer.failed = true;
                    }
                } catch (error) {
                    viewer.failed = true;
                }
            }
        }

        onExited: (code) => {
            if (code !== 0) {
                viewer.resolving = false;
                viewer.failed = true;
            }
        }
    }
}

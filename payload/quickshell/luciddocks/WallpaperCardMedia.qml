import QtQuick
import qs

// One wallpaper card's picture.
//
// A still uses its thumbnail (or the original while the thumbnail is being
// cut); a video or Wallpaper Engine scene plays the short preview skwd-wall or
// the Workshop author provided, but only while the card is selected or hovered.
//
// Web results reuse it: their thumb is an https URL and their path is virtual.
// A Wallhaven card also carries the full image in `preview`; it is loaded only
// while that card is the current selection, so the 432px thumbnail is not what
// you stare at in the hero slot.
Item {
    id: media

    property string path: ""
    property string thumb: ""
    property string preview: ""
    property string kind: ""
    property bool active: false
    // the selected card, not merely hovered: only this one loads a full image
    property bool current: false
    // extra width either side of the card, for the strip's parallax pan
    property real overscan: 0
    property real parallax: 0
    property int sourceSizeWidth: 680
    property int sourceSizeHeight: 422
    // Ask for the cached thumbnail even on the selected card. The slot
    // styles decode at 640x400, below the 680x422 cut, so the original adds
    // nothing there; the strip only sets this while it is moving.
    property bool preferThumb: false
    // the real image's dimensions, for Web results whose thumbnail is a
    // pre-cropped 16:9 preview
    property int sourceWidth: 0
    property int sourceHeight: 0

    readonly property bool virtualPath: /^(wh:|skwd:|more:)/.test(path)
    readonly property bool moving: kind === "video" || kind === "we" || kind === "steam" || /\.(mp4|webm|mkv|mov|m4v)$/i.test(path)
    readonly property bool hasPreview: moving && preview !== ""
    readonly property bool isMore: kind === "more"
    readonly property bool isStatus: kind === "status"
    readonly property bool hires: kind === "wallhaven" && preview !== ""
    // Wallhaven's large thumbnail is a centred 16:9 crop of the original. The
    // full image has to be cropped the same way before it is laid over that
    // thumbnail, or a 4:3/3:2 wallpaper visibly changes framing the moment the
    // selected card loads its real image.
    //
    // sourceClipRect is in the *decoded* image's coordinates: sourceSize is
    // applied first, then the clip is cut out of that. Using the original
    // pixel size here made portrait/4:3 web results ask for a rect far outside
    // the 640x400 decode, which Qt rendered as a tiny picture in the card's
    // top-left corner. Scale the crop into the same space sourceSize decodes
    // to; PreserveAspectCrop covers that box, so the decode is at least as
    // large as the requested one on both axes.
    readonly property rect hiresClip: {
        if (sourceWidth <= 0 || sourceHeight <= 0 || sourceSizeWidth <= 0 || sourceSizeHeight <= 0)
            return Qt.rect(0, 0, 0, 0);
        const scale = Math.min(1, Math.max(sourceSizeWidth / sourceWidth, sourceSizeHeight / sourceHeight));
        const dw = Math.max(1, Math.round(sourceWidth * scale));
        const dh = Math.max(1, Math.round(sourceHeight * scale));
        const want = 16 / 9;
        if (dw / dh > want) {
            const w = Math.round(dh * want);
            return Qt.rect(Math.round((dw - w) / 2), 0, w, dh);
        }
        const h = Math.round(dw / want);
        return Qt.rect(0, Math.round((dh - h) / 2), dw, h);
    }
    // Stills normally decode the original at the card's decode size, because a
    // 680px thumb reads soft in the strip's 1:2 hero on a 2x display. Sources
    // whose thumb is already large enough (the slot styles' 640x400) pass
    // preferThumb, and the strip passes it while an arrow is still moving: a
    // full-size decode of a 10-20 MB original costs ~80 ms on this library,
    // while the cached jpg cut costs a few ms and is what the eye sees during
    // the 300 ms slide anyway.
    //
    // A webp thumb is unusable on a Qt without qt6-imageformats, so it must
    // never be selected: that was the empty-card path in the first attempt at
    // this. Virtual items and the load-more row have no local original.
    readonly property bool thumbUsable: thumb !== "" && !/\.webp$/i.test(thumb)
    readonly property string still: (thumbUsable && (preferThumb || !current)) ? thumb : ((moving || virtualPath) ? (thumbUsable ? thumb : "") : (path !== "" ? path : (thumbUsable ? thumb : "")))

    // download state from RemoteWall, keyed by this card's path
    readonly property var download: RemoteWall.downloadFor(path)
    readonly property bool busy: download !== null && ["starting", "downloading", "waiting", "applying"].indexOf(String(download.state)) >= 0
    readonly property bool failed: download !== null && download.state === "error"
    readonly property real progress: download !== null && download.progress !== undefined ? Number(download.progress) : 0
    readonly property real total: download !== null && download.total !== undefined ? Number(download.total) : 0
    readonly property string statusText: {
        if (download === null)
            return "";
        if (download.state === "starting")
            return Tr.t("Starting");
        if (download.state === "downloading")
            return media.total > 0 ? Tr.fmt("Downloading %1%", Math.round(media.progress / media.total * 100)) : Tr.t("Downloading");
        if (download.state === "waiting")
            return download.message || Tr.t("Subscribe in Steam");
        if (download.state === "applying")
            return Tr.t("Applying");
        if (download.state === "error")
            return download.message || Tr.t("Download failed");
        if (download.state === "done")
            return Tr.t("Ready");
        return "";
    }

    function url(p) {
        if (p === "")
            return "";
        if (p.indexOf("http://") === 0 || p.indexOf("https://") === 0)
            return p;
        return "file://" + p.split("/").map(encodeURIComponent).join("/");
    }

    // a failed remote thumbnail leaves the card's own colour, not a broken
    // image icon or a hole in the strip
    Rectangle {
        anchors.fill: parent
        color: Theme.bgSunken
        visible: media.still === "" || image.status !== Image.Ready
    }

    Image {
        id: image

        anchors.verticalCenter: parent.verticalCenter
        width: parent.width + media.overscan * 2
        height: parent.height
        x: -media.overscan - media.parallax
        source: media.url(media.still)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: media.sourceSizeWidth
        sourceSize.height: media.sourceSizeHeight
        visible: media.still !== "" && status === Image.Ready
    }

    // the full-size Wallhaven image, only on the selected card. It lands over
    // the thumbnail and fades in when decoded; no layout change.
    Image {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width + media.overscan * 2
        height: parent.height
        x: -media.overscan - media.parallax
        source: media.hires && media.current ? media.url(media.preview) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: media.sourceSizeWidth
        sourceSize.height: media.sourceSizeHeight
        // empty rect (0,0,0,0) leaves the source whole for anything that is
        // not a Wallhaven result with known dimensions
        sourceClipRect: media.hires ? media.hiresClip : Qt.rect(0, 0, 0, 0)
        visible: source !== "" && status === Image.Ready
    }

    Loader {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width + media.overscan * 2
        height: parent.height
        x: -media.overscan - media.parallax
        active: media.active && media.hasPreview
        sourceComponent: AnimatedImage {
            source: media.url(media.preview)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            // no frame cache: a 30-frame 720p preview would hold ~110 MB per
            // card, and every card that becomes current would add one
            playing: true
        }
    }

    Text {
        anchors.centerIn: parent
        visible: media.isMore
        text: Tr.t("Load more")
        color: Theme.subtext
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontLabelLg
        font.weight: Font.DemiBold
        font.variableAxes: Theme.axes(Theme.fontLabelLg, 420, 0)
    }

    // the fetching placeholder lives in a card slot where the next preview
    // would be; no pill, no separate overlay
    Column {
        anchors.centerIn: parent
        spacing: Theme.dp(8)
        visible: media.isStatus

        Loader {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Theme.dp(28)
            height: Theme.dp(28)
            active: media.isStatus
            source: "translate/components/LoadingMorph.qml"
            onLoaded: {
                item.size = Theme.dp(28);
                item.color = Theme.accent;
                item.running = true;
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: RemoteWall.latest ? Tr.t("Loading latest") : (RemoteWall.items.length === 0 ? Tr.t("Searching") : Tr.t("Loading more"))
            color: Theme.subtext
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontLabelLg
            font.weight: Font.DemiBold
            font.variableAxes: Theme.axes(Theme.fontLabelLg, 420, 0)
        }

    }

    // download / subscribe progress, drawn over the preview for both sources
    Rectangle {
        anchors.fill: parent
        color: Theme.alpha(Theme.cShadow, 0.68)
        visible: media.busy || media.failed

        Column {
            anchors.centerIn: parent
            spacing: Theme.dp(7)

            Loader {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Theme.dp(26)
                height: Theme.dp(26)
                active: media.busy
                source: "translate/components/LoadingMorph.qml"
                onLoaded: {
                    item.size = Theme.dp(26);
                    item.color = "white";
                    item.running = true;
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(Theme.dp(160), parent.parent.width - Theme.dp(20))
                text: media.statusText
                color: "white"
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontLabelSm
                font.weight: Font.DemiBold
                font.variableAxes: Theme.axes(Theme.fontLabelSm, 420, 0)
            }

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Theme.dp(96)
                height: Theme.dp(4)
                radius: Theme.pill(height)
                color: Theme.alpha("white", 0.24)
                visible: media.download !== null && media.download.state === "downloading" && media.total > 0

                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, media.progress / Math.max(1, media.total)))
                    height: parent.height
                    radius: parent.radius
                    color: "white"
                }

            }

        }

    }

}

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

    readonly property bool virtualPath: /^(wh:|skwd:|more:)/.test(path)
    readonly property bool moving: kind === "video" || kind === "we" || kind === "steam" || /\.(mp4|webm|mkv|mov|m4v)$/i.test(path)
    readonly property bool hasPreview: moving && preview !== ""
    readonly property bool isMore: kind === "more"
    readonly property bool isStatus: kind === "status"
    readonly property bool hires: kind === "wallhaven" && preview !== ""
    // Stills decode the original at the card's decode size: the cached thumb is
    // 680px wide and reads soft in the 1:2 hero card on a 2x display. Videos
    // keep their first-frame thumb until the animated preview takes over.
    // A virtual item (or the load-more row) never has a local file to fall back
    // to, so its thumbnail is the picture.
    //
    // The thumbs are skwd's webp cuts here, and this Qt has no webp image
    // plugin (qt6-imageformats), so a still never falls back to its thumb: it
    // would draw an empty card. The picker's `near` gate is what keeps only a
    // handful of originals decoded at a time.
    readonly property string still: (moving || virtualPath) ? (thumb !== "" ? thumb : "") : (path !== "" ? path : thumb)

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
            return "Starting";
        if (download.state === "downloading")
            return media.total > 0 ? "Downloading " + Math.round(media.progress / media.total * 100) + "%" : "Downloading";
        if (download.state === "waiting")
            return download.message || "Subscribe in Steam";
        if (download.state === "applying")
            return "Applying";
        if (download.state === "error")
            return download.message || "Download failed";
        if (download.state === "done")
            return "Ready";
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
        text: "Load more"
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
            text: RemoteWall.latest ? "Loading latest" : (RemoteWall.items.length === 0 ? "Searching" : "Loading more")
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

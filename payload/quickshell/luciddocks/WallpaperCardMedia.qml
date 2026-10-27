import QtQuick
import qs

// One wallpaper card's picture. A still uses its thumbnail (or the original
// while the thumbnail is being cut); a video or Wallpaper Engine scene plays
// the short animated WebP preview skwd-wall cuts for it, but only while the
// card is selected or hovered, so a grid of a hundred videos stays idle.
Item {
    id: media

    property string path: ""
    property string thumb: ""
    property string preview: ""
    property string kind: ""
    property bool active: false
    // extra width either side of the card, for the strip's parallax pan
    property real overscan: 0
    property real parallax: 0
    property int sourceSizeWidth: 680
    property int sourceSizeHeight: 422

    readonly property bool moving: kind === "video" || kind === "we" || /\.(mp4|webm|mkv|mov|m4v)$/i.test(path)
    readonly property bool hasPreview: moving && preview !== ""
    // Stills decode the original at the card's decode size: the cached thumb is
    // 680px wide and reads soft in the 1:2 hero card on a 2x display. Videos
    // keep their first-frame thumb until the animated preview takes over.
    readonly property string still: moving ? (thumb !== "" ? thumb : "") : (path !== "" ? path : thumb)

    function url(p) {
        return p === "" ? "" : "file://" + p.split("/").map(encodeURIComponent).join("/");
    }

    Image {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width + media.overscan * 2
        height: parent.height
        x: -media.overscan - media.parallax
        source: media.url(media.still)
        fillMode: Image.PreserveAspectCrop
        asynchronous: !media.moving && media.path !== ""
        cache: true
        sourceSize.width: media.sourceSizeWidth
        sourceSize.height: media.sourceSizeHeight
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
            cache: true
            playing: true
        }
    }
}

import QtQuick
import qs

// The wallpaper picker as a row of pills: every wallpaper a narrow pill, the one
// under the selection opens into a card and its neighbours give way. The pills'
// height is a setting (Settings -> Theme -> Pill shape):
//   uniform  all alike, a little shorter than the card
//   full     the whole height of the panel, from edge to edge, like an accordion
//   wave     as tall as a bell around the card, falling away towards the edges
WallpaperSlots {
    id: root

    readonly property string shape: Prefs.wallpaperPillsShape === "full" || Prefs.wallpaperPillsShape === "wave" ? Prefs.wallpaperPillsShape : "uniform"
    // Dock.qml's wallPillsWidth sizes the panel from these, keep the two together
    readonly property real pillW: root.shape === "wave" ? 40 : 52
    readonly property real fullPillMax: 64
    readonly property real openW: root.shape === "full" ? Math.max(root.heroW, Math.round(root.width * 0.4)) : (root.shape === "wave" ? Math.round(root.heroW * 0.9) : root.heroW)
    // the pills in view besides the card: as many as there are when they fit,
    // so a short folder is one row with no empty places on either side
    readonly property int slims: Math.min(Math.max(0, root.count - 1), root.shape === "full" ? 16 : Math.max(2, Math.floor((root.width - root.openW + root.itemGap) / (root.pillW + root.itemGap))))
    // full fills the panel, so its pills share whatever the card leaves; the others keep their width
    readonly property real slimW: root.shape === "full" ? Math.max(Theme.dp(8), Math.min(root.fullPillMax, (root.width - root.openW - root.slims * root.itemGap) / Math.max(1, root.slims))) : root.pillW
    readonly property real rowStart: Math.round((root.width - root.openW - root.slims * (root.slimW + root.itemGap)) / 2)
    // the first wallpaper in view: the card stays in the middle until the row
    // reaches an end, then it moves towards that end instead of leaving a gap
    readonly property int first: Math.max(0, Math.min(root.count - 1 - root.slims, root.currentIndex - Math.floor(root.slims / 2)))

    function pillX(offset) {
        var k = root.currentIndex + offset - root.first;
        if (k < 0)
            return -root.slimW;

        if (k > root.slims)
            return root.width;

        return root.rowStart + k * (root.slimW + root.itemGap) + (offset > 0 ? root.openW - root.slimW : 0);
    }

    slotRect: function (offset) {
        var n = Math.abs(offset);
        var open = offset === 0;
        var h = root.stageH;
        if (root.shape === "uniform")
            h = open ? root.heroH : Math.round(root.heroH * 0.62);
        else if (root.shape === "wave" && !open)
            h = Math.round(root.stageH * (0.2 + 0.58 * Math.exp(-(offset * offset) / (2 * 3.2 * 3.2))));
        var fade = root.shape === "full" ? 0.06 : (root.shape === "wave" ? 0.07 : 0.045);
        return {
            "x": root.pillX(offset),
            "y": Math.round((root.stageH - h) / 2),
            "w": open ? root.openW : root.slimW,
            "h": h,
            "r": open ? Theme.radiusXl : Theme.pill(root.slimW),
            "o": (root.currentIndex + offset < root.first || root.currentIndex + offset > root.first + root.slims) ? 0 : (open ? 1 : Math.max(0.4, 0.92 - fade * (n - 1)))
        };
    }
}

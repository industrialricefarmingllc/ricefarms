import QtQuick

// One small looping preview clip (a baked Wallpaper Engine transcode -
// small mp4, not the full wallpaper). Loader-isolated exactly like
// WallpaperVideoSurface: importing QtMultimedia directly would fail the
// whole shell on machines without it, so the player lives behind a
// Loader where a missing module is just a warning and a null item.
//
// Unlike the shared pool, one player per visible tile: sources swap as
// the strip scrolls, and setting source to "" unloads the file, so
// players only ever exist for tiles on screen.
Item {
    id: root

    // absolute path of the clip, "" for none
    property string clip: ""
    // whether it runs; flipping to false keeps the last frame up
    property bool playing: false

    Loader {
        id: player
        anchors.fill: parent
        source: "WallpaperClipPlayer.qml"
    }

    // Pushed through Binding rather than declared on the player (see
    // WallpaperVideoSurface for why a Loader can't carry its item's
    // properties).
    Binding { target: player.item; property: "clip"; value: root.clip }
    Binding { target: player.item; property: "playing"; value: root.playing }
}

import QtQuick
import QtMultimedia

// The player behind WallpaperClip - never instantiated directly (see it
// for why the Loader matters). One MediaPlayer per visible tile, source
// bound to visibility: assigning "" unloads the file, so scrolling a
// tile off screen (or hiding the launcher) drops its decoder instead of
// accumulating players for the session. Clips are baked small (a few
// hundred KB), so opening one on scroll-into-view is tens of ms, and
// the still thumbnail underneath covers the gap - same handover the
// grid's shared video surface relies on.
Item {
    id: root

    property string clip: ""
    property bool playing: false

    VideoOutput {
        id: out
        anchors.fill: parent
        // transparent until frames arrive, so the still thumbnail
        // underneath shows through on load rather than flashing black
        fillMode: VideoOutput.PreserveAspectCrop
    }

    MediaPlayer {
        source: root.playing && root.clip !== "" ? "file://" + root.clip : ""
        autoPlay: true
        loops: MediaPlayer.Infinite
        videoOutput: out
        // deliberately silent: dozens of tiles share this, and one
        // unplayable clip must not raise a flyout per tile. The still
        // underneath is the fallback.
    }
}

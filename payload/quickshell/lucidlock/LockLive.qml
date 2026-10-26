import QtMultimedia
import QtQuick
import qs

// the live wallpaper behind the lock's blur: LiveWall's small, silent copy on a
// loop, fading in over the still, which is its first frame. a file of its own
// behind a Loader, so the shell loads Qt Multimedia only for a live lock
Item {
    id: live

    property url source
    readonly property bool showing: player.playbackState === MediaPlayer.PlayingState && (player.mediaStatus === MediaPlayer.BufferedMedia || player.mediaStatus === MediaPlayer.BufferingMedia)

    MediaPlayer {
        id: player

        source: live.source
        // play() from here would run before the player has the source
        autoPlay: true
        loops: MediaPlayer.Infinite
        videoOutput: out
        onErrorOccurred: (error, errorString) => {
            return console.warn("lucid lock:", errorString);
        }
    }

    VideoOutput {
        id: out

        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        opacity: live.showing ? 1 : 0

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.ms(300)
            }

        }

    }

}

import QtQuick
import QtMultimedia
import qs
import qs.lucidui

// a video or a song in quick look: it plays, a click pauses. its own file, so
// the multimedia stack only loads the first time something is played
Item {
    id: media

    property string source: ""
    property bool video: true
    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
    // a frame is up: the thumbnail behind can go
    readonly property bool ready: media.video && player.hasVideo && player.position > 0

    MediaPlayer {
        id: player

        source: media.source
        loops: MediaPlayer.Infinite
        videoOutput: out
        // the loader hands the file over once this is built
        onSourceChanged: {
            if (player.source.toString() !== "")
                player.play();

        }

        audioOutput: AudioOutput {
        }

    }

    VideoOutput {
        id: out

        anchors.fill: parent
        visible: media.video
        fillMode: VideoOutput.PreserveAspectFit
    }

    MouseArea {
        anchors.fill: parent
        onClicked: media.playing ? player.pause() : player.play()
    }

    // paused: the way back in
    Rectangle {
        anchors.centerIn: parent
        width: Theme.dp(64)
        height: width
        radius: width / 2
        color: Theme.alpha(Theme.cShadow, 0.55)
        opacity: media.playing ? 0 : 1
        visible: opacity > 0.01

        Icon {
            anchors.centerIn: parent
            size: Theme.dp(34)
            name: "play_arrow"
            color: "#ffffff"
            fill: 1
        }

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.durShort
            }

        }

    }

    // how far it has got
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Theme.dp(12)
        height: Theme.dp(4)
        radius: height / 2
        color: Theme.alpha("#ffffff", 0.25)
        visible: player.duration > 0

        Rectangle {
            width: parent.width * Math.min(1, player.position / Math.max(1, player.duration))
            height: parent.height
            radius: height / 2
            color: Theme.accent
        }

    }

}

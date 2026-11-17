import QtQuick
import QtMultimedia
import Quickshell

pragma Singleton

// One audio attachment plays at a time across the whole social widget. Keeping
// the player outside the cards means opening a post can hand playback to the
// copy of the same file in the detail view instead of leaving a hidden player
// running, and two copies of a recording cannot play over each other.
Singleton {
    id: root

    property string url: ""
    property string title: ""
    property bool started: false
    property bool failed: false

    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
    readonly property int duration: player.duration
    readonly property int position: player.position
    readonly property real progress: root.duration > 0
        ? Math.max(0, Math.min(1, root.position / root.duration))
        : 0

    // Discord signs attachment URLs with an expiry token, so the same file
    // can arrive with a different query after a refresh. Compare the CDN path
    // in that case, while keeping the originally loaded URL for playback.
    function sameMedia(source) {
        var value = String(source || "");
        if (root.url === "" || value === "")
            return false;
        if (root.url === value)
            return true;
        var signed = /^(https?:\/\/(?:cdn|media)\.discordapp\.(?:com|net)\/attachments\/[^?#]+)/i;
        var left = signed.exec(root.url);
        var right = signed.exec(value);
        return left !== null && right !== null && left[1] === right[1];
    }

    function isCurrent(source) {
        return root.url !== "" && root.sameMedia(source);
    }

    function toggle(source, name) {
        if (String(source || "") === "")
            return ;

        if (!root.isCurrent(source)) {
            root.begin(source, name);
            return ;
        }
        if (root.playing) {
            player.pause();
            return ;
        }
        if (root.duration > 0 && root.position >= root.duration)
            player.position = 0;
        root.started = true;
        player.play();
    }

    function begin(source, name) {
        if (String(source || "") === "")
            return ;

        if (!root.isCurrent(source)) {
            player.stop();
            root.url = String(source);
            root.title = String(name || "");
            root.started = false;
            root.failed = false;
        }
        root.started = true;
        player.play();
    }

    function pause() {
        if (root.playing)
            player.pause();
    }

    function stop() {
        player.stop();
        root.url = "";
        root.title = "";
        root.started = false;
        root.failed = false;
    }

    function stopIfCurrent(source) {
        if (root.isCurrent(source))
            root.stop();
    }

    function seek(fraction) {
        if (root.duration > 0)
            player.position = Math.round(root.duration * Math.max(0, Math.min(1, fraction)));
    }

    MediaPlayer {
        id: player

        source: root.url
        audioOutput: AudioOutput {
            muted: false
        }
        onErrorOccurred: (error, errorString) => {
            if (error !== MediaPlayer.NoError)
                root.failed = true;
        }
    }
}

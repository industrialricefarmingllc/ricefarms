import QtMultimedia
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// The live wallpaper, as a quickshell instance of its own: LiveWall.qml starts it
// with `quickshell -p` and the decoder it is to use in its environment, because
// Qt Multimedia reads QT_FFMPEG_DECODING_HW_DEVICE_TYPES once per process. It
// draws on the background layer of every screen and nothing else; what plays,
// and where it is paused, comes from the state file the shell writes.
//
// The first frame of the video sits under it on awww, so the change is the
// player's to make: from one video to the next it crossfades, from a video to a
// picture it fades into the picture, and from a picture it waits out the awww
// transition to the first frame before it shows, since that is where it starts.
ShellRoot {
    id: root

    property string video: ""
    // what awww shows: the video's first frame, or the picture
    property string picture: ""
    // output name -> false where the video holds still
    property var playing: ({})
    // the transition Settings -> Theme sets for wallpapers, in ms
    property int duration: 1000
    property var curve: [0.54, 0, 0.34, 0.99, 1, 1]
    // when the wallpaper last changed (ms since the epoch), so a player started
    // after it knows how much of the awww transition is left
    property real changed: 0

    function urlFor(path) {
        return path === "" ? "" : "file://" + path.split("/").map(encodeURIComponent).join("/");
    }

    FileView {
        path: Quickshell.env("LUCID_LIVE_STATE") || ""
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                const s = JSON.parse(text());
                root.duration = Math.max(0, Number(s.duration) || 0);
                if (Array.isArray(s.curve) && s.curve.length === 4)
                    root.curve = s.curve.concat([1, 1]);

                root.changed = Number(s.changed) || 0;
                root.playing = s.playing || {};
                root.picture = typeof s.picture === "string" ? s.picture : "";
                root.video = typeof s.video === "string" ? s.video : "";
            } catch (e) {
            }
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win

            required property var modelData
            readonly property bool play: root.playing[win.modelData.name] !== false
            readonly property var slots: [slotA, slotB]
            // the slot on screen, and the one fading in over it
            property int front: 0
            property bool waiting: false
            readonly property var frontSlot: win.slots[win.front]
            readonly property var backSlot: win.slots[1 - win.front]

            // a video, or the picture a video gives way to
            function show() {
                const video = root.video;
                const picture = video === "" ? root.picture : "";
                // a change in the middle of one lands the one under way first
                if (fade.running) {
                    fade.stop();
                    win.backSlot.opacity = 1;
                    win.swap();
                }

                if (win.frontSlot.video === video && win.frontSlot.picture === picture)
                    return;

                hold.stop();
                win.waiting = true;
                win.backSlot.opacity = 0;
                win.backSlot.load(video, picture);
                win.tryStart();
            }

            function swap() {
                const old = win.frontSlot;
                win.front = 1 - win.front;
                old.unload();
            }

            function tryStart() {
                if (!win.waiting || !win.backSlot.ready)
                    return;

                const fresh = !win.frontSlot.ready;
                // from a picture the frame is still arriving on awww: wait it out,
                // then the first frame of the video lands on that same frame
                const left = fresh ? root.duration - (Date.now() - root.changed) : 0;
                if (left > 30) {
                    hold.interval = left;
                    hold.restart();
                    return;
                }
                win.waiting = false;
                fade.duration = fresh ? 150 : Math.max(1, root.duration);
                fade.restart();
            }

            screen: win.modelData
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "lucid-live"
            WlrLayershell.exclusionMode: ExclusionMode.Ignore
            Component.onCompleted: win.show()

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            Connections {
                function onVideoChanged() {
                    win.show();
                }

                function onPictureChanged() {
                    if (root.video === "")
                        win.show();

                }

                target: root
            }

            Timer {
                id: hold

                onTriggered: {
                    if (!win.waiting || !win.backSlot.ready)
                        return;

                    win.waiting = false;
                    fade.duration = 150;
                    fade.restart();
                }
            }

            NumberAnimation {
                id: fade

                target: win.backSlot
                property: "opacity"
                from: 0
                to: 1
                easing.type: Easing.Bezier
                easing.bezierCurve: root.curve
                onFinished: win.swap()
            }

            // nothing here takes the pointer: the desktop above it does
            mask: Region {
            }

            component Slot: Item {
                id: slot

                property string video: ""
                property string picture: ""
                readonly property bool ready: slot.picture !== "" ? still.status === Image.Ready : (player.mediaStatus === MediaPlayer.BufferedMedia || player.mediaStatus === MediaPlayer.BufferingMedia)

                function load(video, picture) {
                    slot.video = video;
                    slot.picture = picture;
                    player.source = root.urlFor(video);
                    if (video !== "")
                        win.play ? player.play() : player.pause();

                }

                function unload() {
                    player.stop();
                    slot.video = "";
                    slot.picture = "";
                    player.source = "";
                    slot.opacity = 0;
                }

                anchors.fill: parent
                opacity: 0
                onReadyChanged: {
                    if (slot.ready && slot === win.backSlot)
                        win.tryStart();

                }

                Connections {
                    function onPlayChanged() {
                        if (slot.video !== "")
                            win.play ? player.play() : player.pause();

                    }

                    target: win
                }

                MediaPlayer {
                    id: player

                    loops: MediaPlayer.Infinite
                    videoOutput: out
                    onErrorOccurred: (error, errorString) => {
                        return console.warn("lucid-live:", errorString);
                    }
                }

                VideoOutput {
                    id: out

                    anchors.fill: parent
                    fillMode: VideoOutput.PreserveAspectCrop
                    visible: slot.video !== ""
                }

                Image {
                    id: still

                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    source: root.urlFor(slot.picture)
                    sourceSize.width: win.width
                    asynchronous: true
                    cache: false
                    visible: slot.picture !== ""
                }

            }

            // the one fading in is drawn over the one it replaces
            Slot {
                id: slotA

                z: win.front === 0 ? 0 : 1
            }

            Slot {
                id: slotB

                z: win.front === 1 ? 0 : 1
            }

        }

    }

}

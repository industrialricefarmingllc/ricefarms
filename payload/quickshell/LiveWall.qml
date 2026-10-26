import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
pragma Singleton

// Live wallpapers: a video from the wallpaper folder playing behind the desktop.
// set-wallpaper.sh puts the video's first frame on awww (the colours come from
// it too) and its path in ~/.cache/current_live_wallpaper; this starts
// lucidlive/LiveShell.qml, a quickshell of its own, to play the video over that
// frame, and tells it through a state file where to hold still: under windows,
// in game mode, behind the lock screen. Settings -> Theme -> Live wallpapers.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    // one per shell, so a second copy (a test one, say) never drives this player
    readonly property string stateFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/lucid-live-" + Qt.md5(Quickshell.shellDir).substring(0, 8) + ".json"
    readonly property string childConfig: Quickshell.shellDir + "/lucidlive/LiveShell.qml"
    readonly property var videoExts: ["mp4", "webm", "mkv", "mov", "m4v"]

    property string video: ""
    // what awww holds: the video's first frame, or the picture that replaced it
    property string picture: ""
    // when either last changed, for the player to time its fade against awww's
    property real changed: 0
    property bool loaded: false
    property bool gameMode: false
    // "still" in game mode leaves the first frame on awww and stops the player
    readonly property bool wanted: Prefs.liveWallpapers && root.video !== "" && !(root.gameMode && Prefs.liveGameMode === "still")
    // Qt's own order puts CUDA first, which wakes a hybrid laptop's dGPU for a
    // wallpaper: auto asks the integrated GPU first
    readonly property string decoders: ({
        "auto": "vaapi,cuda",
        "vaapi": "vaapi",
        "cuda": "cuda",
        "cpu": ""
    })[Prefs.liveDecoder] ?? "vaapi,cuda"
    // output name -> whether the video plays there
    readonly property var playing: {
        const out = {};
        const mons = Hyprland.monitors.values;
        for (let i = 0; i < mons.length; i++) {
            const ws = mons[i].activeWorkspace;
            const windows = ws ? ws.toplevels.values.length : 0;
            let still = Lockscreen.locked || (root.gameMode && Prefs.liveGameMode === "pause");
            if (Prefs.livePauseUnder === "any")
                still = still || windows > 0;
            else if (Prefs.livePauseUnder === "fullscreen")
                still = still || (ws !== null && ws.hasFullscreen);
            out[mons[i].name] = !still;
        }
        return out;
    }
    // the player changes with the transition set for pictures; none is a cut
    readonly property int duration: Prefs.wallTransType === "none" ? 0 : Math.round(Math.max(0, Number(Prefs.wallTransDuration) || 0) * 1000)
    readonly property var curve: {
        const c = String(Prefs.wallTransBezier).split(",").map(Number);
        return c.length === 4 && c.every((n) => {
            return isFinite(n);
        }) ? c : [0.54, 0, 0.34, 0.99];
    }
    readonly property string state: JSON.stringify({
        "video": root.video,
        "picture": root.picture,
        "playing": root.playing,
        "duration": root.duration,
        "curve": root.curve,
        "changed": root.changed
    })
    property int failures: 0
    // the lock screen plays a small, silent copy behind its blur rather than
    // decode the full video in the shell: made once per video, in the background
    readonly property string lockSource: Prefs.liveWallpapers ? root.video : ""
    property string lockVideo: ""
    property string lockMaking: ""

    function isVideo(path) {
        const dot = path.lastIndexOf(".");
        return dot > 0 && root.videoExts.indexOf(path.substring(dot + 1).toLowerCase()) !== -1;
    }

    function writeState() {
        stateView.setText(root.state);
    }

    function makeLockCopy() {
        root.lockVideo = "";
        lockCopy.running = false;
        if (root.lockSource === "")
            return ;

        root.lockMaking = root.lockSource;
        lockCopy.running = true;
    }

    function sync() {
        if (root.wanted) {
            linger.stop();
            if (!child.running && !sweep.running)
                sweep.running = true;

        } else if (child.running) {
            // back to a picture: the player fades the video out over the
            // transition awww is already running, then goes
            if (root.video === "")
                linger.restart();
            else
                child.running = false;
        }
    }

    onWantedChanged: root.sync()
    onLockSourceChanged: Qt.callLater(root.makeLockCopy)
    // the fields of one change land together, in one write
    onStateChanged: Qt.callLater(root.writeState)
    // a new decoder needs a new process
    onDecodersChanged: {
        if (child.running) {
            child.running = false;
            restart.restart();
        }
    }
    Component.onCompleted: stateView.setText(root.state)

    // two lines from set-wallpaper.sh: the video (empty for a picture), then what
    // awww was given
    FileView {
        path: root.home + "/.cache/current_live_wallpaper"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const lines = text().split("\n");
            const video = (lines[0] || "").trim();
            const picture = (lines[1] || "").trim();
            if (video === root.video && picture === root.picture)
                return;

            if (root.loaded)
                root.changed = Date.now();

            root.loaded = true;
            root.picture = picture;
            root.video = video;
        }
        onLoadFailed: {
            root.loaded = true;
            root.video = "";
        }
    }

    FileView {
        id: stateView

        path: root.stateFile
        atomicWrites: true
        printErrors: false
    }

    FileView {
        path: Prefs.gameModeStateFile
        watchChanges: Prefs.gameModeStateFile !== ""
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.gameMode = true
        onLoadFailed: root.gameMode = false
    }

    // a player left over from a shell that crashed would play under a new one
    Process {
        id: sweep

        command: ["quickshell", "kill", "-p", root.childConfig]
        onExited: layerOrder.running = true
    }

    // The player, awww and the desktop's icons and widgets all sit on the
    // background layer, stacked in the order they appeared, which would put the
    // video over the icons. A higher layer-rule order sits further back, so awww
    // goes to 2, the player to 1 and the rest stays at 0. Set here rather than in
    // modules/layerrules.lua, which an update does not rewrite; once per Lua
    // state, so again after Hyprland reloads its config
    Process {
        id: layerOrder

        command: ["hyprctl", "eval", "if not LucidLiveOrder then LucidLiveOrder = true " + "hl.layer_rule({ match = { namespace = \"awww-daemon\" }, order = 2 }) " + "hl.layer_rule({ match = { namespace = \"swww-daemon\" }, order = 2 }) " + "hl.layer_rule({ match = { namespace = \"lucid-live\" }, order = 1 }) end"]
        onExited: {
            if (root.wanted && !child.running)
                child.running = true;

        }
    }

    Connections {
        function onRawEvent(event) {
            if (event.name === "configreloaded" && child.running && !layerOrder.running)
                layerOrder.running = true;

        }

        target: Hyprland
    }

    Process {
        id: child

        command: ["quickshell", "-p", root.childConfig]
        environment: ({
            "QT_FFMPEG_DECODING_HW_DEVICE_TYPES": root.decoders,
            // a MediaPlayer also opens every encoding device up front, CUDA
            // and VDPAU included, which keeps a hybrid laptop's dGPU awake;
            // the player never encodes
            "QT_FFMPEG_ENCODING_HW_DEVICE_TYPES": "",
            "LUCID_LIVE_STATE": root.stateFile
        })
        onStarted: alive.restart()
        onExited: (code) => {
            alive.stop();
            if (!root.wanted)
                return;

            // a player that keeps dying leaves the frame on awww
            root.failures++;
            if (root.failures < 4)
                restart.restart();
            else
                console.warn("LiveWall: the player stopped", root.failures, "times; leaving the still frame");
        }
    }

    // keyed on the video's path and mtime like the login screen's copy; 640 wide
    // and 30 frames a second is plenty under a blur that heavy
    Process {
        id: lockCopy

        command: ["sh", "-c", "v=\"$1\"; d=\"$HOME/.cache/lucid/live-lock\"; mkdir -p \"$d\"; find \"$d\" -name '*.mp4' -mtime +14 -delete 2>/dev/null; find \"$d\" -name '.*.mp4' -mmin +10 -delete 2>/dev/null; k=$(printf '%s|%s' \"$v\" \"$(stat -c %Y \"$v\")\" | sha1sum | cut -c1-16); f=\"$d/$k.mp4\"; if [ ! -s \"$f\" ]; then command -v ffmpeg >/dev/null || exit 1; t=\"$d/.$k.$$.mp4\"; nice -n 19 ffmpeg -v error -y -threads 2 -i \"$v\" -an -sn -dn -filter_threads 1 -vf 'scale=640:-2,fps=30' -c:v libx264 -preset veryfast -crf 28 -pix_fmt yuv420p -movflags +faststart -threads 2 \"$t\" </dev/null && mv -f \"$t\" \"$f\" || { rm -f \"$t\"; exit 1; }; fi; printf '%s\\n' \"$f\"", "sh", root.lockMaking]

        stdout: StdioCollector {
            id: lockCopyOut

            onStreamFinished: {
                const f = lockCopyOut.text.trim();
                // a copy for a video that has since been replaced is not this one's
                if (f !== "" && root.lockMaking === root.lockSource)
                    root.lockVideo = "file://" + f.split("/").map(encodeURIComponent).join("/");

            }
        }

    }

    Timer {
        id: linger

        // the fade into the picture, and a little
        interval: root.duration + 400
        onTriggered: {
            if (!root.wanted)
                child.running = false;

        }
    }

    Timer {
        id: restart

        interval: 1000
        onTriggered: root.sync()
    }

    // a player that runs for a minute has settled
    Timer {
        id: alive

        interval: 60000
        onTriggered: root.failures = 0
    }

}

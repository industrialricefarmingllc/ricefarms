import QtQuick
import Quickshell
import Quickshell.Io
pragma Singleton

// screen recording through lucidcap: the whole workspace on the focused
// output, optionally with what the speakers are playing. lucidcap records
// the workspace (not the composited monitor), so layers flagged
// no_screen_share stay out of the video. stopping sends SIGINT so the file
// closes cleanly
Singleton {
    id: root

    property bool available: false
    property bool recording: false
    property real startedAt: 0
    property real now: Date.now()
    property string file: ""
    readonly property real elapsed: root.recording ? root.now - root.startedAt : 0
    readonly property string dir: Quickshell.env("HOME") + "/Videos/Recordings"
    // absolute: the user service PATH has no ~/.local/bin
    readonly property string capBin: Quickshell.env("HOME") + "/.local/bin/lucidcap"

    function clock(ms) {
        var s = Math.floor(ms / 1000);
        return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
    }

    function start() {
        if (root.recording || !root.available)
            return ;

        var scr = Monitors.focusedScreen || Monitors.mainScreen;
        var stamp = new Date().toLocaleString(Qt.locale("C"), "yyyy-MM-dd_HH-mm-ss");
        root.file = root.dir + "/lucid-" + stamp + ".mp4";

        var cmd = "mkdir -p '" + root.dir + "'; exec '" + root.capBin + "' --fps 30 --quiet --output '" + root.file + "'";
        if (scr && scr.name)
            cmd += " --monitor '" + scr.name + "'";
        if (Prefs.recordAudio)
            cmd += " --audio \"$(pactl get-default-sink).monitor\"";

        rec.command = ["sh", "-c", cmd];
        rec.running = true;
        root.startedAt = Date.now();
        root.now = root.startedAt;
        root.recording = true;
    }

    function stop() {
        if (!root.recording)
            return ;

        rec.signal(2);
    }

    function toggle() {
        if (root.recording)
            root.stop();
        else
            root.start();
    }

    Timer {
        interval: 500
        repeat: true
        running: root.recording
        onTriggered: root.now = Date.now()
    }

    Process {
        id: probe

        running: true
        command: ["sh", "-c", "test -x '" + root.capBin + "'"]
        onExited: (code) => {
            return root.available = code === 0;
        }
    }

    Process {
        id: rec

        onExited: (code) => {
            var took = Date.now() - root.startedAt;
            root.recording = false;
            // under a second means it never really started
            if (took < 1000) {
                Quickshell.execDetached(["notify-send", "-a", "Screen recorder", "-i", "media-record", "Recording failed", "lucidcap stopped straight away"]);
                return ;
            }
            // the same hand-off the overlay's recordings use: the shell copies
            // the finished file to the clipboard and shows it the way
            // Prefs.shotPreview asks, so a take from here lands there too
            Quickshell.execDetached(["sh", "-c", "printf '%s\\t%s\\n' \"$(date +%s%N)\" \"$1\" > \"$2\"", "sh", root.file, (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/lucid-recording-saved"]);
        }
    }

    IpcHandler {
        // qs ipc call recorder toggle
        function toggle(): void {
            root.toggle();
        }

        function start(): void {
            root.start();
        }

        function stop(): void {
            root.stop();
        }

        target: "recorder"
    }

}

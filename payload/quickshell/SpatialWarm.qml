import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs
pragma Singleton

// Warm the spatial cache in the background while the machine is on AC power.
//
// The depth map, the shared matte/background and the per-model influence map
// are generated here one wallpaper at a time at nice 19, so a picker pick or a
// wallpaper switch finds them ready. On battery it does nothing, and while a
// real wallpaper (or a picker prewarm) is generating it steps aside.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property string script: home + "/.config/quickshell/luciddocks/spatial-warm.py"
    // UPower.onBattery is false on machines without a battery.
    readonly property bool allowed: Prefs.spatialWallpapers && !UPower.onBattery
    readonly property string model: Prefs.spatialDepthModel
    readonly property string folder: Prefs.wallpaperDir
    // A real apply, or the picker's hover prewarm, owns the CPU.
    readonly property bool busy: SpatialWall.status !== "" || SpatialWall.prewarmBusy
        || Theme.revealActive
    readonly property bool running: warm.running
    // One mesh per distinct screen shape; the plugin builds background and
    // subject for each.
    readonly property var aspects: {
        const out = [];
        for (let i = 0; i < Quickshell.screens.length; i++) {
            const screen = Quickshell.screens[i];
            // The mesh key formats the aspect with six decimals; keep the same
            // precision here or the offline cache never matches.
            const aspect = (screen.width / Math.max(1, screen.height)).toFixed(6);
            if (out.indexOf(aspect) === -1)
                out.push(aspect);
        }
        return out.length > 0 ? out : [16 / 9];
    }
    property string lastLine: ""

    function restart() {
        warm.running = false;
        if (!root.allowed || root.folder === "")
            return ;
        if (root.busy) {
            hold.restart();
            return ;
        }
        var command = ["/usr/bin/nice", "-n", "19", "/usr/bin/python3", root.script,
            "--model", root.model, "--dir", root.folder];
        for (let i = 0; i < root.aspects.length; i++)
            command.push("--aspect", String(root.aspects[i]));
        warm.command = command;
        // Low-power devices: two threads, and one wallpaper at a time.
        warm.environment = ({
            "OMP_NUM_THREADS": "2",
            "LUCID_DEPTH_THREADS": "2"
        });
        warm.running = true;
    }

    onAllowedChanged: root.restart()
    onModelChanged: root.restart()
    onFolderChanged: root.restart()
    onBusyChanged: root.restart()
    Component.onCompleted: root.restart()

    // A real generation was running; look again shortly after it ends.
    Timer {
        id: hold

        interval: 4000
        repeat: false
        onTriggered: root.restart()
    }

    // Pick up wallpapers added after the last sweep without re-running often.
    Timer {
        interval: 30 * 60 * 1000
        repeat: true
        running: root.allowed && !root.running && !root.busy
        onTriggered: root.restart()
    }

    Process {
        id: warm

        running: false

        stdout: SplitParser {
            onRead: (line) => {
                root.lastLine = line;
            }
        }
    }
}

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.UPower
import Quickshell.Wayland
import qs
pragma Singleton

// Warm the spatial cache in the background while the machine is on AC power.
//
// The depth map, the shared matte/background and the per-model influence map
// are generated here one wallpaper at a time at nice 19, so a picker pick or a
// wallpaper switch finds them ready. On battery it does nothing, and while a
// real wallpaper is generating it steps aside.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property string script: home + "/.config/quickshell/luciddocks/spatial-warm.py"
    // UPower.onBattery is false on machines without a battery.
    // Warming is optional work. Only start it after the session has been
    // idle for two minutes, and stop the whole sweep the moment input
    // returns; the renderer builds a missing mesh on demand anyway.
    readonly property bool idle: idleMonitor.isIdle
    // Do not start a multi-minute CPU sweep under a film or a fullscreen game.
    readonly property bool mediaPlaying: {
        const players = Mpris.players ? Mpris.players.values : [];
        for (let i = 0; i < players.length; i++) {
            if (players[i].isPlaying)
                return true;
        }
        return false;
    }
    readonly property bool fullscreen: {
        const info = Hyprland.activeToplevel ? Hyprland.activeToplevel.lastIpcObject : null;
        return !!(info && info.fullscreen);
    }
    readonly property bool allowed: Prefs.spatialWallpapers && !UPower.onBattery
        && root.idle && !root.mediaPlaying && !root.fullscreen
    readonly property string model: Prefs.spatialDepthModel
    readonly property string folder: Prefs.wallpaperDir
    // A real apply owns the CPU.
    readonly property bool busy: SpatialWall.status !== "" || Theme.revealActive
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
        // The whole sweep, not only the mesh child, runs in the idle I/O class.
        var command = ["/usr/bin/ionice", "-c", "3", "/usr/bin/nice", "-n", "19",
            "/usr/bin/python3", root.script,
            "--model", root.model, "--dir", root.folder];
        for (let i = 0; i < root.aspects.length; i++)
            command.push("--aspect", String(root.aspects[i]));
        warm.command = command;
        // Low-power devices: two threads, and one wallpaper at a time.
        warm.environment = ({
            "OMP_NUM_THREADS": "2",
            "LUCID_DEPTH_THREADS": "2",
            "LUCID_PREP_THREADS": "2"
        });
        warm.running = true;
    }

    onAllowedChanged: root.restart()
    onModelChanged: root.restart()
    onFolderChanged: root.restart()
    onBusyChanged: root.restart()
    Component.onCompleted: root.restart()

    IdleMonitor {
        id: idleMonitor

        enabled: true
        timeout: 120
        respectInhibitors: true
    }

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

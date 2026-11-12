import QtQuick
import Quickshell
import Quickshell.Io
pragma Singleton

// Global cursor position for the spatial wallpaper. A background layer surface
// with an empty input region never receives pointer motion, and giving it a
// real input region would steal clicks from widgets and desktop icons.
// Hyprland's own IPC gives us the compositor position without any input grab.
Singleton {
    id: root

    readonly property string script: Quickshell.env("HOME") + "/.config/quickshell/luciddocks/spatial-pointer.py"
    readonly property string pointerFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/lucid-scene-pointer"
    property real x: 0
    property real y: 0
    property bool valid: false
    // While every output has a focused client window the wallpaper is frozen,
    // so polling Hyprland's cursor IPC would only burn CPU for coordinates no
    // shader or camera reads. Start again as soon as a surface can move.
    readonly property bool wanted: Prefs.spatialWallpapers
        && (SpatialWall.hasVisual || SpatialWall.isScene)
        && SpatialWall.displaysAwake
        && !SpatialWall.allScreensFocused

    onWantedChanged: {
        if (!root.wanted) {
            tracker.running = false;
            root.valid = false;
        } else
            retry.restart();
    }

    Process {
        id: tracker

        command: ["/usr/bin/python3", root.script, "--write", root.pointerFile]
        running: false
        stdout: SplitParser {
            onRead: (line) => {
                const parts = String(line).trim().split(/\s+/);
                if (parts.length < 2)
                    return ;
                const nx = Number(parts[0]);
                const ny = Number(parts[1]);
                if (!isFinite(nx) || !isFinite(ny))
                    return ;
                root.x = nx;
                root.y = ny;
                root.valid = true;
            }
        }
        onExited: retry.restart()
    }

    Timer {
        id: retry

        // Short because this also restarts the tracker when a window stops
        // covering the wallpaper; a long delay would look like a frozen
        // parallax for the first gesture after focus returns to the desktop.
        interval: 180
        repeat: false
        onTriggered: {
            if (root.wanted && !tracker.running)
                tracker.running = true;
        }
    }

    Component.onCompleted: if (root.wanted)
        retry.restart()
}

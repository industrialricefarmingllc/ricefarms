import QtQuick
import Quickshell
import Quickshell.Io

// TEST FIXTURE COPY of ../../qml/GlassLayout.qml (kept in sync by hand).
// Quickshell forbids imports outside the config folder, so the rig vendors
// its own copy instead of importing the real one.

// Publishes pill geometry for the liquid-glass-hypr compositor plugin.
//
// The plugin draws glass where the pixels already are (in the render pass),
// so it needs to know WHERE the pills are — but nothing else. This component
// mirrors its rect list to
// ~/.cache/liquid-glass-hypr/liquidglass-<name>-<MON>.json on every change
// (persistent cache dir, tiny, exact — deliberately not /tmp, which wipes
// on reboot). One file per publisher surface (dock, bar, ...); the
// plugin routes files to surfaces by surface size, so publishers stay fully
// independent — no registry, no lifecycle tracking.
//
//   GlassLayout {
//       name: "dock"
//       targetScreen: dockWindow.screen
//       surfaceW: dockWindow.width
//       surfaceH: dockWindow.height
//       pills: [{
//           x: shell.x, y: shell.y, w: shell.width, h: shell.height,
//           r: [r, r, bottomLeft, bottomRight]
//       }]
//   }
//
// Coordinates are surface-relative logical px; radii are [tl, tr, br, bl] in
// the same units. Bindings re-evaluate per frame during animations, so the
// glass tracks morphs exactly — no debounce here by design. NOTE: no dpr
// anywhere on purpose. Qt's devicePixelRatio can disagree with fractional
// compositor scale (here: 2 vs 1.6); the plugin converts with the monitor
// scale it already knows.

Item {
    id: root

    property string name: "unnamed"
    property var targetScreen: null
    property real surfaceW: 0
    property real surfaceH: 0
    // [{x, y, w, h, r: [tl, tr, br, bl]}]
    property var pills: []

    readonly property string monitorName: root.targetScreen && root.targetScreen.name ? root.targetScreen.name : "DP-1"

    // NOTE: Quickshell.env() yields null (not "") for unset vars, so test
    // truthiness — a `!== ""` check resolves to a bogus "null/..." path.
    readonly property string cacheDir: {
        var xdg = Quickshell.env("XDG_CACHE_HOME");
        var base = xdg ? xdg : Quickshell.env("HOME") + "/.cache";
        return base + "/liquid-glass-hypr";
    }

    FileView {
        id: file

        path: root.cacheDir + "/liquidglass-" + root.name + "-" + root.monitorName + ".json"
        blockLoading: true

        adapter: JsonAdapter {
            id: json

            property string monitor: ""
            property var surface: ({})
            property var pills: []
        }
    }

    function sync() {
        json.monitor = root.monitorName;
        json.surface = {
            "w": root.surfaceW,
            "h": root.surfaceH
        };
        json.pills = root.pills;
        file.writeAdapter();
    }

    onPillsChanged: root.sync()
    onMonitorNameChanged: root.sync()
    onSurfaceWChanged: root.sync()
    onSurfaceHChanged: root.sync()
    Component.onCompleted: {
        Quickshell.execDetached(["mkdir", "-p", root.cacheDir]);
        root.sync();
    }
    Timer {
        interval: 2000
        running: true
        repeat: false
        onTriggered: root.sync()
    }
}

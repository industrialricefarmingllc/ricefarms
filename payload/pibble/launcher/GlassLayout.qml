import QtQuick
import Quickshell
import Quickshell.Io

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
//       surfaceNamespace: "quickshell"   // layer ns; disambiguates same-size surfaces
//       targetScreen: dockWindow.screen
//       surfaceW: dockWindow.width
//       surfaceH: dockWindow.height
//       pills: [{
//           x: shell.x, y: shell.y, w: shell.width, h: shell.height,
//           r: [r, r, bottomLeft, bottomRight],
//           fl: [flareLeft, flareRight]  // optional notch shoulders, default 0
//           sq: 0.5  // optional per-pill squircle 0..1, default: global
//                    // squircle_f (animation geometry like the launch
//                    // reveal's circle sends 0 to stay a true circle)
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
    // WlrLayershell.namespace of the window publishing this geometry. The
    // plugin matches it exactly (when the file carries it) *in addition* to
    // the surface size, so a near-identical surface (bar 896 vs this
    // always-mapped 900px launcher, 0.4% apart) can't receive these pills,
    // or vice versa. Empty keeps the legacy size-only routing.
    property string surfaceNamespace: ""
    property var targetScreen: null
    property real surfaceW: 0
    property real surfaceH: 0
    // [{x, y, w, h, r: [tl, tr, br, bl]}]
    property var pills: []

    readonly property string monitorName: root.targetScreen && root.targetScreen.name ? root.targetScreen.name : "DP-1"

    // XDG-aware persistent dir (mirrors the plugin's geoDir()). mkdir'd on
    // completion; the plugin also creates it, so boot races resolve both ways.
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
            property string ns: ""
            property var surface: ({})
            property var pills: []
        }
    }

    // Last published signature: identical re-evaluations skip the write.
    // (The pills array is rebuilt inline at the call site, so without this
    // every dependency evaluation writes an identical file.) Morph frames
    // publish at most every 16ms: the reveal edge moves ~14px/ms, so a
    // longer window would visibly detach the glass from the content; 16ms
    // merges only same-frame duplicate publishes at native frame lag.
    property string _lastSig: ""
    property double _lastWriteMs: 0

    Timer {
        id: coalesceTimer

        interval: 16
        repeat: false
        onTriggered: root.flushPending()
    }

    function sigOf() {
        return root.monitorName + "|" + root.surfaceNamespace + "|" + root.surfaceW + "x" + root.surfaceH + "|" + JSON.stringify(root.pills);
    }

    function doWrite(sig) {
        root._lastSig = sig;
        root._lastWriteMs = Date.now();
        json.monitor = root.monitorName;
        json.ns = root.surfaceNamespace;
        json.surface = {
            "w": root.surfaceW,
            "h": root.surfaceH
        };
        json.pills = root.pills;
        file.writeAdapter();
    }

    function flushPending() {
        if (root.name === "" || file.path === "")
            return;
        var sig = root.sigOf();
        if (sig === root._lastSig)
            return;
        root.doWrite(sig);
    }

    function sync(force) {
        if (root.name === "" || file.path === "")
            return; // init ordering: bindings settle a frame later
        if (force === true) {
            coalesceTimer.stop();
            root.flushPending();
            return;
        }
        var sig = root.sigOf();
        if (sig === root._lastSig)
            return; // idle: nothing transformed, skip the write
        if (Date.now() - root._lastWriteMs < 16) {
            coalesceTimer.restart();
            return;
        }
        root.doWrite(sig);
    }

    onPillsChanged: root.sync(false)
    onMonitorNameChanged: root.sync(false)
    onSurfaceNamespaceChanged: root.sync(false)
    onSurfaceWChanged: root.sync(false)
    onSurfaceHChanged: root.sync(false)
    Component.onCompleted: {
        Quickshell.execDetached(["mkdir", "-p", root.cacheDir]);
        root.sync(true);
    }
    // Boot-race insurance: if the first write landed before the dir
    // existed, this rewrite lands after both mkdir and plugin init.
    Timer {
        interval: 2000
        running: true
        repeat: false
        onTriggered: root.sync(true)
    }
}

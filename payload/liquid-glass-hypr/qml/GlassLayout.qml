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
//                    // squircle_f (animation geometry that must stay
//                    // circular sends 0)
//       }]
//   }
//
// Coordinates are surface-relative logical px; radii are [tl, tr, br, bl] in
// the same units. Bindings re-evaluate per frame during animations, so the
// glass tracks morphs exactly — no debounce here by design. A trailing
// debounce starves mid-morph (every frame restarts the timer, nothing
// publishes until settle+interval, glass freezes then jumps ~400ms late),
// which is why widget opens lost their animation. Idle write churn is
// instead gated inside sync() by geometry signature: no transformation =>
// no file write. NOTE: no dpr anywhere on purpose. Qt's devicePixelRatio can disagree with fractional
// compositor scale (here: 2 vs 1.6); the plugin converts with the monitor
// scale it already knows.

Item {
    id: root

    property string name: "unnamed"
    // Bridge filename prefix. The wash-only publisher uses "liquidwash-" so
    // the glass plugin (which scans "liquidglass-") ignores its pills.
    property string filePrefix: "liquidglass-"
    // WlrLayershell.namespace of the window publishing this geometry. The
    // plugin matches it exactly (when the file carries it) *in addition* to
    // the surface size, so a near-identical surface (bar 896 vs an
    // always-mapped 900px launcher, 0.4% apart) can't receive these pills.
    // Empty keeps the legacy size-only routing.
    property string surfaceNamespace: ""
    property var targetScreen: null
    property real surfaceW: 0
    property real surfaceH: 0
    // [{x, y, w, h, r: [tl, tr, br, bl]}]
    property var pills: []
    // Minimum time between geometry publishes. 4 ms for direct manipulation,
    // 8 ms for transitions (see the note above _lastPills).
    property int coalesceMs: 4
    // Optional circular clip for this surface's glass body, surface-local
    // logical px: {x, y, r}. The plugin feathers the glass edge to the circle
    // (used by the launcher iris reveal, whose QML mask clips content the same
    // way). Empty object/absent = no mask.
    property var mask: null
    // Shape is the live committed layer-surface box; only radius/squircle
    // come from the pills. Removes size/position from the bridge entirely.
    property bool full: false

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

        path: root.cacheDir + "/" + root.filePrefix + root.name + "-" + root.monitorName + ".json"
        blockLoading: true

        adapter: JsonAdapter {
            id: json

            property string monitor: ""
            property string ns: ""
            property var surface: ({})
            property var pills: []
            property var mask: ({})
            property bool full: false
        }
    }

    // Last published geometry, kept as values rather than a serialised
    // signature. The bridge publishes at most once per coalesceMs. The bar
    // uses 8 ms (120 Hz) for panel transitions: one frame of lag at 165 Hz,
    // still smooth, and ~27 % fewer filesystem writes + plugin parses + glass
    // passes. Surfaces that are directly dragged or resized keep 4 ms so the
    // glass stays on the pointer. Do not use a trailing debounce: it starves
    // mid-morph and freezes the glass until the animation settles.
    //
    // The equality check is a field-by-field walk (~0.2 us for six pills), not
    // a JSON string: stringifying the same list costs ~25 us on V4, and doing
    // it twice per coalesced frame was the largest fixed cost in the bridge.
    // The JSON itself is only assembled by the adapter on an actual write.
    property var _lastPills: []
    property var _lastMask: ({})
    property real _lastSurfaceW: -1
    property real _lastSurfaceH: -1
    property string _lastNs: ""
    property string _lastMon: ""
    property bool _lastFull: false
    property double _lastWriteMs: 0

    Timer {
        id: coalesceTimer

        interval: root.coalesceMs
        repeat: false
        onTriggered: root.flushPending()
    }

    function copyPills(src) {
        var out = [];
        if (!Array.isArray(src))
            return out;
        for (var i = 0; i < src.length; i++) {
            var p = src[i];
            if (!p)
                continue;
            out.push({
                "x": p.x,
                "y": p.y,
                "w": p.w,
                "h": p.h,
                "r": p.r ? p.r.slice(0) : [],
                "sq": p.sq,
                "fl": p.fl
            });
        }
        return out;
    }

    function samePills(a, b) {
        if (!Array.isArray(a) || !Array.isArray(b))
            return !Array.isArray(a) && !Array.isArray(b);
        if (a === b)
            return true;
        if (!a || !b || a.length !== b.length)
            return false;
        for (var i = 0; i < a.length; i++) {
            var p = a[i], q = b[i];
            if (!p || !q) {
                if (p !== q)
                    return false;
                continue;
            }
            if (p.x !== q.x || p.y !== q.y || p.w !== q.w || p.h !== q.h || p.sq !== q.sq)
                return false;
            var pr = p.r || [], qr = q.r || [];
            if (pr.length !== qr.length)
                return false;
            for (var j = 0; j < pr.length; j++) {
                if (pr[j] !== qr[j])
                    return false;
            }
            var pf = p.fl || [], qf = q.fl || [];
            if (pf.length !== qf.length)
                return false;
            for (j = 0; j < pf.length; j++) {
                if (pf[j] !== qf[j])
                    return false;
            }
        }
        return true;
    }

    function sameMask(a, b) {
        var am = a || ({}), bm = b || ({});
        return (am.x || 0) === (bm.x || 0) && (am.y || 0) === (bm.y || 0) && (am.r || 0) === (bm.r || 0);
    }

    function geometrySame() {
        return root.monitorName === root._lastMon
            && root.surfaceNamespace === root._lastNs
            && root.full === root._lastFull
            && root.surfaceW === root._lastSurfaceW
            && root.surfaceH === root._lastSurfaceH
            && root.sameMask(root.mask, root._lastMask)
            && root.samePills(root.pills, root._lastPills);
    }

    function remember() {
        root._lastMon = root.monitorName;
        root._lastNs = root.surfaceNamespace;
        root._lastFull = root.full;
        root._lastSurfaceW = root.surfaceW;
        root._lastSurfaceH = root.surfaceH;
        root._lastMask = root.mask ? { "x": root.mask.x, "y": root.mask.y, "r": root.mask.r } : ({});
        root._lastPills = root.copyPills(root.pills);
    }

    function doWrite() {
        if (root._writing) {
            root._pending = true;
            return;
        }
        root.remember();
        root._lastWriteMs = Date.now();
        root._writeStart = root._lastWriteMs;
        json.monitor = root.monitorName;
        json.ns = root.surfaceNamespace;
        json.surface = {
            "w": root.surfaceW,
            "h": root.surfaceH
        };
        json.pills = Array.isArray(root.pills) ? root.pills.filter((p) => p) : [];
        json.mask = root.mask || ({});
        json.full = root.full;
        if (root._writes === 0)
            root._tFirst = root._lastWriteMs;
        root._writes++;
        if (root._writes % 300 === 0)
            console.log("GLASS " + root.name + " writes=" + root._writes + " elapsedMs=" + Math.round(root._lastWriteMs - root._tFirst) + " lastPills=" + root._lastPills.length);
        root._writing = true;
        file.writeAdapter();
    }

    function flushPending() {
        if (root.name === "" || file.path === "")
            return;
        if (root.geometrySame())
            return;
        root.doWrite();
    }

    property int _writes: 0
    property double _tFirst: 0
    // A FileView write can block the caller ("Blocking on write" in the log)
    // when another write is still in flight. The launcher used to publish
    // every frame, so a slow disk turned into a frozen launcher while the rest
    // of the shell looked idle. Never issue a second write while one is in
    // flight; keep only the latest geometry and flush it when the write ends.
    property bool _writing: false
    property bool _pending: false
    property double _writeStart: 0
    // Bumped only on a successful write; the launcher uses this to start its
    // fill/rim crossfade after the plugin actually has the settled shape.
    property int saveGeneration: 0

    Connections {
        target: file

        function onSaved() {
            root.saveGeneration++;
            root.finishWrite();
        }

        function onSaveFailed() {
            root.finishWrite();
        }
    }

    Timer {
        id: flushTimer

        interval: 4
        repeat: false
        onTriggered: root.flushPending()
    }

    Timer {
        id: writeWatchdog

        interval: 2000
        repeat: true
        running: root._writing
        onTriggered: {
            // A canceled write may never emit saved/saveFailed. Drop the
            // guard once it is clearly stale, then publish the latest state.
            if (Date.now() - root._writeStart < 1500)
                return;
            root._writing = false;
            if (root._pending)
                root.flushPending();
        }
    }

    function finishWrite() {
        root._writing = false;
        if (root._pending) {
            root._pending = false;
            flushTimer.restart();
        }
    }

    function sync(force) {
        if (root.name === "" || file.path === "")
            return; // init ordering: bindings settle a frame later
        if (force === true) {
            coalesceTimer.stop();
            root.doWrite();
            return;
        }
        if (root.geometrySame())
            return; // idle: nothing transformed
        if (Date.now() - root._lastWriteMs < root.coalesceMs) {
            coalesceTimer.restart();
            return;
        }
        root.doWrite();
    }

    onPillsChanged: root.sync()
    onMaskChanged: root.sync()
    onFullChanged: root.sync()
    onMonitorNameChanged: root.sync()
    onSurfaceNamespaceChanged: root.sync()
    onSurfaceWChanged: root.sync()
    onSurfaceHChanged: root.sync()
    Component.onCompleted: {
        Quickshell.execDetached(["mkdir", "-p", root.cacheDir]);
        root.sync(true);
    }
    // Boot-race insurance: if the first write landed before the dir
    // existed, this rewrite lands after both mkdir and plugin init.
    // Forced: it must land even when the signature is unchanged.
    Timer {
        interval: 2000
        running: true
        repeat: false
        onTriggered: root.sync(true)
    }
}

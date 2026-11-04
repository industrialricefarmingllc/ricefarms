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
    // signature. Morph frames publish at most every 4ms: below one frame on a
    // 165 Hz output, so it only merges duplicate publishes inside the same
    // frame. At 16ms the glass advanced in ~3-frame steps while the content
    // (and its mask) moved every frame, which read as a flickering edge once
    // the rim hairline made it visible.
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

        interval: 4
        repeat: false
        onTriggered: root.flushPending()
    }

    function copyPills(src) {
        var out = [];
        if (!Array.isArray(src))
            return out;
        for (var i = 0; i < src.length; i++) {
            var p = src[i];
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
        root.remember();
        root._lastWriteMs = Date.now();
        json.monitor = root.monitorName;
        json.ns = root.surfaceNamespace;
        json.surface = {
            "w": root.surfaceW,
            "h": root.surfaceH
        };
        json.pills = Array.isArray(root.pills) ? root.pills : [];
        json.mask = root.mask || ({});
        json.full = root.full;
        if (root._writes === 0)
            root._tFirst = root._lastWriteMs;
        root._writes++;
        if (root._writes % 300 === 0)
            console.log("GLASS " + root.name + " writes=" + root._writes + " elapsedMs=" + Math.round(root._lastWriteMs - root._tFirst) + " lastPills=" + root._lastPills.length);
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
        if (Date.now() - root._lastWriteMs < 4) {
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

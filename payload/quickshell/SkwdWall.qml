import QtQuick
import Quickshell
import Quickshell.Io
import qs
pragma Singleton

// skwd-wall integration. When the suite is installed and Settings -> Theme ->
// skwd-wall is on, its daemon (skwd-walld) owns the desktop wallpaper and this
// singleton reads that library for lucid's picker: images, videos and Wallpaper
// Engine scenes, with the animated previews skwd cuts for the moving ones.
//
// Lucid still does the picking and the colour work. An item is addressed as a
// normal file path, or as "skwd:we:<workshop id>" for a scene that has no file;
// set-wallpaper.sh turns either into `skwd-helm apply`.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property string script: home + "/.config/quickshell/luciddocks/skwd-previews.sh"
    // available means the pieces the shell needs are on PATH. enabled also asks
    // the preference, so a machine without skwd keeps the awww/LiveWall path.
    property bool available: false
    property bool probed: false
    property bool enabled: Prefs.skwdWall && root.available
    property bool loaded: false
    property string error: ""
    // one entry per wallpaper, in the shape the picker's ListModels use.
    // path is a file path, or skwd:<key> for a Wallpaper Engine scene.
    property var items: []
    property string currentPath: ""
    property string currentKind: ""
    property string currentKey: ""
    property bool previewsRunning: false
    property bool previewsWarmed: false
    property bool listing: false
    property bool listAgain: false
    // skwd only notices a file that appeared after startup on a scan; keep
    // the scan serialised so opening the picker twice does not race itself
    property bool scanning: false
    // key -> {jpg,gif,mp4} written by live-capture.sh; these override the
    // author/library preview once a live recording exists
    property var livePreviews: ({})

    signal listingFailed()

    function isVirtual(path) {
        return String(path).indexOf("skwd:") === 0;
    }

    function keyFor(path) {
        return root.isVirtual(path) ? String(path).substring(5) : "";
    }

    // A Wallpaper Engine scene is stored as skwd:we:<id>; its video variant is
    // a real file inside Steam's workshop folder. Both mean the same item.
    function workshopIdFor(path) {
        const p = String(path);
        if (p.indexOf("skwd:we:") === 0)
            return p.substring(8);
        if (/^we:\d+$/.test(p))
            return p.substring(3);
        const m = p.match(/\/steamapps\/workshop\/content\/431960\/(\d+)(?:\/|$)/);
        return m ? m[1] : "";
    }

    function entryForPath(path) {
        for (let i = 0; i < root.items.length; i++) {
            if (root.items[i].path === path)
                return root.items[i];
        }
        return null;
    }

    function refresh(scanFirst) {
        if (!root.enabled) {
            root.items = [];
            root.loaded = false;
            root.currentPath = "";
            return ;
        }
        // A download happened after skwd's last scan. Make the scan discovery
        // step part of the refresh, otherwise the new file stays invisible
        // until something else happens to rescan the library.
        if (scanFirst === true) {
            if (root.scanning)
                return ;
            root.scanning = true;
            scan.running = true;
            return ;
        }
        if (root.listing) {
            root.listAgain = true;
            return ;
        }
        root.listing = true;
        list.running = true;
    }

    function parseList(text) {
        let rows = [];
        try {
            const data = JSON.parse(text);
            rows = Array.isArray(data.wallpapers) ? data.wallpapers : [];
        } catch (e) {
            root.error = "skwd-helm list: " + e;
            rows = [];
        }

        const next = [];
        for (let i = 0; i < rows.length; i++) {
            const item = rows[i];
            const key = String(item.key || "");
            if (key === "")
                continue;

            const kind = String(item.type || "static");
            const nativePath = String(item.video_file || item.path || "");
            next.push({
                "path": kind === "we" ? "skwd:" + key : (nativePath !== "" ? nativePath : "skwd:" + key),
                "name": String(item.name || key),
                "thumb": String(item.thumb_sm || item.thumb || ""),
                "preview": String(item.preview || ""),
                "key": key,
                "kind": kind
            });
        }
        root.items = root.applyLivePreviews(next);
        root.loaded = true;
        root.error = "";
        root.warmPreviews();
        if (!wePreviews.running)
            wePreviews.running = true;
    }

    // the live recording is newer than both skwd's WebP thumb and the author's
    // preview; apply it on top of whatever the item currently has
    function applyLivePreviews(list) {
        const map = root.livePreviews || {};
        var out = [];
        for (var i = 0; i < list.length; i++) {
            var e = list[i];
            var p = map[e.key];
            if (p && (p.jpg || p.gif)) {
                var copy = {};
                for (var k in e) copy[k] = e[k];
                if (p.jpg)
                    copy.thumb = p.jpg;
                if (p.gif)
                    copy.preview = p.gif;
                out.push(copy);
            } else {
                out.push(e);
            }
        }
        return out;
    }

    function mergeLivePreviews(text) {
        var map = null;
        try {
            map = JSON.parse(text);
        } catch (e) {
            return ;
        }
        if (!map || typeof map !== "object")
            return ;

        root.livePreviews = map;
        root.items = root.applyLivePreviews(root.items);
    }

    // skwd's WebP scene thumbs do not always decode in Qt. The workshop folder
    // carries the author's own preview.gif/jpg; use it for the still and, when
    // it is a GIF, play it on hover.
    function mergeWePreviews(text) {
        var map = null;
        try {
            map = JSON.parse(text);
        } catch (e) {
            return ;
        }
        if (!map)
            return ;

        var changed = false;
        var next = [];
        for (var i = 0; i < root.items.length; i++) {
            var e = root.items[i];
            var p = map[e.key];
            if (p && (p.thumb || p.preview)) {
                var copy = {};
                for (var k in e) copy[k] = e[k];
                if (p.thumb)
                    copy.thumb = p.thumb;
                if (p.preview)
                    copy.preview = p.preview;
                next.push(copy);
                changed = true;
            } else {
                next.push(e);
            }
        }
        if (changed)
            root.items = root.applyLivePreviews(next);
    }

    // Ask skwd to cut the short animated WebP previews its picker uses. The
    // helper is a no-op when they all exist, and only ever runs one at a time.
    function warmPreviews() {
        if (root.previewsWarmed || root.previewsRunning || !root.enabled)
            return ;

        for (let i = 0; i < root.items.length; i++) {
            const item = root.items[i];
            if (item.kind === "video" && item.preview !== "") {
                root.previewsRunning = true;
                root.previewsWarmed = true;
                previews.running = true;
                return ;
            }
        }
    }

    function parseOutputs(text) {
        try {
            const data = JSON.parse(text);
            const names = Object.keys(data || {});
            if (names.length === 0)
                return ;

            let output = null;
            for (let i = 0; i < names.length; i++) {
                const candidate = data[names[i]];
                if (candidate && candidate.connected !== false) {
                    output = candidate;
                    break;
                }
            }
            output = output || data[names[0]];
            const kind = String(output.type || "");
            const we = String(output.we_id || "");
            if (kind === "we" && we !== "") {
                root.currentKind = "we";
                root.currentKey = "we:" + we;
                root.currentPath = "skwd:we:" + we;
            } else {
                const path = String(output.path || output.current || "");
                root.currentKind = kind;
                root.currentKey = "";
                root.currentPath = path;
            }
        } catch (e) {
        }
    }

    function openPicker() {
        Quickshell.execDetached(["skwd-wall-v2"]);
    }

    onEnabledChanged: {
        if (root.enabled)
            root.refresh();
        else {
            root.items = [];
            root.loaded = false;
            root.previewsWarmed = false;
        }
    }

    Component.onCompleted: detect.running = true

    Process {
        id: detect

        command: ["sh", "-c", "command -v skwd-helm >/dev/null 2>&1 && command -v skwd-walld >/dev/null 2>&1 && command -v skwd-wall-v2 >/dev/null 2>&1"]
        onExited: (code) => {
            root.available = code === 0;
            root.probed = true;
            if (root.enabled)
                root.refresh();

        }
    }

    Process {
        id: scan

        command: ["sh", "-c", "command -v skwd-wall-scan >/dev/null 2>&1 && skwd-wall-scan >/dev/null 2>&1"]
        onExited: (code) => {
            root.scanning = false;
            root.refresh();
        }
    }

    Process {
        id: list

        command: ["skwd-helm", "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: root.parseList(text)
        }
        onExited: (code) => {
            root.listing = false;
            if (code !== 0) {
                root.loaded = true;
                root.error = "skwd-helm list exited " + code;
                root.listingFailed();
            }
            if (root.listAgain) {
                root.listAgain = false;
                Qt.callLater(root.refresh);
            }
        }
    }

    Process {
        id: wePreviews

        command: ["python3", root.home + "/.config/quickshell/luciddocks/skwd-we-previews.py"]
        stdout: StdioCollector {
            onStreamFinished: root.mergeWePreviews(text)
        }
    }

    Process {
        id: previews

        command: ["bash", root.script]
        onExited: (code) => {
            root.previewsRunning = false;
        }
    }

    FileView {
        id: livePreviewsFile

        path: root.home + "/.cache/lucid/live-previews/index.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.mergeLivePreviews(text())
    }

    FileView {
        id: outputs

        path: root.home + "/.cache/skwd-wall-v2/outputs.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.parseOutputs(text())
        onLoadFailed: {
            if (root.currentPath === "") {
                root.currentKind = "";
                root.currentKey = "";
            }
        }
    }

}

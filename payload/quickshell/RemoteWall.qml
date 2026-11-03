import QtQuick
import Quickshell
import Quickshell.Io
import qs
pragma Singleton

// Web wallpapers for the picker. Local results are the base list; this adds
// Wallhaven and the Workshop's most popular scenes when the field is typed.
//
// Results are fetched a page at a time but revealed seven at a time, so the
// strip never has to decode a whole page of remote thumbnails at once. The
// selected Wallhaven card loads its full image (its 432px thumbnail is soft on
// a 2x display); Workshop previews are whatever the author uploaded.
//
// A pick starts a download. Its state lives in a small JSON file written by
// remote-wall.sh, which the card reads for the progress overlay.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property string searchScript: home + "/.config/quickshell/luciddocks/remote-wall-search.py"
    readonly property string applyScript: home + "/.config/quickshell/luciddocks/remote-wall.sh"
    readonly property string downloadDir: home + "/.cache/lucid/downloads"
    readonly property int batchSize: 7

    property bool enabled: Prefs.webWallpapers
    property string query: ""
    // true while "latest" (no query) is showing after the local end
    property bool latest: false
    // what the picker sees; pool is fetched but not revealed yet
    property var items: []
    property var pool: []
    property bool loading: false
    property bool serverHasMore: false
    property bool hasMore: false
    // per-source pagination: Wallhaven restarts at page 1 when it widens the
    // topRange, while Steam keeps advancing its own page
    property int whPage: 1
    property int steamPage: 1
    property int whRange: 0
    property int steamRange: 0
    property bool whMore: true
    property bool steamMore: true
    property bool fresh: true
    readonly property int maxPagesPerRange: 10
    readonly property var topRanges: ["1d", "3d", "1w", "1M", "3M", "6M", "1y"]
    readonly property var steamRanges: [1, 3, 7, 14, 30, 90, 365]
    readonly property bool canEscalate: root.latest && root.query === ""
        && (root.whRange < root.topRanges.length - 1
            || root.steamRange < root.steamRanges.length - 1)
    // cache/backoff guards
    property double fetchedAt: 0
    property double attemptedAt: 0
    // bumped whenever a request starts or is abandoned
    property int generation: 0
    // bumped whenever the visible list changes
    property int revision: 0
    property string error: ""

    // a newer page arrived while a request was still running
    property int pendingPage: 0

    // key -> { state, progress, total, message } for the card overlay
    property var downloads: ({})
    // Three downloads may run at once. The most recent pick is the one that
    // gets applied; the others still finish and stay cached.
    property var jobs: []
    property var results: ({})
    // Pending picks are written here so a shell restart resumes them.
    readonly property string pendingFile: root.downloadDir + "/pending.json"
    property bool pendingLoaded: false
    property int pickSeq: 0
    property int latestSeq: 0
    property int downloadRevision: 0

    signal downloadApplying(string path)
    // the helper has exited; the picker is deliberately left open
    signal downloadFinished(string path, bool ok)

    function updateHasMore() {
        root.hasMore = root.pool.length > 0 || root.whMore || root.steamMore || root.canEscalate;
        root.serverHasMore = root.whMore || root.steamMore || root.canEscalate;
    }

    function clear() {
        if (root.query === "" && !root.latest && root.items.length === 0 && root.pool.length === 0 && !root.loading && !searchProcess.running)
            return ;

        searchProcess.running = false;
        root.query = "";
        root.latest = false;
        root.items = [];
        root.pool = [];
        root.whPage = 1;
        root.steamPage = 1;
        root.whRange = 0;
        root.steamRange = 0;
        root.whMore = true;
        root.steamMore = true;
        root.fresh = true;
        root.loading = false;
        root.hasMore = false;
        root.serverHasMore = false;
        root.error = "";
        root.attemptedAt = 0;
        root.pendingPage = 0;
        root.generation++;
        root.revision++;
    }

    // The NSFW chip decides both sources; a cached page fetched under the old
    // choice must not survive the switch.
    Connections {
        target: Prefs

        function onWallhavenPurityChanged() {
            root.attemptedAt = 0;
            root.fetchedAt = 0;
        }
    }

    function search(text) {
        const q = String(text || "").trim();
        if (!root.enabled || q === "") {
            root.clear();
            return ;
        }
        // same query in flight, freshly answered, or just attempted: the picker
        // re-runs this on every model change and must not refetch
        if (q === root.query && (root.loading || Date.now() - root.attemptedAt < 3000 || (root.items.length > 0 && Date.now() - root.fetchedAt < 120000)))
            return ;

        root.query = q;
        root.latest = false;
        root.items = [];
        root.pool = [];
        root.whPage = 1;
        root.steamPage = 1;
        root.whRange = 0;
        root.steamRange = 0;
        root.whMore = true;
        root.steamMore = true;
        root.fresh = true;
        root.loading = true;
        root.hasMore = false;
        root.serverHasMore = false;
        root.error = "";
        root.fetchedAt = 0;
        root.attemptedAt = Date.now();
        root.generation++;
        root.revision++;
        debounce.restart();
    }

    // No query: fetch the latest Wallhaven + approved Workshop pages. This is
    // what the picker calls when the local list reaches its last card.
    function loadLatest() {
        if (!root.enabled)
            return ;
        if (root.latest && (root.loading || root.items.length > 0 || root.pool.length > 0))
            return ;
        if (root.latest && Date.now() - root.attemptedAt < 3000)
            return ;

        root.latest = true;
        root.query = "";
        root.items = [];
        root.pool = [];
        root.whPage = 1;
        root.steamPage = 1;
        root.whRange = 0;
        root.steamRange = 0;
        root.whMore = true;
        root.steamMore = true;
        root.fresh = true;
        root.loading = true;
        root.hasMore = false;
        root.serverHasMore = false;
        root.error = "";
        root.fetchedAt = 0;
        root.attemptedAt = Date.now();
        root.generation++;
        root.revision++;
        debounce.restart();
    }

    // one step of "more": reveal a batch we already have, or ask the next
    // source pages when the pool is empty
    function loadMore() {
        if (!root.enabled || root.loading)
            return ;
        if (root.query === "" && !root.latest)
            return ;
        if (root.pool.length > 0) {
            root.revealBatch();
            return ;
        }
        if (!root.advanceSources()) {
            root.updateHasMore();
            root.revision++;
        }
    }

    // Advance whichever source still has results. When Wallhaven's current
    // toplist range is exhausted, widen it (1d -> 3d -> 1w ...) and restart
    // Wallhaven at page 1; Steam stays on its own page.
    function advanceSources() {
        const useRanges = root.latest && root.query === "";
        let advanced = false;

        // Wallhaven: next page inside this toplist range, then the next range.
        if (root.whPage > 0) {
            if (root.whMore && root.whPage < root.maxPagesPerRange) {
                root.whPage++;
                advanced = true;
            } else if (useRanges && root.whRange < root.topRanges.length - 1) {
                root.whRange++;
                root.whPage = 1;
                advanced = true;
            } else {
                root.whPage = 0;
            }
        }

        // Steam keeps its own day scale; ten pages per range on both sides.
        if (root.steamPage > 0) {
            if (root.steamMore && root.steamPage < root.maxPagesPerRange) {
                root.steamPage++;
                advanced = true;
            } else if (useRanges && root.steamRange < root.steamRanges.length - 1) {
                root.steamRange++;
                root.steamPage = 1;
                advanced = true;
            } else {
                root.steamPage = 0;
            }
        }

        if (!advanced)
            return false;
        root.run();
        return true;
    }

    function revealBatch() {
        if (root.pool.length === 0) {
            root.updateHasMore();
            root.revision++;
            return ;
        }

        const batch = root.pool.slice(0, root.batchSize);
        root.pool = root.pool.slice(root.batchSize);
        const seen = {};
        for (var i = 0; i < root.items.length; i++)
            seen[root.items[i].path] = true;

        const next = root.items.slice();
        for (var j = 0; j < batch.length; j++) {
            if (seen[batch[j].path])
                continue;
            seen[batch[j].path] = true;
            next.push(batch[j]);
        }
        root.items = next;
        root.updateHasMore();
        root.revision++;
    }

    function run() {
        if (searchProcess.running) {
            root.pendingPage = 1;
            searchProcess.running = false;
            return ;
        }

        root.loading = true;
        root.attemptedAt = Date.now();
        root.generation++;
        root.revision++;
        const useRanges = root.latest && root.query === "";
        const range = useRanges ? root.topRanges[root.whRange] : "";
        const days = useRanges ? root.steamRanges[root.steamRange] : 1;
        searchProcess.first = root.fresh;
        searchProcess.gen = root.generation;
        searchProcess.command = [
            "python3", root.searchScript,
            "--query", root.query,
            "--wh-page", String(root.whPage),
            "--steam-page", String(root.steamPage),
            "--wh-top-range", range,
            "--steam-days", String(days),
            "--purity", Prefs.wallhavenPurity
        ];
        searchProcess.running = true;
    }

    // Both sources can repeat an item across pages or ranges (a toplist
    // reshuffles between requests; the same scene appears in the 1d and 7d
    // lists). Everything is keyed by its picker path.
    function dedupe(list) {
        const seen = {};
        const out = [];
        for (var i = 0; i < list.length; i++) {
            if (seen[list[i].path])
                continue;
            seen[list[i].path] = true;
            out.push(list[i]);
        }
        return out;
    }

    function appendPool(fetched) {
        if (fetched.length === 0)
            return ;

        const seen = {};
        for (var i = 0; i < root.pool.length; i++)
            seen[root.pool[i].path] = true;
        for (var a = 0; a < root.items.length; a++)
            seen[root.items[a].path] = true;
        const next = root.pool.slice();
        for (var j = 0; j < fetched.length; j++) {
            if (seen[fetched[j].path])
                continue;
            seen[fetched[j].path] = true;
            next.push(fetched[j]);
        }
        root.pool = next;
    }

    function parseOutput(text, first) {
        if (searchProcess.gen !== root.generation)
            return ;

        var data = null;
        try {
            data = JSON.parse(text);
        } catch (e) {
            root.loading = false;
            root.error = "search failed";
            root.revision++;
            return ;
        }

        const w = Array.isArray(data.wallhaven) ? data.wallhaven : [];
        const s = Array.isArray(data.steam) ? data.steam : [];
        // one query, one strip, both sources in it
        const mixed = [];
        const n = Math.max(w.length, s.length);
        for (var i = 0; i < n; i++) {
            if (i < w.length)
                mixed.push(w[i]);
            if (i < s.length)
                mixed.push(s[i]);
        }

        if (first)
            root.pool = root.dedupe(mixed);
        else
            root.appendPool(root.dedupe(mixed));

        root.fresh = false;
        root.whMore = data.wallhavenHasMore === true;
        root.steamMore = data.steamHasMore === true;
        root.error = (data.errors || []).join("; ");
        root.loading = false;
        root.fetchedAt = Date.now();
        root.updateHasMore();
        root.revealBatch();
    }

    function beginDownload(key) {
        var all = {};
        for (var k in root.downloads) all[k] = root.downloads[k];
        all[key] = {
            "state": "starting",
            "progress": 0,
            "total": 0,
            "message": ""
        };
        root.downloads = all;
        root.downloadRevision++;
    }

    function savePending() {
        if (!root.pendingLoaded)
            return ;
        const payload = JSON.stringify({
            "seq": root.pickSeq,
            "latest": root.jobs.length > 0 ? root.latestSeq : 0,
            "jobs": root.jobs
        });
        Quickshell.execDetached([
            "sh", "-c",
            "mkdir -p \"$0\" && printf '%s' \"$1\" > \"$2\"",
            root.downloadDir, payload, root.pendingFile
        ]);
    }

    function restorePending(text) {
        root.pendingLoaded = true;
        var data = null;
        try {
            data = JSON.parse(String(text || ""));
        } catch (e) {
            return ;
        }
        if (!data || !Array.isArray(data.jobs))
            return ;
        root.pickSeq = Math.max(root.pickSeq, Number(data.seq) || 0);
        root.latestSeq = Number(data.latest) || 0;
        const jobs = [];
        for (var i = 0; i < data.jobs.length; i++) {
            const job = data.jobs[i];
            if (!job || !job.key || job.id === undefined)
                continue;
            jobs.push({
                "kind": String(job.kind || ""),
                "id": String(job.id),
                "dir": String(job.dir || ""),
                "key": String(job.key),
                "seq": Number(job.seq) || 0,
                "file": String(job.file || ""),
                "state": "queued"
            });
            if (!root.downloads[job.key])
                root.setDownload(job.key, "starting", 0, 0, "Resuming");
        }
        root.jobs = jobs;
        root.pump();
    }

    function remember(key, value) {
        var all = {};
        for (var k in root.results) all[k] = root.results[k];
        all[key] = value;
        root.results = all;
    }

    function setDownload(key, state, progress, total, message) {
        var all = {};
        for (var k in root.downloads) all[k] = root.downloads[k];
        all[key] = {
            "state": String(state),
            "progress": Number(progress) || 0,
            "total": Number(total) || 0,
            "message": String(message || "")
        };
        root.downloads = all;
        root.downloadRevision++;
    }

    // The helper prints one JSON progress object per line, then the finished
    // path. Both sources share this so a Wallhaven card shows "Downloading"
    // exactly like a Workshop card does.
    function progressLine(key, line) {
        const text = String(line || "").trim();
        if (key === "" || text === "")
            return ;
        if (text.charAt(0) === "{") {
            var d = null;
            try {
                d = JSON.parse(text);
            } catch (e) {
                return ;
            }
            if (!d || typeof d !== "object")
                return ;
            const prev = root.downloads[key] ? root.downloads[key].state : "";
            root.setDownload(key, d.state, d.progress, d.total, d.message);
            if (d.state === "applying" && prev !== "applying")
                root.downloadApplying(key);
            return ;
        }
        if (text.charAt(0) === "/" || text.indexOf("skwd:we:") === 0)
            root.remember(key, text);
    }

    function downloadFor(path) {
        // the property read is the binding dependency for the card overlay
        root.downloadRevision;
        return root.downloads[path] || null;
    }

    function startRemote(kind, id, dir) {
        const seq = ++root.pickSeq;
        root.latestSeq = seq;
        const key = kind === "wallhaven" ? "wh:" + String(id) : "skwd:we:" + String(id);
        const file = root.downloadDir + (kind === "wallhaven"
            ? "/wallhaven-" + String(id) + ".json"
            : "/steam-" + String(id) + ".json");
        root.beginDownload(key);
        const jobs = root.jobs.slice();
        jobs.push({
            "kind": kind,
            "id": String(id),
            "dir": String(dir || ""),
            "key": key,
            "seq": seq,
            "file": file,
            "state": "queued"
        });
        root.jobs = jobs;
        root.savePending();
        root.pump();
    }

    function applyWallhaven(id, dir) {
        root.startRemote("wallhaven", id, dir);
    }

    function applySteam(id) {
        root.startRemote("steam", id, "");
    }

    // A local pick or another action supersedes a download that has not been
    // applied yet; the file still finishes and stays cached.
    function cancelRemoteApply() {
        root.latestSeq = 0;
        root.savePending();
    }

    function workerAt(index) {
        return index === 0 ? worker0 : (index === 1 ? worker1 : worker2);
    }

    function pump() {
        // Steam installs go through one client and one subscription at a time;
        // a second skwd-steam call while the first is downloading fails.
        const steamBusy = root.jobs.some((job) => job.state === "running" && job.kind === "steam");
        for (let i = 0; i < 3; i++) {
            const worker = root.workerAt(i);
            if (!worker || worker.running || worker.slotKey !== "")
                continue;
            const jobs = root.jobs.slice();
            const at = jobs.findIndex((job) => job.state === "queued"
                && !(steamBusy && job.kind === "steam"));
            if (at < 0)
                return ;
            const job = jobs[at];
            job.state = "running";
            root.jobs = jobs;
            root.savePending();
            worker.slotKey = job.key;
            worker.slotSeq = job.seq;
            worker.environment = {
                "REMOTE_WALL_SKIP_APPLY": "1",
                "REMOTE_WALL_PROGRESS_STDOUT": "1"
            };
            worker.command = job.kind === "wallhaven"
                ? [root.applyScript, "wallhaven", job.id, job.dir, job.file]
                : [root.applyScript, "steam", job.id, job.file];
            worker.running = true;
            return ;
        }
    }

    function finishJob(key, seq, code) {
        if (key === "")
            return ;
        const remaining = root.jobs.filter((job) => job.key !== key);
        root.jobs = remaining;
        root.savePending();
        const prev = root.downloads[key] || {};
        if (code === 0) {
            root.setDownload(key, "done", 100, prev.total || 0, "Ready");
        } else if (prev.state !== "error") {
            root.setDownload(key, "error", 0, prev.total || 0, "Download failed");
        }
        root.downloadFinished(key, code === 0);
        if (code === 0 && key.indexOf("skwd:we:") === 0)
            SkwdWall.refresh(true);
        if (code === 0 && seq === root.latestSeq) {
            const path = root.results[key] || "";
            if (path !== "") {
                Quickshell.execDetached([
                    Quickshell.env("HOME") + "/.config/hypr/scripts/wallpaper/set-wallpaper.sh",
                    path
                ]);
            }
        }
        root.pump();
    }

    onEnabledChanged: {
        if (!root.enabled)
            root.clear();
    }

    Timer {
        id: debounce

        interval: 400
        repeat: false
        onTriggered: root.run()
    }

    Process {
        id: searchProcess

        property bool first: true
        property int gen: 0

        stdout: StdioCollector {
            onStreamFinished: root.parseOutput(text, searchProcess.first)
        }
        onExited: (code) => {
            if (root.pendingPage > 0) {
                root.pendingPage = 0;
                root.run();
                return ;
            }
            if (!root.loading || searchProcess.gen !== root.generation)
                return ;
            if (code !== 0) {
                root.loading = false;
                root.error = "search failed";
                root.revision++;
            }
        }
    }

    // Scripting hook for tests and for the picker's own smoke checks.
    IpcHandler {
        target: "remote-wall"

        function wallhaven(id: string): void {
            root.applyWallhaven(id, Prefs.wallpaperDir);
        }

        function steam(id: string): void {
            root.applySteam(id);
        }

        function state(): string {
            return JSON.stringify({
                "downloads": root.downloads,
                "latest": root.latestSeq,
                "results": root.results,
                "jobs": root.jobs.length
            });
        }
    }

    // Load the pending queue once; the file may not exist on a fresh install.
    Process {
        id: pendingLoad

        command: ["sh", "-c", "cat \"$0\" 2>/dev/null || true", root.pendingFile]
        running: true
        stdout: StdioCollector {
            onStreamFinished: root.restorePending(text)
        }
        onExited: {
            if (!root.pendingLoaded)
                root.pendingLoaded = true;
        }
    }

    // Three concurrent workers. Explicit instances instead of a dynamically
    // instanced Process pool: that was fragile at startup.
    RemoteWorker {
        id: worker0
        onProgressLine: (key, line) => root.progressLine(key, line)
        onJobFinished: (key, seq, code) => root.finishJob(key, seq, code)
    }

    RemoteWorker {
        id: worker1
        onProgressLine: (key, line) => root.progressLine(key, line)
        onJobFinished: (key, seq, code) => root.finishJob(key, seq, code)
    }

    RemoteWorker {
        id: worker2
        onProgressLine: (key, line) => root.progressLine(key, line)
        onJobFinished: (key, seq, code) => root.finishJob(key, seq, code)
    }


}

pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// The shell side of lucid-gate.  The daemon owns the ledger; this singleton
// only reads its state file and sends commands through the `gate` CLI.  One
// instance feeds both hosts: the desktop card (GatewayWidget) and the
// foreground overlay (GateOverlay).
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property string binPath: Quickshell.env("LUCID_GATE_BIN") || (root.home + "/.local/bin/gate")
    readonly property string statePath: root.home + "/.local/state/lucid-gate/state.json"
    readonly property string browserPath: Quickshell.env("LUCID_GATE_BROWSER") || "helium-browser"
    readonly property string assetsPath: Quickshell.env("LUCID_GATE_ASSETS") || (root.home + "/src/lucid-gate/qml/assets")
    readonly property string lessonUrlPath: root.home + "/.local/state/lucid-gate/duolingo-url"
    readonly property string duoProgressPath: root.home + "/.local/state/lucid-gate/duolingo-progress.json"

    property var state: root.blankState()
    property bool loaded: false
    // false when the CLI or the daemon could not be reached; the UI shows it
    property bool available: true
    property string lastError: ""
    // bumped once a second while a task runs, so the countdowns stay live
    property int tick: 0
    // the card asked for the small foreground pill (a task started by hand)
    property bool pillWanted: false
    // a Duolingo lesson is open in the big foreground surface
    property bool lessonOpen: false
    // after the lesson completes, keep the surface up long enough to read the
    // summary (Duolingo only; the task itself is already done)
    property bool lessonLinger: false
    // the page to open; restored from disk when the shell restarts mid-lesson
    property string lessonUrl: "https://www.duolingo.com/learn"
    property string savedDuolingoUrl: ""
    // screen-space rect of the widget logo that started the lesson, for the
    // launch morph
    property var launchRect: null
    // bumped whenever a lesson should be loaded (new session, resume, reopen)
    property int lessonRequest: 0
    // the output the current lesson belongs on; each warm view compares against it
    property string lessonTargetScreen: ""
    // the active view has finished loading; the launch tile waits for this
    property bool lessonPageReady: false
    // Duolingo account XP, polled in the background. The first value seen is
    // the baseline: nothing before it is credited.
    property int duoLastXp: -1
    property int duoBaselineXp: -1
    // unix time of the last lesson finished *inside* the gate; XP gained right
    // after that must not be paid out twice in the background poll
    property real duoInternalAt: 0
    property bool duoProgressLoaded: false
    property string duoError: ""

    readonly property var tasks: root.state.tasks || []
    readonly property var gates: root.state.gates || ({})
    readonly property var sessions: root.state.sessions || ({})
    readonly property int balance: Number(root.state.balance || 0)

    readonly property var pendingGates: {
        const out = [];
        const all = root.state.gates || ({});
        for (const key in all) {
            const gate = all[key];
            if (gate && gate.state === "pending")
                out.push(gate);

        }
        out.sort((a, b) => Number(a.created || 0) - Number(b.created || 0));
        return out;
    }
    readonly property var gate: root.pendingGates.length > 0 ? root.pendingGates[0] : null
    readonly property int pendingCount: root.pendingGates.length

    readonly property var runningSessions: {
        const out = [];
        const all = root.state.sessions || ({});
        for (const key in all) {
            const session = all[key];
            if (session && session.state === "running")
                out.push(session);

        }
        out.sort((a, b) => Number(a.started || 0) - Number(b.started || 0));
        return out;
    }
    readonly property var running: root.runningSessions.length > 0 ? root.runningSessions[root.runningSessions.length - 1] : null

    function blankState() {
        return ({
            "version": 1,
            "balance": 0,
            "gates": ({}),
            "sessions": ({}),
            "tasks": [],
            "stats": ({})
        });
    }

    function taskFor(taskId) {
        for (let i = 0; i < root.tasks.length; i++) {
            if (root.tasks[i].id === taskId)
                return root.tasks[i];

        }
        return null;
    }

    function sessionFor(taskId) {
        const list = root.runningSessions;
        for (let i = list.length - 1; i >= 0; i--) {
            if (list[i].task === taskId)
                return list[i];

        }
        return null;
    }

    // seconds left on a session; reads tick so bindings follow the clock
    function remaining(session) {
        if (!session)
            return 0;

        root.tick;
        return Math.max(0, Number(session.started || 0) + Number(session.min || 0) - Date.now() / 1000);
    }

    function progress(session) {
        if (!session || Number(session.min || 0) <= 0)
            return 1;

        return Math.max(0, Math.min(1, 1 - root.remaining(session) / Number(session.min)));
    }

    function clock(seconds) {
        const total = Math.max(0, Math.ceil(seconds));
        return total >= 60 ? Math.floor(total / 60) + ":" + (total % 60 < 10 ? "0" : "") + (total % 60) : total + "s";
    }

    function absorb(raw) {
        const first = !root.loaded;
        try {
            const parsed = JSON.parse(raw);
            if (parsed && typeof parsed === "object") {
                root.state = parsed;
                root.available = true;
                root.lastError = "";
                if (first) {
                    const sessions = parsed.sessions || ({});
                    for (const key in sessions) {
                        const session = sessions[key];
                        if (session && session.state === "running" && session.task === "duolingo") {
                            resumeTimer.restart();
                            break;
                        }
                    }
                }
            }
        } catch (e) {
            root.lastError = "Could not read the gate ledger";
        }
        root.loaded = true;
    }

    onRunningChanged: {
        if (root.running === null) {
            root.pillWanted = false;
            if (!root.lessonLinger)
                root.lessonOpen = false;
        }

    }

    // ---- commands ---------------------------------------------------------
    // Commands are small and infrequent, so one Process drains a queue.  The
    // state file is the reply; every mutation makes the daemon rewrite it.
    property var queue: []

    function run(args) {
        root.queue = root.queue.concat([args]);
        root.pump();
    }

    function pump() {
        if (gateProc.running || root.queue.length === 0)
            return ;

        const next = root.queue[0];
        root.queue = root.queue.slice(1);
        gateProc.command = next;
        gateProc.running = true;
    }

    function startTask(taskId, origin) {
        const task = root.taskFor(taskId);
        const existing = root.sessionFor(taskId);
        root.lessonLinger = false;
        root.launchRect = (origin !== undefined && origin !== null) ? origin : null;
        if (task !== null && task.kind === "duolingo") {
            root.lessonUrl = (existing !== null && root.savedDuolingoUrl !== "")
                ? root.savedDuolingoUrl
                : ((task.url && task.url !== "") ? task.url : "https://www.duolingo.com/learn");
        }
        if (task !== null && task.kind === "instant") {
            // a debug/instant task: start and immediately claim it
            root.run([root.binPath, "start", taskId]);
            root.run([root.binPath, "complete", taskId]);
            refreshTimer.restart();
            return ;
        }
        root.run([root.binPath, "start", taskId]);
        if (task !== null && task.kind === "browser")
            root.openBrowser(task);

        if (task !== null && task.kind === "duolingo") {
            root.lessonOpen = true;
            root.lessonPageReady = false;
            root.lessonRequest++;
            root.pillWanted = false;
        } else {
            root.pillWanted = true;
        }
        refreshTimer.restart();
    }

    function readDuoProgress(raw) {
        try {
            const progress = JSON.parse(raw);
            root.duoLastXp = Number(progress.lastXp || -1);
            root.duoBaselineXp = Number(progress.baselineXp || -1);
            root.duoInternalAt = Number(progress.internalAt || 0);
        } catch (e) {
            root.duoLastXp = -1;
            root.duoBaselineXp = -1;
            root.duoInternalAt = 0;
        }
        root.duoProgressLoaded = true;
    }

    function saveDuoProgress() {
        // coalesce: a completion stamps internalAt and then the report moves
        // lastXp in the same turn, and two immediate FileView writes can race
        duoSave.restart();
    }

    function reportDuoProgress(xp) {
        xp = Number(xp) || 0;
        if (xp <= 0)
            return ;
        if (!root.duoProgressLoaded)
            return ;
        // start from now: the first observed total is the baseline
        if (root.duoLastXp <= 0) {
            root.duoLastXp = xp;
            root.duoBaselineXp = xp;
            root.saveDuoProgress();
            return ;
        }
        if (xp < root.duoLastXp) {
            root.duoLastXp = xp;
            root.saveDuoProgress();
            return ;
        }
        if (xp === root.duoLastXp)
            return ;

        const now = Date.now() / 1000;
        // a lesson finished here shows up as XP a little later; the stamp is
        // written when it completes, so the poll can recognise it even if the
        // ledger has not been re-read yet
        let internal = root.duoInternalAt > 0 && now - root.duoInternalAt < 600;
        if (!internal) {
            const sessions = root.state.sessions || ({});
            for (const key in sessions) {
                const session = sessions[key];
                if (session.task === "duolingo" && session.state === "done"
                    && Number(session.finished || 0) > now - 600) {
                    internal = true;
                    break;
                }
            }
        }

        const delta = xp - root.duoLastXp;
        if (!internal) {
            // one reward per lesson-shaped XP step; a poll usually spans one
            const lessons = Math.max(1, Math.round(delta / 20));
            for (let i = 0; i < lessons; i++) {
                root.run([root.binPath, "credit", "160",
                    "--ref", "duolingo-xp-" + xp + "-" + i,
                    "--label", "Duolingo lesson"]);
            }
        }
        root.duoLastXp = xp;
        root.saveDuoProgress();
    }

    function markInternalDuo() {
        root.duoInternalAt = Date.now() / 1000;
        if (root.duoProgressLoaded)
            root.saveDuoProgress();
    }

    function completeManualDuolingo() {
        root.markInternalDuo();
        root.run([root.binPath, "start", "duolingo"]);
        root.run([root.binPath, "complete", "duolingo"]);
    }

    function rememberLessonUrl(url) {
        if (!url || String(url).indexOf("duolingo.com") < 0)
            return ;

        root.savedDuolingoUrl = String(url);
        lessonUrlFile.setText(String(url) + "\n");
    }

    function closeLesson() {
        const session = root.sessionFor("duolingo");
        console.log("lucid-gate: closeLesson", session ? session.id : "no session");
        if (session !== null)
            root.abandon(session.id);

        root.lessonLinger = false;
        root.lessonOpen = false;
    }

    function lingerLesson(ms) {
        root.lessonLinger = true;
        lessonLingerTimer.interval = Math.max(0, Number(ms) || 0);
        lessonLingerTimer.restart();
    }

    function completeTask(taskId) {
        if (taskId === "duolingo")
            root.markInternalDuo();
        root.run([root.binPath, "complete", taskId]);
        refreshTimer.restart();
    }

    function abandon(sessionId) {
        console.log("lucid-gate: abandon", sessionId);
        root.run([root.binPath, "abandon", sessionId]);
        refreshTimer.restart();
    }

    function unlock(gateId) {
        root.run([root.binPath, "unlock", gateId]);
        refreshTimer.restart();
    }

    function cancel(gateId) {
        root.run([root.binPath, "cancel", gateId]);
        refreshTimer.restart();
    }

    function request(place, label, cost) {
        const args = [root.binPath, "request", "--place", place || "unknown", "--label", label || ""];
        if (cost !== undefined && cost !== null && cost !== "")
            args.push("--cost", String(cost));

        root.run(args);
        refreshTimer.restart();
    }

    function openBrowser(task) {
        if (!task || !task.url)
            return ;

        browser.command = [root.browserPath, "--app=" + task.url, "--class=lucid-gate-" + task.id,
            "--window-size=1280,900"];
        browser.running = true;
    }

    function refresh() {
        stateFile.reload();
    }

    Timer {
        id: duoSave

        interval: 150
        onTriggered: duoProgressFile.setText(JSON.stringify({
            "lastXp": root.duoLastXp,
            "baselineXp": root.duoBaselineXp,
            "internalAt": root.duoInternalAt,
            "updated": Date.now() / 1000
        }) + "\n")
    }

    FileView {
        id: duoProgressFile

        path: root.duoProgressPath
        blockLoading: true
        printErrors: false
        onLoaded: root.readDuoProgress(text())
        onLoadFailed: {
            root.duoProgressLoaded = true;
            root.duoLastXp = -1;
        }
    }

    FileView {
        id: lessonUrlFile

        path: root.lessonUrlPath
        watchChanges: true
        blockLoading: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.savedDuolingoUrl = text().trim()
        onLoadFailed: root.savedDuolingoUrl = ""
    }

    FileView {
        id: stateFile

        path: root.statePath
        watchChanges: true
        blockLoading: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.absorb(text())
        onLoadFailed: root.loaded = true
    }

    // a mutation and the daemon's write race by a few milliseconds; watch
    // changes cover the normal case, this covers the rest
    Timer {
        id: refreshTimer

        interval: 140
        onTriggered: root.refresh()
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.running !== null || root.pendingCount > 0
        onTriggered: root.tick++
    }

    Timer {
        id: resumeTimer

        interval: 300
        onTriggered: {
            if (root.running !== null && root.running.task === "duolingo" && !root.lessonOpen) {
                root.lessonUrl = root.savedDuolingoUrl !== ""
                    ? root.savedDuolingoUrl
                    : "https://www.duolingo.com/learn";
                root.lessonOpen = true;
                root.lessonPageReady = false;
                root.lessonRequest++;
            }
        }
    }

    Timer {
        id: lessonLingerTimer

        interval: 2000
        onTriggered: {
            root.lessonLinger = false;
            root.lessonOpen = false;
        }
    }

    Process {
        id: gateProc

        stderr: StdioCollector {
            id: processError

            onStreamFinished: {
                const text = this.text.trim();
                if (text !== "")
                    root.lastError = text;

            }
        }

        onExited: (code) => {
            root.pump();
            if (!gateProc.running)
                refreshTimer.restart();

        }
    }

    Process {
        id: browser
    }

    Component.onCompleted: root.run([root.binPath, "status"])

    IpcHandler {
        target: "gate-core"

        function start(task: string): string {
            GateCore.startTask(task);
            return "started " + task;
        }

        function startAt(task: string, x: string, y: string, w: string, h: string, screen: string): string {
            GateCore.startTask(task, {
                "x": Number(x),
                "y": Number(y),
                "w": Number(w),
                "h": Number(h),
                "screen": screen
            });
            return "started " + task;
        }

        function complete(task: string): string {
            GateCore.completeTask(task);
            return "completing " + task;
        }

        // debug/inspection hook: report an XP total by hand, or just read the
        // baseline state
        function duo(xp: string, internal: string): string {
            if (String(internal) !== "")
                GateCore.markInternalDuo();
            if (String(xp) !== "")
                GateCore.reportDuoProgress(Number(xp));

            return JSON.stringify({
                lastXp: root.duoLastXp,
                baselineXp: root.duoBaselineXp,
                loaded: root.duoProgressLoaded
            });
        }

        function pill(on: bool): string {
            GateCore.pillWanted = on;
            return "pill " + on;
        }

        function state(): string {
            return JSON.stringify({
                balance: root.balance,
                gate: root.gate,
                running: root.running,
                tasks: root.tasks
            });
        }
    }
}

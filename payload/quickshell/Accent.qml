pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs

// Long-press alternate spellings.
//
// Hyprland's own key-repeat state arms the picker (see
// ~/.config/hypr/lucid-accent.lua) and leaves a small request in the runtime
// directory.  This singleton turns that request into the list of spellings for
// the key and runs the insert/dismiss state machine.
//
// The UI lives in lucidaccent/AccentPicker.qml; one transparent, always-mapped
// surface per output is kept ready so taking keyboard focus is a property
// change rather than a new layer surface.  Lower-case keys raise the card
// after a deliberate hold and have already stopped the app's repeat; the
// upper-case path takes focus just before the repeat.
Singleton {
    id: root

    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
    readonly property string requestPath: root.runtimeDir + "/lucid-accent.json"
    readonly property string keymapScript: (Quickshell.shellDir || (Quickshell.env("HOME") + "/.config/quickshell")) + "/scripts/accent-keymap.py"

    // layout tables and base letter -> spellings, built once by the script
    property bool keymapLoaded: false
    property string keymapSignature: ""
    property var layouts: []
    property var variants: ({})

    // picker session
    property bool open: false
    // leaving: focus already released, card still fading out
    property bool closing: false
    property string screenName: ""
    property string baseChar: ""
    property var items: []
    property int selected: 0
    property var targetToplevel: null
    property double pressMs: 0
    property int repeatDelay: 250
    property int repeatRate: 25
    property int layoutIndex: 0
    // repeats the Lua hook could not stop (normally zero)
    property int leakedRepeats: 0
    property bool hasWtype: false
    // last request sequence, so a duplicated dispatch cannot open it twice
    property double lastSeq: -1
    property var pendingRequest: null
    property string pendingText: ""

    // ---- keymap ----------------------------------------------------------

    function loadKeymap() {
        if (keymapProc.running)
            return ;

        keymapProc.running = true;
    }

    function parseKeymap(text) {
        try {
            const doc = JSON.parse(text);
            if (!doc || !Array.isArray(doc.layouts) || !doc.variants)
                return ;

            root.layouts = doc.layouts;
            root.variants = doc.variants;
            root.keymapSignature = doc.signature || "";
            root.keymapLoaded = true;
            if (root.pendingRequest) {
                const req = root.pendingRequest;
                root.pendingRequest = null;
                root.applyRequest(req);
            }
        } catch (e) {
            console.log("Accent: keyboard map parse failed:", e);
        }
    }

    function screenFor(name) {
        const screens = Quickshell.screens;
        if (name) {
            for (let i = 0; i < screens.length; i++) {
                if (screens[i].name === name)
                    return screens[i];
            }
        }
        return Monitors.focusedScreen || (screens.length > 0 ? screens[0] : null);
    }

    function letterFor(req) {
        if (!root.keymapLoaded)
            return "";

        const layout = root.layouts[req.layout] || root.layouts[0];
        if (!layout || !layout.keys)
            return "";

        const pair = layout.keys[String(req.code)];
        if (!pair)
            return "";

        // Caps Lock flips the level like Shift does.  Hold both and you get
        // the unshifted letter again.
        const shifted = (req.shift === true) !== (req.caps === true);
        return pair[shifted ? 1 : 0] || pair[0] || "";
    }

    // ---- request ---------------------------------------------------------

    function pollRequest() {
        if (root.open) {
            // the picker already owns the keyboard; a second long press while
            // it is up must not replace the list under the pointer
            return ;
        }
        requestProc.running = false;
        requestProc.running = true;
    }

    function parseRequest(text) {
        if (!text || text.trim() === "")
            return ;

        let req;
        try {
            req = JSON.parse(text);
        } catch (e) {
            return ;
        }
        if (!req || req.seq === root.lastSeq)
            return ;

        root.lastSeq = req.seq;
        if (!root.keymapLoaded) {
            root.pendingRequest = req;
            return ;
        }
        root.applyRequest(req);
    }

    function applyRequest(req) {
        if (root.open || Lockscreen.locked)
            return ;

        const base = root.letterFor(req);
        if (base === "")
            return ;

        const list = root.variants[base] || [];
        if (list.length === 0)
            return ;

        // Prefer the display Quickshell sees as focused right now.  The Lua
        // request's monitor is a fallback: the Hyprland window object can be
        // a beat behind a focus change, while Hyprland's active-toplevel IPC
        // (which drives Monitors.focusedScreen) is current.
        const screen = Monitors.focusedScreen || root.screenFor(req.mon);
        root.baseChar = base;
        root.items = list;
        root.selected = 0;
        root.pressMs = Number(req.press) || Date.now();
        root.repeatDelay = Number(req.delay) || 250;
        root.repeatRate = Number(req.rate) || 25;
        root.layoutIndex = Number(req.layout) || 0;
        // The Lua side stops a lower-case app repeat before it starts; its
        // request says how many repeats it could not stop.  The picker then
        // removes the one character the key press itself inserted plus those,
        // never a guessed run of three.
        root.leakedRepeats = Math.max(0, Math.min(1, Number(req.leaks) || 0));
        root.screenName = screen ? screen.name : "";
        // must be read before the surface takes focus: layer surfaces are not
        // toplevels, but store the window we are about to cover anyway
        root.targetToplevel = ToplevelManager.activeToplevel;
        root.open = true;
        root.closing = false;
        safetyTimer.restart();
    }

    // ---- navigation ------------------------------------------------------

    function step(delta) {
        if (!root.open || root.closing || root.items.length === 0)
            return ;

        const n = root.items.length;
        root.selected = ((root.selected + delta) % n + n) % n;
    }

    function choose(index) {
        if (!root.open || root.closing)
            return ;

        const i = (index >= 0 && index < root.items.length) ? index : root.selected;
        const text = root.items[i];
        if (!text)
            return ;

        root.closing = true;
        // Release the exclusive keyboard grab first; the target window gets
        // the keyboard back automatically, but activating it also covers the
        // case where another window took focus in the meantime.  wtype runs a
        // beat later, after the compositor has actually moved focus back.
        root.pendingText = text;
        if (root.targetToplevel)
            root.targetToplevel.activate();

        typeTimer.restart();
        closeTimer.restart();
    }

    function dismiss(refocus) {
        if (!root.open || root.closing)
            return ;

        root.closing = true;
        root.pendingText = "";
        if (refocus !== false && root.targetToplevel)
            root.targetToplevel.activate();
        closeTimer.restart();
    }

    function finishClose() {
        root.open = false;
        root.closing = false;
        root.items = [];
        root.baseChar = "";
        root.leakedRepeats = 0;
        root.pressMs = 0;
        root.targetToplevel = null;
        root.pendingRequest = null;
        root.pendingText = "";
    }

    function typeText(text) {
        if (!root.hasWtype) {
            Quickshell.execDetached(["wl-copy", "--", text]);
            return ;
        }

        // The target already received the pressed key.  The Lua side stopped
        // its auto-repeat before the first repeat, so this is normally exactly
        // one backspace (the pressed character), not a guessed run.
        let backspaces = 1 + root.leakedRepeats;
        backspaces = Math.max(1, Math.min(2, backspaces));
        const cmd = ["wtype"];
        for (let i = 0; i < backspaces; i++)
            cmd.push("-k", "BackSpace");
        cmd.push("--", text);
        typeProc.command = cmd;
        typeProc.running = true;
    }

    // ---- test hook -------------------------------------------------------

    function preview(letter) {
        if (root.open)
            return "busy";

        const list = root.variants[letter] || [];
        if (list.length === 0)
            return "no spellings for " + letter;

        const screen = Monitors.focusedScreen || (Quickshell.screens.length > 0 ? Quickshell.screens[0] : null);
        root.baseChar = letter;
        root.items = list;
        root.selected = 0;
        root.pressMs = Date.now() + 1000;
        root.repeatDelay = 250;
        root.repeatRate = 25;
        root.layoutIndex = 0;
        root.leakedRepeats = 0;
        root.screenName = screen ? screen.name : "";
        root.targetToplevel = ToplevelManager.activeToplevel;
        root.open = true;
        root.closing = false;
        safetyTimer.restart();
        return "ok";
    }

    // ---- processes -------------------------------------------------------

    Process {
        id: keymapProc

        command: ["/usr/bin/python3", root.keymapScript]

        stdout: StdioCollector {
            onStreamFinished: root.parseKeymap(this.text)
        }

        stderr: StdioCollector {
            id: keymapErr

            onStreamFinished: {
                if (this.text.trim() !== "")
                    console.log("Accent: keyboard map:", this.text.trim());
            }
        }

        onExited: (code) => {
            if (code !== 0)
                console.log("Accent: keyboard map exited with", code);
        }
    }

    Process {
        id: requestProc

        command: ["cat", root.requestPath]

        stdout: StdioCollector {
            onStreamFinished: root.parseRequest(this.text)
        }
    }

    Process {
        id: typeProc
    }

    Process {
        id: wtypeCheck

        running: true
        command: ["sh", "-c", "command -v wtype >/dev/null 2>&1"]

        onExited: (code) => {
            root.hasWtype = code === 0;
        }
    }

    Timer {
        id: closeTimer

        // Outlast the 70 ms focus hand-off/type timer even with reduced motion
        // (Theme.durExit can be zero).  The card itself still fades on its own
        // duration; this only keeps the session alive long enough to insert.
        interval: Math.max(260, Theme.durExit)

        onTriggered: root.finishClose()
    }

    Timer {
        id: typeTimer

        // the compositor needs a beat to hand the keyboard back before wtype
        // can reach the window we came from
        interval: 70

        onTriggered: {
            const text = root.pendingText;
            root.pendingText = "";
            if (text !== "")
                root.typeText(text);
        }
    }

    Timer {
        id: safetyTimer

        // a lost key or a compositor hiccup must not leave an exclusive
        // keyboard grab on screen forever
        interval: 12000

        onTriggered: {
            if (root.open)
                root.dismiss();

        }
    }

    Component.onCompleted: {
        root.loadKeymap();
    }

    Connections {
        target: Lockscreen

        function onLockedChanged() {
            if (Lockscreen.locked)
                root.dismiss(false);

        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event.name === "configreloaded")
                root.loadKeymap();

        }
    }

    IpcHandler {
        target: "accent"

        // qs ipc call accent test 'a'
        function test(letter: string): string {
            return root.preview(letter);
        }

        function close(): void {
            root.dismiss();
        }

        function status(): string {
            return root.keymapLoaded ? ("keymap " + root.layouts.length + " layouts, " + Object.keys(root.variants).length + " letters") : "keymap loading";
        }

        function reload(): string {
            root.loadKeymap();
            return "reloading";
        }

    }

}

import QtQuick
import QtQuick.Controls.Basic as QQC
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "components"
import "components/squircle"

// The whole widget: a top-right layer surface that is absent until Super+T,
// a compact ask box that unfolds into a chat, and a tiny state file whose only
// remembered value is the target language.
PanelWindow {
    id: root

    readonly property var languages: [
        { "code": "fr", "name": "Français", "prompt": "French" },
        { "code": "lb", "name": "Lëtzebuergesch", "prompt": "Luxembourgish" },
        { "code": "ru", "name": "Русский", "prompt": "Russian" },
        { "code": "de", "name": "Deutsch", "prompt": "German" }
    ]

    property bool shown: false
    property bool rendered: false
    // 0..1, overshoots slightly on the way in
    property real entry: 0
    property bool chat: false
    property bool animateMorph: true
    property real morph: root.chat ? 1 : 0
    property string targetCode: "fr"
    property string draft: ""
    property bool busy: false
    property var history: []
    property string requestLanguage: "fr"
    property var targetScreen: null
    // Hyprland's own margins, read on open: top/right are what matter here
    property real gapsTop: 16
    property real gapsRight: 25
    property real reservedTop: 53
    property real reservedRight: 0
    property bool stateReady: false
    property bool languageChosen: false
    property bool languageDirty: false
    property string opencodeBin: "opencode"
    // none = reasoning.effort none. A simple translation is ~42 tokens and
    // 0 reasoning tokens at the provider; anything higher only adds latency.
    readonly property string modelVariant: "none"
    // fetch the Go credential once, in memory only, and hand it to the helper
    // through its environment (not a command line)
    property string providerKey: ""
    property var lastUsage: ({})
    property int lastLatencyMs: 0
    property bool busyDirect: false
    property int pendingId: 0
    property int requestSeq: 0
    property int translatorRestarts: 0
    property string translatorStderr: ""
    property string pendingKind: "translate"
    property string pendingMeta: ""
    property string pendingSource: ""
    property string lastSource: ""
    property string lastTranslation: ""
    property string lastTranslationLang: ""
    property int lastTranslationHistoryIndex: -1
    property var metaHistory: []
    readonly property string serverPath: String(Qt.resolvedUrl("scripts/translate_server.py")).replace("file://", "")
    readonly property string configHome: Theme.configHome

    readonly property real clampM: Math.max(0, Math.min(1, root.morph))
    readonly property int pad: Theme.dp(16)
    readonly property int topRowH: Theme.dp(48)
    readonly property int railH: Theme.dp(34)
    readonly property int compactW: Theme.dp(424)
    readonly property int chatW: Theme.dp(452)
    readonly property int compactH: Theme.dp(128)
    readonly property int chatH: Math.max(Theme.dp(340), Math.min(Theme.dp(566), (root.screen ? root.screen.height : 900) - root.topMargin - Theme.dp(24)))
    // a little extra breathing room beyond the compositor's own margins
    readonly property int extraMargin: Theme.dp(20)
    readonly property int topMargin: Math.round(root.reservedTop + root.gapsTop + root.extraMargin)
    readonly property int rightMargin: Math.round(root.reservedRight + root.gapsRight + root.extraMargin)
    readonly property real markSize: Theme.dp(40)
    readonly property real composerH: Theme.dp(52) + (Theme.dp(64) - Theme.dp(52)) * root.clampM
    readonly property real composerX: root.pad + (root.markSize + Theme.dp(10)) * (1 - root.clampM)
    readonly property real composerW: root.cardW - root.pad * 2 - (root.markSize + Theme.dp(10)) * (1 - root.clampM)
    readonly property real composerY: root.pad + root.clampM * (root.cardH - root.pad * 2 - root.composerH)
    // compact: the rail starts at the composer's left edge and is vertically
    // centred in the space between the composer and the card's bottom edge
    readonly property real railHeaderY: root.pad + root.topRowH + Theme.dp(6)
    readonly property real railCompactY: root.pad + Theme.dp(52) + Math.max(0, (root.compactH - (root.pad + Theme.dp(52)) - root.railH) / 2)
    readonly property real railX: root.pad + (root.markSize + Theme.dp(10)) * (1 - root.clampM)
    readonly property real railW: root.cardW - root.pad * 2 - (root.markSize + Theme.dp(10)) * (1 - root.clampM)
    readonly property real railY: root.railHeaderY + (root.railCompactY - root.railHeaderY) * (1 - root.clampM)
    readonly property real messagesY: root.railY + root.railH + Theme.dp(14)
    readonly property real messagesH: Math.max(0, root.composerY - root.messagesY - Theme.dp(12))
    readonly property bool canSend: input.text.trim() !== "" && !root.busy

    Behavior on morph {
        enabled: root.animateMorph

        NumberAnimation {
            duration: Theme.ms(560)
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.curveSpatial
        }

    }

    // Follow the state file until the user makes a choice. That way a slow
    // file read cannot clobber the remembered language with the fallback.
    Binding {
        target: root
        property: "targetCode"
        value: root.normaliseLanguage(st.language)
        when: !root.languageChosen
        restoreMode: Binding.RestoreNone
    }

    readonly property real cardW: root.compactW + (root.chatW - root.compactW) * root.morph
    readonly property real cardH: root.compactH + (root.chatH - root.compactH) * root.morph
    readonly property real cardRadius: Theme.rad(38) + (Theme.rad(30) - Theme.rad(38)) * root.clampM
    readonly property real cardTailRadius: Theme.rad(16) + (Theme.rad(30) - Theme.rad(16)) * root.clampM

    function validLanguage(code) {
        for (var i = 0; i < root.languages.length; i++) {
            if (root.languages[i].code === code)
                return true;
        }
        return false;
    }

    function normaliseLanguage(code) {
        return root.validLanguage(code) ? code : "fr";
    }

    function languageFor(code) {
        if (code === "en")
            return { "code": "en", "name": "English", "prompt": "English" };

        for (var i = 0; i < root.languages.length; i++) {
            if (root.languages[i].code === code)
                return root.languages[i];
        }
        return root.languages[0];
    }

    function languageName(code) {
        return root.languageFor(code).name;
    }

    function codeForLanguageName(name) {
        var n = String(name || "").toLowerCase().trim();
        if (n === "en" || n.indexOf("english") >= 0)
            return "en";

        for (var i = 0; i < root.languages.length; i++) {
            var lang = root.languages[i];
            if (n === lang.code || n.indexOf(lang.prompt.toLowerCase()) >= 0 || n.indexOf(lang.name.toLowerCase()) >= 0)
                return lang.code;
        }
        return "";
    }

    function parseTranslation(rawText) {
        var full = String(rawText || "").trim();
        var targetMatch = /(?:^|\n)\s*(?:\*\*)?TARGET(?:\*\*)?\s*:\s*(?:\*\*)?\s*([^\n]+)/i.exec(full);
        var transMatch = /(?:^|\n)\s*(?:\*\*)?TRANSLATION(?:\*\*)?\s*:\s*([\s\S]*)$/i.exec(full);
        var body = transMatch ? transMatch[1].trim() : full;
        body = body.replace(/^\*\*\s*/, "").replace(/\s*\*\*$/, "").trim();
        var code = targetMatch ? root.codeForLanguageName(targetMatch[1]) : "";
        return {
            "text": root.cleanTranslation(body),
            "lang": code !== "" ? code : root.requestLanguage
        };
    }

    function selectLanguage(code) {
        var next = root.normaliseLanguage(code);
        if (root.targetCode === next)
            return;

        root.languageChosen = true;
        root.languageDirty = true;
        root.targetCode = next;
        st.language = next;
        // write now rather than waiting on the adapter notification: the state
        // file is tiny and the choice must survive a quick close.
        stateFile.writeAdapter();

    }

    function screenNamed(name) {
        var screens = Quickshell.screens;
        for (var i = 0; i < screens.length; i++) {
            if (screens[i].name === name)
                return screens[i];
        }
        return null;
    }

    function refreshGeometry() {
        if (!root.screen)
            return;

        gapsProc.running = false;
        gapsProc.running = true;
    }

    function show() {
        if (root.shown)
            return;

        closeTimer.stop();
        root.resetState();
        var focused = Hyprland.focusedMonitor;
        var wanted = focused && focused.name ? focused.name : "";
        var picked = wanted !== "" ? root.screenNamed(wanted) : null;
        if (picked)
            root.targetScreen = picked;
        else if (!root.targetScreen && Quickshell.screens.length > 0)
            root.targetScreen = Quickshell.screens[0];

        root.refreshGeometry();
        root.shown = true;
        root.rendered = true;
        root.entry = 0;
        enterAnim.restart();
        focusTimer.restart();
        markPulse.restart();
        geomRetry.restart();
        // wake the keep-alive connection while the user is typing; if it is
        // already alive this is a no-op, otherwise the worker reconnects now
        // rather than on the first translation.
        if (translator.running && translator.stdinEnabled)
            translator.write(JSON.stringify({ "warm": true }) + "\n");
    }

    function hide() {
        if (!root.shown)
            return;

        root.shown = false;
        if (root.languageDirty)
            stateFile.writeAdapter();
        root.clearPending();
        if (request.running)
            request.running = false;
        root.chat = false;
        exitAnim.restart();
        closeTimer.restart();
    }

    function toggle() {
        if (root.shown)
            root.hide();
        else
            root.show();
    }

    function resetState() {
        root.animateMorph = false;
        root.chat = false;
        root.animateMorph = true;
        root.draft = "";
        root.history = [];
        root.clearPending();
        root.requestLanguage = root.targetCode;
        root.lastSource = "";
        root.lastTranslation = "";
        root.lastTranslationLang = "";
        root.lastTranslationHistoryIndex = -1;
        root.metaHistory = [];
        // lastUsage/lastLatencyMs are diagnostics only; keep them so debug
        // still reports the last request after the popup has closed.
        messages.clear();
        input.text = "";
        if (request.running)
            request.running = false;
    }

    function clearPending() {
        root.busy = false;
        root.busyDirect = false;
        root.pendingId = 0;
        root.pendingKind = "translate";
        root.pendingMeta = "";
        root.pendingSource = "";
        requestTimer.stop();
    }

    function scrollToEnd() {
        if (root.chat)
            list.positionViewAtEnd();
    }

    function delegateLayout() {
        var out = [];
        for (var i = 0; i < Math.min(list.count, 12); i++) {
            var item = list.itemAtIndex(i);
            out.push(item ? [Math.round(item.y), Math.round(item.height)] : null);
        }
        return out;
    }

    function cleanTranslation(text) {
        var out = String(text || "").trim();
        if (out === "")
            return "";

        // Models sometimes wrap a translation in a code fence or quotes even
        // when asked not to. Strip the wrapper, not the translation.
        out = out.replace(/^```[a-zA-Z0-9_-]*\s*/, "").replace(/\s*```$/, "");
        if ((out.charAt(0) === "\"" && out.charAt(out.length - 1) === "\"") || (out.charAt(0) === "“" && out.charAt(out.length - 1) === "”"))
            out = out.slice(1, -1);

        out = out.replace(/^(translation|traduction|traducción|übersetzung|перевод)\s*:\s*/i, "");
        return out.trim();
    }

    function appendError(detail) {
        var line = String(detail || "").trim().split("\n")[0];
        if (line.length > 160)
            line = line.slice(0, 157) + "…";

        messages.append({
            "kind": "error",
            "text": line !== "" ? line : "The translation service did not answer.",
            "lang": "",
            "label": ""
        });
        Qt.callLater(root.scrollToEnd);
    }

    function finishTranslation(code, outText, errText) {
        if (!root.shown || !root.busy)
            return;

        var raw = "";
        var detail = "";
        var usage = ({});
        try {
            var data = JSON.parse(String(outText || "").trim());
            if (data && typeof data.text === "string") {
                raw = data.text;
                if (data.usage)
                    usage = data.usage;
            } else if (data && data.data && typeof data.data.text === "string") {
                raw = data.data.text;
            } else if (data && data.message) {
                detail = data.message;
            } else if (data && data._tag) {
                detail = data.message || data._tag;
            }
        } catch (e) {
            detail = String(errText || "").trim() || String(outText || "").trim();
        }

        if (raw === "") {
            if (code !== 0 && detail === "")
                detail = "opencode exited with code " + code;
            root.clearPending();
            root.appendError(detail);
            return;
        }

        if (root.pendingKind === "meta")
            root.handleMetaResponse(raw, usage, 0);
        else
            root.handleTranslationResponse(raw, usage, 0);
    }

    function handleTranslationResponse(rawText, usage, latency) {
        if (!root.shown || !root.busy)
            return;

        var parsed = root.parseTranslation(rawText);
        var translated = parsed.text;
        var source = root.pendingSource;
        var language = parsed.lang;
        root.clearPending();

        if (translated === "") {
            root.appendError("The translation service returned no text.");
            return;
        }

        messages.append({
            "kind": "assistant",
            "text": translated,
            "lang": language,
            "label": ""
        });
        root.history = root.history.concat([{ "role": "assistant", "text": translated }]);
        root.lastTranslationHistoryIndex = root.history.length - 1;
        root.lastSource = source;
        root.lastTranslation = translated;
        root.lastTranslationLang = language;
        root.metaHistory = [];
        if (usage)
            root.lastUsage = usage;
        root.lastLatencyMs = Number(latency) || 0;
        input.forceActiveFocus();
        Qt.callLater(root.scrollToEnd);
    }

    function handleMetaResponse(rawText, usage, latency) {
        if (!root.shown || !root.busy)
            return;

        var meta = root.pendingMeta;
        var full = String(rawText || "").trim();
        var prefix = /(?:^|\n)\s*(?:\*\*)?(ANSWER|TRANSLATION)(?:\*\*)?\s*:\s*(?:\*\*)?\s*([\s\S]*)$/i.exec(full);
        var kind = "";
        var body = "";
        if (prefix) {
            kind = prefix[1].toLowerCase();
            body = prefix[2].trim();
        } else {
            var lower = meta.toLowerCase();
            var refine = /(^|\s)(make|less|more|use|change|rewrite|translate|be|keep|avoid|soften|shorten|lengthen|formal|informal|casual|polite|shorter|longer|simpler|literal|natural)\b/i.test(lower);
            var question = /(\?|(^|\s)(why|what|how|when|where|who|which|is|are|was|were|do|does|did|can|could|should|would|will|explain)\b)/i.test(lower);
            kind = (refine || (!question && root.lastTranslation !== "")) ? "translation" : "answer";
            body = full;
        }

        body = body.replace(/^\*\*\s*/, "").replace(/\s*\*\*$/, "").trim();
        root.clearPending();
        if (body === "") {
            root.appendError("The model returned an empty reply.");
            return;
        }

        if (kind === "translation" && root.lastTranslation !== "") {
            var refined = root.cleanTranslation(body);
            if (refined === "") {
                root.appendError("The model returned no refined translation.");
                return;
            }
            messages.append({
                "kind": "refined",
                "text": refined,
                "lang": root.lastTranslationLang,
                "label": "Refined · " + root.languageName(root.lastTranslationLang)
            });
            var idx = root.lastTranslationHistoryIndex;
            if (idx >= 0 && idx < root.history.length) {
                var next = root.history.slice();
                next[idx] = { "role": "assistant", "text": refined };
                root.history = next;
            }
            root.lastTranslation = refined;
        } else {
            var answer = body.replace(/^```[a-zA-Z0-9_-]*\s*/, "").replace(/\s*```$/, "").trim();
            messages.append({
                "kind": "answer",
                "text": answer,
                "lang": "",
                "label": "English"
            });
            root.metaHistory = root.metaHistory.concat([
                { "role": "user", "text": "> " + meta },
                { "role": "assistant", "text": answer }
            ]).slice(-8);
        }

        if (usage)
            root.lastUsage = usage;
        root.lastLatencyMs = Number(latency) || 0;
        input.forceActiveFocus();
        Qt.callLater(root.scrollToEnd);
    }

    function buildMetaPrompt(meta) {
        var hasPrevious = root.lastTranslation !== "";
        var langCode = hasPrevious && root.lastTranslationLang !== "" ? root.lastTranslationLang : root.targetCode;
        var lang = root.languageFor(langCode);
        var out = "You are a translation assistant. The user's new message starts with '>' and is a meta-message.\n\n";
        if (hasPrevious) {
            out += "Previous source sentence: " + root.lastSource + "\n";
            out += "Previous translation into " + lang.prompt + ": " + root.lastTranslation + "\n\n";
        } else {
            out += "There is no previous translation yet.\n\n";
        }

        if (root.metaHistory.length > 0) {
            out += "Recent meta exchange:\n";
            var start = Math.max(0, root.metaHistory.length - 6);
            for (var i = start; i < root.metaHistory.length; i++) {
                var turn = root.metaHistory[i];
                out += turn.role === "user" ? "User: " : "Assistant: ";
                out += turn.text + "\n";
            }
            out += "\n";
        }

        out += "Meta-message: " + meta + "\n\n";
        out += "If this is a question about the translation, the language, or anything else, answer it in English. ";
        out += "Keep an ANSWER as short and direct as possible: use only the words needed, with no preamble and no restating of the question. ";
        if (hasPrevious)
            out += "If it is an instruction to change the translation, re-translate the previous source sentence into " + lang.prompt + " applying the instruction, and output only the revised translation. Do not answer in English in that case. ";
        else
            out += "There is nothing to refine yet; answer in English. ";
        out += "Reply exactly in one of these forms, starting with the label:\n";
        out += "ANSWER: <short, direct English answer>\n";
        if (hasPrevious)
            out += "TRANSLATION: <only the revised translation in " + lang.prompt + ">";
        return out;
    }

    function buildPrompt(languageCode) {
        var lang = root.languageFor(languageCode);
        var out = "Translate the final user message. If it is already in " + lang.prompt + ", translate it into English instead; otherwise translate it into " + lang.prompt + ".\n\n";
        var start = Math.max(0, root.history.length - 12);
        for (var i = start; i < root.history.length; i++) {
            var turn = root.history[i];
            out += turn.role === "user" ? "User: " : "Assistant: ";
            out += turn.text + "\n";
        }
        out += "Reply exactly as:\nTARGET: <English name of the language you translated into>\nTRANSLATION: <only the translation>";
        return out;
    }

    function send() {
        if (!root.canSend)
            return;

        var sentence = input.text.trim();
        if (sentence === "")
            return;

        if (sentence.charAt(0) === ">") {
            root.sendMeta(sentence.slice(1).trim());
            return;
        }

        if (!root.chat) {
            root.chat = true;
            markPulse.restart();
        }

        messages.append({
            "kind": "user",
            "text": sentence,
            "lang": "",
            "label": ""
        });
        root.history = root.history.concat([{ "role": "user", "text": sentence }]);
        root.requestLanguage = root.targetCode;
        root.pendingKind = "translate";
        root.pendingSource = sentence;
        root.busy = true;
        input.text = "";
        input.forceActiveFocus();
        Qt.callLater(root.scrollToEnd);
        root.sendPrompt(root.buildPrompt(root.requestLanguage));
    }

    function sendMeta(meta) {
        if (meta === "") {
            input.text = "";
            root.appendError("Type a question or refinement after >.");
            return;
        }

        if (!root.chat) {
            root.chat = true;
            markPulse.restart();
        }

        messages.append({
            "kind": "instruction",
            "text": "> " + meta,
            "lang": "",
            "label": ""
        });
        root.pendingKind = "meta";
        root.pendingMeta = meta;
        root.busy = true;
        input.text = "";
        input.forceActiveFocus();
        Qt.callLater(root.scrollToEnd);
        root.sendPrompt(root.buildMetaPrompt(meta));
    }

    function sendPrompt(prompt) {
        if (root.providerKey !== "" && translator.running && translator.stdinEnabled) {
            root.busyDirect = true;
            root.pendingId = ++root.requestSeq;
            translator.write(JSON.stringify({
                "id": root.pendingId,
                "prompt": prompt,
                "model": "gpt-6-luna",
                "effort": root.modelVariant
            }) + "\n");
        } else {
            root.busyDirect = false;
            root.pendingId = 0;
            request.environment = ({});
            request.pendingInput = "";
            request.stdinEnabled = false;
            var payload = {
                "model": {
                    "id": "gpt-6-luna",
                    "providerID": "opencode-go",
                    "variant": root.modelVariant
                },
                "prompt": prompt
            };
            request.command = [root.opencodeBin, "api", "post", "/api/experimental/generate", "--data", JSON.stringify(payload)];
            request.running = true;
        }
        requestTimer.restart();
    }

    function translatorLine(line) {
        var textLine = String(line || "").trim();
        if (textLine === "")
            return;

        var data;
        try {
            data = JSON.parse(textLine);
        } catch (e) {
            return;
        }

        if (data.ready !== undefined) {
            if (data.ready)
                root.translatorRestarts = 0;
            else if (data.error)
                root.translatorStderr = String(data.error);
            return;
        }

        if (!root.busyDirect)
            return;
        if (data.id !== undefined && Number(data.id) !== root.pendingId)
            return;

        if (data.error) {
            root.clearPending();
            root.appendError(String(data.error));
            return;
        }

        if (root.pendingKind === "meta")
            root.handleMetaResponse(data.text, data.usage, data.latency_ms);
        else
            root.handleTranslationResponse(data.text, data.usage, data.latency_ms);
    }

    function focusInput() {
        if (root.shown)
            input.forceActiveFocus();
    }

    color: "transparent"
    visible: root.rendered
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "quick-translate"
    WlrLayershell.keyboardFocus: root.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    screen: root.targetScreen ? root.targetScreen : (Quickshell.screens.length > 0 ? Quickshell.screens[0] : null)

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    // Only the painted card takes input. Everything else belongs to whatever
    // is underneath the widget.
    mask: root.rendered ? cardRegion : emptyRegion

    Shortcut {
        sequence: "Escape"
        context: Qt.WindowShortcut
        onActivated: root.hide()
    }

    onScreenChanged: root.refreshGeometry()
    onBusyChanged: {
        if (root.busy)
            Qt.callLater(root.scrollToEnd);
    }
    onVisibleChanged: {
        if (root.visible && root.shown)
            Qt.callLater(root.focusInput);
    }
    Component.onCompleted: {
        if (!root.targetScreen && Quickshell.screens.length > 0)
            root.targetScreen = Quickshell.screens[0];
        root.refreshGeometry();
    }

    Region {
        id: emptyRegion
    }

    Region {
        id: cardRegion

        x: Math.floor(card.x)
        y: Math.floor(card.y)
        width: Math.max(0, Math.ceil(card.width))
        height: Math.max(0, Math.ceil(card.height))
        radius: Math.round(root.cardRadius)
    }

    // ---- state ------------------------------------------------------------
    FileView {
        id: stateFile

        path: root.configHome + "/quick-translate/state.json"
        blockLoading: true
        onLoaded: {
            if (!root.languageChosen && root.validLanguage(st.language))
                root.targetCode = st.language;
            root.languageDirty = false;
        }
        onAdapterUpdated: {
            if (root.stateReady && root.languageDirty)
                stateFile.writeAdapter();
        }

        adapter: JsonAdapter {
            id: st

            property string language: "fr"
        }

    }

    Process {
        id: mkdirState

        command: ["mkdir", "-p", root.configHome + "/quick-translate"]
        running: true
        onExited: root.stateReady = true
    }

    Timer {
        interval: 700
        running: true
        onTriggered: root.stateReady = true
    }

    // ---- Hyprland geometry ------------------------------------------------
    // The bar reserves its strip at the top of the output. The widget starts
    // below that strip plus gaps_out, and stops the same distance from the
    // right edge, so it sits inside the same box as a tiled window.
    Process {
        id: gapsProc

        command: ["sh", "-c", "hyprctl -j monitors; printf '\\n---GAPS---\\n'; hyprctl -j getoption general:gaps_out"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                var chunks = String(this.text || "").split("---GAPS---");
                try {
                    var monitors = JSON.parse(chunks[0]);
                    var wanted = root.screen ? root.screen.name : "";
                    var mon = null;
                    for (var i = 0; i < monitors.length; i++) {
                        if (monitors[i].name === wanted) {
                            mon = monitors[i];
                            break;
                        }
                    }
                    if (!mon && monitors.length > 0)
                        mon = monitors[0];
                    if (mon && mon.reserved && mon.reserved.length >= 2) {
                        var reserved = Number(mon.reserved[1]) || 0;
                        root.reservedTop = reserved > 0 ? reserved : Theme.lucidBarReserved;
                        root.reservedRight = Number(mon.reserved[2]) || 0;
                    }
                } catch (e) {
                }

                try {
                    var opt = JSON.parse(chunks[1] || "{}");
                    var raw = String(opt.css !== undefined && opt.css !== "" ? opt.css : (opt.custom !== undefined && opt.custom !== "" ? opt.custom : (opt.int !== undefined ? opt.int : "16"))).trim();
                    var parts = raw.split(/\s+/).map(Number);
                    var top = 16;
                    var right = 25;
                    if (parts.length === 1) {
                        top = right = parts[0];
                    } else if (parts.length === 2) {
                        top = parts[0];
                        right = parts[1];
                    } else if (parts.length >= 4) {
                        top = parts[0];
                        right = parts[1];
                    }
                    root.gapsTop = top;
                    root.gapsRight = right;
                } catch (e2) {
                }
            }
        }

    }

    // ---- translation request ----------------------------------------------
    // The daemon can be started from the compositor, whose PATH may not include
    // ~/.bun/bin. Resolve the binary once and fall back to the usual Bun path.
    Process {
        id: whichOpencode

        command: ["sh", "-c", "command -v opencode 2>/dev/null || printf '%s' \"$HOME/.bun/bin/opencode\""]
        running: true

        stdout: StdioCollector {
            onStreamFinished: {
                var found = String(this.text || "").trim();
                if (found !== "")
                    root.opencodeBin = found;
                credentialProc.running = true;
            }
        }

    }

    // Read the active OpenCode Go key from the local service. It lives only in
    // this process and in the helper's environment.
    Process {
        id: credentialProc

        command: [root.opencodeBin, "api", "get", "/api/credential"]
        workingDirectory: Quickshell.env("HOME")

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var data = JSON.parse(String(this.text || "").trim());
                    for (var i = 0; i < (data.data || []).length; i++) {
                        var item = data.data[i];
                        if (item.integrationID === "opencode-go" && item.value && item.value.type === "key" && item.value.key) {
                            root.providerKey = item.value.key;
                            break;
                        }
                    }
                } catch (e) {
                }

                if (root.providerKey !== "" && !translator.running) {
                    translator.environment = ({ "QUICK_TRANSLATE_KEY": root.providerKey });
                    translator.running = true;
                }
            }
        }

        stderr: StdioCollector {
        }

    }

    // One long-lived worker. It preconnects at startup so the ~3.7s TLS
    // handshake is not paid by the first translation, and keeps the Responses
    // API socket for later turns.
    Process {
        id: translator

        running: false
        stdinEnabled: false
        command: ["python3", root.serverPath]
        workingDirectory: Quickshell.env("HOME")
        environment: ({ "QUICK_TRANSLATE_KEY": root.providerKey })

        onStarted: translator.stdinEnabled = true

        onExited: (code) => {
            translator.stdinEnabled = false;
            if (root.busyDirect) {
                root.busy = false;
                root.busyDirect = false;
                root.pendingId = 0;
                requestTimer.stop();
                root.appendError("The translation helper stopped (code " + code + ").");
            }
            if (root.providerKey !== "" && root.translatorRestarts < 5) {
                root.translatorRestarts++;
                translatorRestart.restart();
            }
        }

        stdout: SplitParser {
            onRead: (line) => root.translatorLine(line)
        }

        stderr: SplitParser {
            onRead: (line) => {
                root.translatorStderr = line;
            }
        }

    }

    Timer {
        id: translatorRestart

        interval: 1500
        onTriggered: {
            if (root.providerKey !== "" && !translator.running) {
                translator.environment = ({ "QUICK_TRANSLATE_KEY": root.providerKey });
                translator.running = true;
            }
        }
    }

    // Keep the keep-alive socket from going stale while the widget sits hidden.
    // A warm message on a live connection is a no-op; a dead one is replaced in
    // the background before the next opening.
    Timer {
        id: translatorKeepalive

        interval: 120000
        repeat: true
        running: translator.running
        onTriggered: {
            if (translator.running && translator.stdinEnabled)
                translator.write(JSON.stringify({ "warm": true }) + "\n");
        }
    }

    Process {
        id: request

        property string pendingInput: ""

        onStarted: {
            if (request.pendingInput !== "") {
                write(request.pendingInput);
                request.pendingInput = "";
                stdinCloser.restart();
            }
        }

        // Keep OpenCode's project discovery out of the widget's own directory.
        workingDirectory: Quickshell.env("HOME")

        stdout: StdioCollector {
            id: requestOut
        }

        stderr: StdioCollector {
            id: requestErr
        }

        onExited: (code) => root.finishTranslation(code, requestOut.text, requestErr.text)
    }

    Timer {
        id: stdinCloser

        interval: 120
        onTriggered: request.stdinEnabled = false
    }

    Timer {
        id: requestTimer

        interval: 60000
        repeat: false
        onTriggered: {
            if (root.busyDirect) {
                root.clearPending();
                translator.running = false;
                root.appendError("The translation timed out.");
                return;
            }

            if (!request.running)
                return;

            request.running = false;
            root.clearPending();
            root.appendError("The translation timed out. Is the OpenCode service running?");
        }
    }

    // ---- entry / exit -----------------------------------------------------
    NumberAnimation {
        id: enterAnim

        target: root
        property: "entry"
        from: 0
        to: 1
        duration: Theme.ms(360)
        easing.type: Easing.OutBack
        easing.overshoot: 0.7
    }

    NumberAnimation {
        id: exitAnim

        target: root
        property: "entry"
        from: 1
        to: 0
        duration: Theme.ms(210)
        easing.type: Easing.Bezier
        easing.bezierCurve: Theme.curveAccelerate
    }

    Timer {
        id: closeTimer

        interval: Theme.ms(240)
        onTriggered: {
            root.rendered = false;
            root.resetState();
        }
    }

    Timer {
        id: focusTimer

        interval: 100
        onTriggered: {
            root.focusInput();
            focusRetry.restart();
        }
    }

    Timer {
        id: focusRetry

        interval: 280
        onTriggered: root.focusInput()
    }

    // A bar/launcher remap can briefly report reserved=0 on the first read.
    // Read once more after the surface has settled.
    Timer {
        id: geomRetry

        interval: 400
        onTriggered: {
            if (root.shown)
                root.refreshGeometry();
        }
    }

    // ---- card -------------------------------------------------------------
    Item {
        id: card

        x: root.width - root.rightMargin - root.cardW
        y: root.topMargin + (1 - Math.min(1, root.entry)) * Theme.dp(10)
        width: root.cardW
        height: root.cardH
        opacity: Math.max(0, Math.min(1, root.entry))
        scale: 0.9 + 0.1 * root.entry
        transformOrigin: Item.TopRight




        // The lifted edge. Lucid's full-screen lucid-overlay soft-light wash
        // passes over this whole surface exactly as it does over a window.
        SquircleRect {
            x: Theme.dp(1)
            y: Theme.dp(7)
            width: parent.width
            height: parent.height
            radius: root.cardRadius
            smoothing: Theme.squircleF
            fillColor: Theme.shadow
        }

        SquircleRect {
            id: surface

            anchors.fill: parent
            radius: root.cardRadius
            topLeftRadius: root.cardRadius
            topRightRadius: root.cardTailRadius
            bottomLeftRadius: root.cardRadius
            bottomRightRadius: root.cardRadius
            smoothing: Theme.squircleF
            fillColor: Theme.card
            borderWidth: 1
            borderColor: Theme.cardBorder

            Behavior on fillColor {
                ColorAnimation {
                    duration: Theme.ms(300)
                }

            }

            Behavior on borderColor {
                ColorAnimation {
                    duration: Theme.ms(300)
                }

            }

        }

        // the expressive mark: an M3 shape that briefly changes species when
        // the widget starts working
        Item {
            id: mark

            x: root.pad
            y: root.pad + (root.topRowH - root.markSize) / 2
            width: root.markSize
            height: root.markSize

            MaterialShape {
                anchors.fill: parent
                shape: "cookie9"
                to: "softBurst"
                morph: markMorph
                color: Theme.accent
                spin: markSpin
            }

            Icon {
                anchors.centerIn: parent
                name: "translate"
                size: Theme.dp(21)
                color: Theme.fgAccent
            }

        }

        Column {
            x: root.pad + root.markSize + Theme.dp(12)
            y: root.pad + Theme.dp(6)
            width: root.cardW - x - root.pad - Theme.dp(44)
            spacing: Theme.dp(1)
            opacity: Math.max(0, Math.min(1, (root.clampM - 0.08) / 0.92))
            visible: opacity > 0.01

            Text {
                width: parent.width
                text: "Translate"
                color: Theme.text
                elide: Text.ElideRight
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fs(16)
                font.weight: Font.DemiBold
                font.variableAxes: Theme.axes(Theme.fs(16), 560, 0)
            }

            Text {
                width: parent.width
                text: "into " + root.languageName(root.targetCode)
                color: Theme.subtext
                elide: Text.ElideRight
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fs(11.5)
                font.variableAxes: Theme.axes(Theme.fs(11.5), 500, 0)
            }

        }

        Item {
            id: closeButton

            x: root.cardW - root.pad - Theme.dp(32)
            y: root.pad + Theme.dp(8)
            width: Theme.dp(32)
            height: Theme.dp(32)
            opacity: Math.max(0, Math.min(1, (root.clampM - 0.1) / 0.9))
            visible: opacity > 0.01

            SquircleRect {
                anchors.fill: parent
                radius: Theme.pill(height)
                smoothing: Theme.squircleF
                fillColor: closeMouse.containsMouse ? Theme.alpha(Theme.text, 0.08) : "transparent"

                Behavior on fillColor {
                    ColorAnimation {
                        duration: Theme.ms(140)
                    }

                }

            }

            Icon {
                anchors.centerIn: parent
                name: "close"
                size: Theme.dp(17)
                color: Theme.subtext
            }

            MouseArea {
                id: closeMouse

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.hide()
            }

        }

        LanguageRail {
            id: rail

            x: root.railX
            y: root.railY
            width: root.railW
            height: root.railH
            languages: root.languages
            current: root.targetCode
            onSelected: (code) => root.selectLanguage(code)
            onLeaveRequested: input.forceActiveFocus()
            onTextTyped: (text) => {
                input.forceActiveFocus();
                var pos = Math.max(0, Math.min(input.length, input.cursorPosition));
                input.insert(pos, text);
                input.cursorPosition = pos + text.length;
            }
        }

        Rectangle {
            x: root.railX
            y: root.railY + root.railH + Theme.dp(8)
            width: root.railW
            height: 1
            color: Theme.divider
            opacity: Math.max(0, Math.min(1, (root.clampM - 0.2) / 0.8))
        }

        ListView {
            id: list

            x: root.pad
            y: root.messagesY
            width: root.cardW - root.pad * 2
            height: root.messagesH
            visible: root.clampM > 0.12
            opacity: Math.max(0, Math.min(1, (root.clampM - 0.12) / 0.7))
            clip: true
            spacing: Theme.dp(10)
            model: messages
            boundsBehavior: Flickable.StopAtBounds
            cacheBuffer: Theme.dp(300)
            onCountChanged: Qt.callLater(root.scrollToEnd)
            onContentHeightChanged: Qt.callLater(root.scrollToEnd)

            delegate: MessageBubble {
                width: ListView.view.width
                kind: model.kind
                text: model.text
                order: index
                languageName: model.label || root.languageName(model.lang)
            }

            footer: Item {
                width: list.width
                height: root.busy ? Theme.dp(56) : 0
                visible: root.busy

                SquircleRect {
                    x: 0
                    y: 0
                    width: Theme.dp(132)
                    height: Theme.dp(46)
                    radius: Theme.rad(22)
                    bottomLeftRadius: Theme.rad(7)
                    smoothing: Theme.squircleF
                    fillColor: Theme.assistantBubble

                    LoadingMorph {
                        x: Theme.dp(12)
                        anchors.verticalCenter: parent.verticalCenter
                        size: Theme.dp(22)
                        color: Theme.accent
                        running: root.busy
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.dp(42)
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.pendingKind === "meta" ? "Thinking" : "Translating"
                        color: Theme.subtext
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fs(12)
                        font.variableAxes: Theme.axes(Theme.fs(12), 500, 0)
                    }

                }

            }

        }

        // the composer: starts in the top row, then travels to the bottom
        // while the card opens into a conversation
        SquircleRect {
            id: composerBg

            x: root.composerX
            y: root.composerY
            width: root.composerW
            height: root.composerH
            radius: Theme.pill(height)
            smoothing: Theme.squircleF
            fillColor: Theme.composer
            borderWidth: input.activeFocus ? 2 : 1
            borderColor: input.activeFocus ? Theme.accent : Theme.composerBorder

            Behavior on fillColor {
                ColorAnimation {
                    duration: Theme.ms(220)
                }

            }

            Behavior on borderColor {
                ColorAnimation {
                    duration: Theme.ms(180)
                }

            }

        }

        QQC.TextArea {
            id: input

            x: composerBg.x + Theme.dp(16)
            y: composerBg.y + Theme.dp(8)
            width: Math.max(0, composerBg.width - Theme.dp(16) - sendButton.width - Theme.dp(12))
            height: Math.max(0, composerBg.height - Theme.dp(16))
            padding: 0
            verticalAlignment: TextEdit.AlignVCenter
            background: null
            color: Theme.text
            selectionColor: Theme.alpha(Theme.accent, 0.32)
            selectedTextColor: Theme.text
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fs(15)
            font.variableAxes: Theme.axes(Theme.fs(15), 420, 0)
            wrapMode: QQC.TextArea.Wrap
            selectByMouse: true
            focus: false
            clip: true

            Keys.priority: Keys.BeforeItem
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Escape) {
                    event.accepted = true;
                    root.hide();
                    return;
                }
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (event.modifiers & Qt.ShiftModifier) {
                        event.accepted = false;
                        return;
                    }
                    event.accepted = true;
                    root.send();
                    return;
                }
                // The language row only takes Tab after it has been activated
                // with Arrow Down or a click. Before that, Tab is not a language
                // switch.
                if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_Down) {
                    event.accepted = true;
                    rail.activate();
                    return;
                }
            }

            onTextChanged: root.draft = input.text
        }

        Text {
            visible: input.text.length === 0
            x: input.x
            y: input.y + (input.height - height) / 2
            width: input.width
            text: root.chat ? "Type a sentence…" : "Type a sentence to translate…"
            color: Theme.subtext
            opacity: 0.8
            elide: Text.ElideRight
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fs(15)
            font.variableAxes: Theme.axes(Theme.fs(15), 420, 0)
        }

        Item {
            id: sendButton

            readonly property real side: Theme.dp(40) + Theme.dp(4) * root.clampM

            x: composerBg.x + composerBg.width - side - Theme.dp(6)
            y: composerBg.y + (composerBg.height - side) / 2
            width: side
            height: side
            opacity: 1
            scale: sendMouse.pressed ? 0.9 : 1

            Behavior on scale {
                NumberAnimation {
                    duration: Theme.ms(220)
                    easing.type: Easing.OutBack
                    easing.overshoot: 0.8
                }

            }

            SquircleRect {
                anchors.fill: parent
                radius: Theme.pill(height)
                smoothing: Theme.squircleF
                fillColor: root.busy ? Theme.accent : (root.canSend ? Theme.accent : Theme.alpha(Theme.subtext, 0.12))

                Behavior on fillColor {
                    ColorAnimation {
                        duration: Theme.ms(220)
                    }

                }

            }

            Icon {
                visible: !root.busy
                anchors.centerIn: parent
                name: "arrow_upward"
                size: Theme.dp(20)
                color: root.canSend ? Theme.onAccent : Theme.subtext
            }

            LoadingMorph {
                visible: root.busy
                anchors.centerIn: parent
                size: Theme.dp(22)
                color: Theme.onAccent
                running: root.busy
            }

            MouseArea {
                id: sendMouse

                anchors.fill: parent
                enabled: root.canSend
                hoverEnabled: true
                cursorShape: root.canSend ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.send()
            }

        }

    }

    // ---- small animations -------------------------------------------------
    property real markMorph: 0
    property real markSpin: 0

    SequentialAnimation {
        id: markPulse

        ParallelAnimation {
            NumberAnimation {
                target: root
                property: "markMorph"
                to: 0.82
                duration: Theme.ms(220)
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.curveEmphasized
            }

            NumberAnimation {
                target: root
                property: "markSpin"
                to: 22
                duration: Theme.ms(220)
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.curveEmphasized
            }

        }

        ParallelAnimation {
            NumberAnimation {
                target: root
                property: "markMorph"
                to: 0
                duration: Theme.ms(560)
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.curveSpatial
            }

            NumberAnimation {
                target: root
                property: "markSpin"
                to: 0
                duration: Theme.ms(560)
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.curveSpatial
            }

        }

    }

    ListModel {
        id: messages
    }

    IpcHandler {
        target: "quick-translate"

        function toggle(): void {
            root.toggle();
        }

        function open(): void {
            root.show();
        }

        function close(): void {
            root.hide();
        }

        function language(code: string): string {
            root.selectLanguage(code);
            return root.targetCode;
        }

        // scripting hook, also handy for a one-shot translation:
        // qs -p <repo> ipc call quick-translate ask "Good morning"
        function ask(text: string): string {
            if (!root.shown)
                root.show();
            input.text = text;
            Qt.callLater(function() {
                root.send();
            });
            return "sent";
        }

        function status(): string {
            return JSON.stringify({
                "open": root.shown,
                "language": root.targetCode,
                "busy": root.busy,
                "turns": messages.count
            });
        }

        function debug(): string {
            return JSON.stringify({
                "open": root.shown,
                "rendered": root.rendered,
                "chat": root.chat,
                "morph": root.morph,
                "entry": root.entry,
                "cardW": root.cardW,
                "cardH": root.cardH,
                "cardX": card.x,
                "cardY": card.y,
                "inputFocus": input.activeFocus,
                "top": root.topMargin,
                "right": root.rightMargin,
                "railX": rail.x,
                "railY": rail.y,
                "railW": rail.width,
                "railContentW": rail.contentWidth,
                "composerX": composerBg.x,
                "composerY": composerBg.y,
                "composerW": composerBg.width,
                "composerH": composerBg.height,
                "turns": messages.count,
                "busy": root.busy,
                "language": root.targetCode,
                "lastReply": messages.count > 0 ? messages.get(messages.count - 1).text : "",
                "lastUsage": root.lastUsage,
                "lastLatencyMs": root.lastLatencyMs,
                "lastKind": messages.count > 0 ? messages.get(messages.count - 1).kind : "",
                "pendingKind": root.pendingKind,
                "lastTranslationLang": root.lastTranslationLang,
                "lastSource": root.lastSource,
                "lastTranslation": root.lastTranslation,
                "metaTurns": root.metaHistory.length,
                "layout": root.delegateLayout(),
                "hasCredential": root.providerKey !== "",
                "translatorRunning": translator.running,
                "translatorStdin": translator.stdinEnabled,
                "busyDirect": root.busyDirect,
                "pendingId": root.pendingId,
                "translatorRestarts": root.translatorRestarts,
                "translatorStderr": root.translatorStderr,
                "stateReady": root.stateReady,
                "languageDirty": root.languageDirty,
                "languageChosen": root.languageChosen,
                "isLight": Theme.isLight,
                "isLightMode": Theme.isLightMode,
                "bgOpaque": Theme.bgOpaque.toString(),
                "accent": Theme.accent.toString(),
                "accentContainer": Theme.accentContainer.toString(),
                "fgAccentContainer": Theme.fgAccentContainer.toString(),
                "text": Theme.text.toString(),
                "subtext": Theme.subtext.toString(),
                "outline": Theme.outline.toString(),
                "squircleF": Theme.squircleF,
                "cornerScale": Theme.cornerScale,
                "fontScale": Theme.fontScale,
                "motionScale": Theme.motionScale,
                "fontFamily": Theme.fontFamily
            });
        }

    }

}

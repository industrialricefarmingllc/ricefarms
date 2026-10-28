import QtQuick
import Quickshell
import Quickshell.Io
import "translate/components"

// The launcher's Translate tab. The launcher search field is the composer:
// submit(text) is called by LauncherFace when Enter is pressed. This pane only
// owns the conversation, the language rail and the provider worker.
Item {
    id: pane

    readonly property var languages: [
        { "code": "fr", "name": "Français", "prompt": "French" },
        { "code": "lb", "name": "Lëtzebuergesch", "prompt": "Luxembourgish" },
        { "code": "ru", "name": "Русский", "prompt": "Russian" },
        { "code": "de", "name": "Deutsch", "prompt": "German" }
    ]

    // Set by the launcher: one Lucid type step below the mode labels, at the
    // launcher's own content scale.
    property real languageLabelSize: 0
    property string targetCode: "fr"
    property string requestLanguage: "fr"
    property var history: []
    property var metaHistory: []
    property string pendingKind: "translate"
    property string pendingMeta: ""
    property string pendingSource: ""
    property string pendingImagePath: ""
    property string lastImagePath: ""
    property string pasteSerial: ""
    readonly property string cacheHome: Quickshell.env("XDG_CACHE_HOME") || (pane.home + "/.cache")
    property string lastSource: ""
    property string lastTranslation: ""
    property string lastTranslationLang: ""
    property int lastTranslationHistoryIndex: -1
    property bool busy: false
    property bool busyDirect: false
    property int pendingId: 0
    property int requestSeq: 0
    property bool languageChosen: false
    property bool languageDirty: false
    property bool stateReady: false
    property string providerKey: ""
    property string opencodeBin: "opencode"
    property var lastUsage: ({})
    property int lastLatencyMs: 0
    property string translatorStderr: ""
    property int translatorRestarts: 0
    property bool resetting: false

    // The provider chain is not free: it makes a directory, runs `command -v
    // opencode`, reads a credential through the opencode CLI and then keeps a
    // python3 worker alive for the rest of the session. None of that is worth
    // anything until the tab has been opened at least once, which in most
    // sessions it never is, so the whole chain waits for the first visit.
    property bool wanted: false
    onVisibleChanged: if (pane.visible) pane.wanted = true

    readonly property string home: Quickshell.env("HOME")
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (pane.home + "/.config")
    readonly property string serverPath: Qt.resolvedUrl("translate/translate_server.py").toString().replace("file://", "")
    readonly property int pad: Theme.dp(16)
    readonly property bool languageEngaged: rail.activeFocus

    signal focusInputRequested()
    signal tabsFocusRequested()
    signal typeIntoInputRequested(string text)

    function activateLanguage() {
        rail.activate();
    }

    function validLanguage(code) {
        for (var i = 0; i < pane.languages.length; i++) {
            if (pane.languages[i].code === code)
                return true;
        }
        return false;
    }

    function languageFor(code) {
        if (code === "en")
            return { "code": "en", "name": "English", "prompt": "English" };

        for (var i = 0; i < pane.languages.length; i++) {
            if (pane.languages[i].code === code)
                return pane.languages[i];
        }
        return pane.languages[0];
    }

    function languageName(code) {
        return pane.languageFor(code).name;
    }

    function codeForLanguageName(name) {
        var n = String(name || "").toLowerCase().trim();
        if (n === "en" || n.indexOf("english") >= 0)
            return "en";

        for (var i = 0; i < pane.languages.length; i++) {
            var lang = pane.languages[i];
            if (n === lang.code || n.indexOf(lang.prompt.toLowerCase()) >= 0 || n.indexOf(lang.name.toLowerCase()) >= 0)
                return lang.code;
        }
        return "";
    }

    function selectLanguage(code) {
        var next = pane.validLanguage(code) ? code : "fr";
        if (pane.targetCode === next)
            return;

        pane.languageChosen = true;
        pane.languageDirty = true;
        pane.targetCode = next;
        st.language = next;
        if (pane.stateReady)
            stateFile.writeAdapter();
    }

    function cycleLanguage(delta) {
        var current = 0;
        for (var i = 0; i < pane.languages.length; i++) {
            if (pane.languages[i].code === pane.targetCode)
                current = i;
        }
        var next = (current + delta + pane.languages.length) % pane.languages.length;
        pane.selectLanguage(pane.languages[next].code);
    }

    function clearPending() {
        pane.busy = false;
        pane.busyDirect = false;
        pane.pendingId = 0;
        pane.pendingKind = "translate";
        pane.pendingMeta = "";
        pane.pendingSource = "";
        pane.pendingImagePath = "";
        timeout.stop();
    }

    function reset() {
        pane.resetting = true;
        pane.clearPending();
        pane.history = [];
        pane.metaHistory = [];
        pane.lastSource = "";
        pane.lastImagePath = "";
        pane.lastTranslation = "";
        pane.lastTranslationLang = "";
        pane.lastTranslationHistoryIndex = -1;
        pane.requestLanguage = pane.targetCode;
        messages.clear();
        if (fallback.running)
            fallback.running = false;
        pane.resetting = false;
    }

    function status() {
        return JSON.stringify({
            "language": pane.targetCode,
            "engaged": pane.languageEngaged,
            "labelSize": pane.languageLabelSize,
            "railHeight": rail.height,
            "messages": messages.count,
            "busy": pane.busy,
            "hasCredential": pane.providerKey !== "",
            "translatorRunning": translator.running,
            "lastUsage": pane.lastUsage,
            "lastLatencyMs": pane.lastLatencyMs,
            "lastTranslationLang": pane.lastTranslationLang,
            "lastTranslation": pane.lastTranslation
        });
    }

    function scrollToEnd() {
        Qt.callLater(function() {
            list.positionViewAtEnd();
        });
    }

    function cleanTranslation(text) {
        var out = String(text || "").trim();
        if (out === "")
            return "";

        out = out.replace(/^```[a-zA-Z0-9_-]*\s*/, "").replace(/\s*```$/, "");
        if ((out.charAt(0) === "\"" && out.charAt(out.length - 1) === "\"") || (out.charAt(0) === "“" && out.charAt(out.length - 1) === "”"))
            out = out.slice(1, -1);
        out = out.replace(/^(translation|traduction|traducción|übersetzung|перевод)\s*:\s*/i, "");
        return out.trim();
    }

    function imageMime(types) {
        var lines = String(types || "").split("\n");
        var preferred = ["image/png", "image/webp", "image/jpeg", "image/jpg", "image/gif"];
        for (var p = 0; p < preferred.length; p++) {
            for (var i = 0; i < lines.length; i++) {
                if (lines[i].trim().toLowerCase() === preferred[p])
                    return preferred[p];
            }
        }
        for (var j = 0; j < lines.length; j++) {
            var type = lines[j].trim().toLowerCase();
            if (type.indexOf("image/") === 0)
                return type;
        }
        return "";
    }

    function pasteImage() {
        if (pane.busy) {
            pane.appendError("Wait for the current translation to finish.");
            return true;
        }
        if (clipboardTypes.running || clipboardSave.running)
            return true;

        pane.pasteSerial = String(Date.now());
        clipboardTypes.running = true;
        return true;
    }

    function clipboardTypesReady(types) {
        var mime = pane.imageMime(types);
        if (mime === "" || pane.pasteSerial === "")
            return;

        var ext = mime === "image/jpeg" || mime === "image/jpg" ? "jpg" : mime.split("/")[1];
        var dir = pane.cacheHome + "/quick-translate";
        var path = dir + "/paste-" + pane.pasteSerial + "." + ext;
        clipboardSave.pastePath = path;
        clipboardSave.command = ["sh", "-c", "mkdir -p \"$1\" && wl-paste --type \"$2\" > \"$3\"", "sh", dir, mime, path];
        clipboardSave.running = true;
    }

    function clipboardSaved(code, path) {
        if (code !== 0 || path === "")
            return;

        var preview = "file://" + path;
        pane.submitImage(path, preview);
    }

    function buildImagePrompt() {
        var lang = pane.languageFor(pane.targetCode);
        var out = "Read all text visible in the image and translate it. ";
        out += "If the text is already in " + lang.prompt + ", translate it into English instead; otherwise translate it into " + lang.prompt + ". ";
        out += "Preserve line breaks, lists, and layout as closely as possible. Do not describe the image; return only the translation. ";
        out += "If there is no readable text, reply exactly:\nTARGET: NONE\nTRANSLATION: [no text found]\n\n";
        out += "Reply exactly as:\nTARGET: <English name of the language you translated into>\nTRANSLATION: <only the translation>";
        return out;
    }

    function submitImage(path, previewUrl) {
        if (pane.busy)
            return;

        messages.append({
            "kind": "user",
            "text": "Image",
            "imageUrl": previewUrl,
            "lang": "",
            "label": ""
        });
        pane.history = pane.history.concat([{ "role": "user", "text": "[image]" }]);
        pane.requestLanguage = pane.targetCode;
        pane.pendingKind = "translate";
        pane.pendingSource = "";
        pane.pendingImagePath = path;
        pane.busy = true;
        pane.sendPrompt(pane.buildImagePrompt(), path);
        pane.scrollToEnd();
    }

    function appendError(detail) {
        var line = String(detail || "").trim().split("\n")[0];
        if (line.length > 160)
            line = line.slice(0, 157) + "…";

        messages.append({
            "kind": "error",
            "text": line !== "" ? line : "The translation service did not answer.",
            "imageUrl": "",
            "lang": "",
            "label": ""
        });
        pane.scrollToEnd();
    }

    function parseTranslation(rawText) {
        var full = String(rawText || "").trim();
        var targetMatch = /(?:^|\n)\s*(?:\*\*)?TARGET(?:\*\*)?\s*:\s*(?:\*\*)?\s*([^\n]+)/i.exec(full);
        var transMatch = /(?:^|\n)\s*(?:\*\*)?TRANSLATION(?:\*\*)?\s*:\s*([\s\S]*)$/i.exec(full);
        var body = transMatch ? transMatch[1].trim() : full;
        body = body.replace(/^\*\*\s*/, "").replace(/\s*\*\*$/, "").trim();
        var code = targetMatch ? pane.codeForLanguageName(targetMatch[1]) : "";
        return {
            "text": pane.cleanTranslation(body),
            "lang": code !== "" ? code : pane.requestLanguage
        };
    }

    function buildPrompt(languageCode) {
        var lang = pane.languageFor(languageCode);
        var out = "Translate the final user message. If it is already in " + lang.prompt + ", translate it into English instead; otherwise translate it into " + lang.prompt + ".\n\n";
        var start = Math.max(0, pane.history.length - 12);
        for (var i = start; i < pane.history.length; i++) {
            var turn = pane.history[i];
            out += turn.role === "user" ? "User: " : "Assistant: ";
            out += turn.text + "\n";
        }
        out += "Reply exactly as:\nTARGET: <English name of the language you translated into>\nTRANSLATION: <only the translation>";
        return out;
    }

    function buildMetaPrompt(meta) {
        var hasPrevious = pane.lastTranslation !== "";
        var langCode = hasPrevious && pane.lastTranslationLang !== "" ? pane.lastTranslationLang : pane.targetCode;
        var lang = pane.languageFor(langCode);
        var out = "You are a translation assistant. The user's new message starts with '>' and is a meta-message.\n\n";
        if (hasPrevious) {
            if (pane.lastImagePath !== "")
                out += "Previous input was an image; the translation below is its translated text.\n";
            else
                out += "Previous source sentence: " + pane.lastSource + "\n";
            out += "Previous translation into " + lang.prompt + ": " + pane.lastTranslation + "\n\n";
        } else {
            out += "There is no previous translation yet.\n\n";
        }

        if (pane.metaHistory.length > 0) {
            out += "Recent meta exchange:\n";
            var start = Math.max(0, pane.metaHistory.length - 6);
            for (var i = start; i < pane.metaHistory.length; i++) {
                var turn = pane.metaHistory[i];
                out += turn.role === "user" ? "User: " : "Assistant: ";
                out += turn.text + "\n";
            }
            out += "\n";
        }

        out += "Meta-message: " + meta + "\n\n";
        out += "If this is a question about the translation, the language, or anything else, answer it in English. ";
        out += "Keep an ANSWER as short and direct as possible: use only the words needed, with no preamble and no restating of the question. ";
        if (hasPrevious) {
            var source = pane.lastImagePath !== "" ? "the text visible in the previous image" : "the previous source sentence";
            out += "If it is an instruction to change the translation, re-translate " + source + " into " + lang.prompt + " applying the instruction, and output only the revised translation. Do not answer in English in that case. ";
        } else
            out += "There is nothing to refine yet; answer in English. ";
        out += "Reply exactly in one of these forms, starting with the label:\n";
        out += "ANSWER: <short, direct English answer>\n";
        if (hasPrevious)
            out += "TRANSLATION: <only the revised translation in " + lang.prompt + ">";
        return out;
    }

    function submit(text) {
        var sentence = String(text || "").trim();
        if (sentence === "" || pane.busy)
            return;

        if (sentence.charAt(0) === ">") {
            pane.submitMeta(sentence.slice(1).trim());
            return;
        }

        messages.append({
            "kind": "user",
            "text": sentence,
            "imageUrl": "",
            "lang": "",
            "label": ""
        });
        pane.history = pane.history.concat([{ "role": "user", "text": sentence }]);
        pane.requestLanguage = pane.targetCode;
        pane.pendingKind = "translate";
        pane.pendingSource = sentence;
        pane.pendingImagePath = "";
        pane.lastImagePath = "";
        pane.busy = true;
        pane.sendPrompt(pane.buildPrompt(pane.requestLanguage), "");
        pane.scrollToEnd();
    }

    function submitMeta(meta) {
        if (meta === "") {
            pane.appendError("Type a question or refinement after >.");
            return;
        }

        messages.append({
            "kind": "instruction",
            "text": "> " + meta,
            "imageUrl": "",
            "lang": "",
            "label": ""
        });
        pane.pendingKind = "meta";
        pane.pendingMeta = meta;
        pane.pendingImagePath = pane.lastImagePath;
        pane.busy = true;
        pane.sendPrompt(pane.buildMetaPrompt(meta), pane.lastImagePath);
        pane.scrollToEnd();
    }

    function sendPrompt(prompt, imagePath) {
        if (pane.providerKey !== "" && translator.running && translator.stdinEnabled) {
            pane.busyDirect = true;
            pane.pendingId = ++pane.requestSeq;
            translator.write(JSON.stringify({
                "id": pane.pendingId,
                "prompt": prompt,
                "model": "gpt-6-luna",
                "effort": "none",
                "image_path": imagePath || ""
            }) + "\n");
        } else if (imagePath) {
            pane.busyDirect = false;
            pane.pendingId = 0;
            pane.clearPending();
            pane.appendError("The persistent translator is not running; image input needs it.");
        } else {
            pane.busyDirect = false;
            pane.pendingId = 0;
            fallback.command = [pane.opencodeBin, "api", "post", "/api/experimental/generate", "--data", JSON.stringify({
                "model": {
                    "id": "gpt-6-luna",
                    "providerID": "opencode-go",
                    "variant": "none"
                },
                "prompt": prompt
            })];
            fallback.running = true;
        }
        timeout.restart();
    }

    function finishFallback(code, outText, errText) {
        if (!pane.busy)
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
            pane.clearPending();
            pane.appendError(detail);
            return;
        }

        if (pane.pendingKind === "meta")
            pane.handleMetaResponse(raw, usage, 0);
        else
            pane.handleTranslationResponse(raw, usage, 0);
    }

    function handleTranslationResponse(rawText, usage, latency) {
        if (!pane.busy)
            return;

        var parsed = pane.parseTranslation(rawText);
        var translated = parsed.text;
        var source = pane.pendingSource;
        var imagePath = pane.pendingImagePath;
        var language = parsed.lang;
        pane.clearPending();

        if (translated === "") {
            pane.appendError("The translation service returned no text.");
            return;
        }

        messages.append({
            "kind": "assistant",
            "text": translated,
            "imageUrl": "",
            "lang": language,
            "label": ""
        });
        pane.history = pane.history.concat([{ "role": "assistant", "text": translated }]);
        pane.lastTranslationHistoryIndex = pane.history.length - 1;
        pane.lastSource = source;
        pane.lastImagePath = imagePath;
        pane.lastTranslation = translated;
        pane.lastTranslationLang = language;
        pane.metaHistory = [];
        if (usage)
            pane.lastUsage = usage;
        pane.lastLatencyMs = Number(latency) || 0;
        pane.scrollToEnd();
    }

    function handleMetaResponse(rawText, usage, latency) {
        if (!pane.busy)
            return;

        var meta = pane.pendingMeta;
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
            kind = (refine || (!question && pane.lastTranslation !== "")) ? "translation" : "answer";
            body = full;
        }

        body = body.replace(/^\*\*\s*/, "").replace(/\s*\*\*$/, "").trim();
        pane.clearPending();
        if (body === "") {
            pane.appendError("The model returned an empty reply.");
            return;
        }

        if (kind === "translation" && pane.lastTranslation !== "") {
            var refined = pane.cleanTranslation(body);
            if (refined === "") {
                pane.appendError("The model returned no refined translation.");
                return;
            }
            messages.append({
                "kind": "refined",
                "text": refined,
                "imageUrl": "",
                "lang": pane.lastTranslationLang,
                "label": "Refined · " + pane.languageName(pane.lastTranslationLang)
            });
            var idx = pane.lastTranslationHistoryIndex;
            if (idx >= 0 && idx < pane.history.length) {
                var next = pane.history.slice();
                next[idx] = { "role": "assistant", "text": refined };
                pane.history = next;
            }
            pane.lastTranslation = refined;
        } else {
            var answer = body.replace(/^```[a-zA-Z0-9_-]*\s*/, "").replace(/\s*```$/, "").trim();
            messages.append({
                "kind": "answer",
                "text": answer,
                "imageUrl": "",
                "lang": "",
                "label": "English"
            });
            pane.metaHistory = pane.metaHistory.concat([
                { "role": "user", "text": "> " + meta },
                { "role": "assistant", "text": answer }
            ]).slice(-8);
        }

        if (usage)
            pane.lastUsage = usage;
        pane.lastLatencyMs = Number(latency) || 0;
        pane.scrollToEnd();
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
                pane.translatorRestarts = 0;
            else if (data.error)
                pane.translatorStderr = String(data.error);
            return;
        }

        if (!pane.busyDirect)
            return;
        if (data.id !== undefined && Number(data.id) !== pane.pendingId)
            return;

        if (data.error) {
            pane.clearPending();
            pane.appendError(String(data.error));
            return;
        }

        if (pane.pendingKind === "meta")
            pane.handleMetaResponse(data.text, data.usage, data.latency_ms);
        else
            pane.handleTranslationResponse(data.text, data.usage, data.latency_ms);
    }

    // ---- language state ---------------------------------------------------
    Binding {
        target: pane
        property: "targetCode"
        value: pane.validLanguage(st.language) ? st.language : "fr"
        when: !pane.languageChosen
        restoreMode: Binding.RestoreNone
    }

    FileView {
        id: stateFile

        path: pane.configHome + "/quick-translate/state.json"
        blockLoading: true
        onLoaded: {
            if (!pane.languageChosen && pane.validLanguage(st.language))
                pane.targetCode = st.language;
            pane.languageDirty = false;
        }
        onAdapterUpdated: {
            if (pane.stateReady && pane.languageDirty)
                stateFile.writeAdapter();
        }

        adapter: JsonAdapter {
            id: st

            property string language: "fr"
        }

    }

    Process {
        id: mkdirState

        command: ["mkdir", "-p", pane.configHome + "/quick-translate"]
        running: pane.wanted
        onExited: pane.stateReady = true
    }

    Timer {
        interval: 700
        running: pane.wanted
        onTriggered: pane.stateReady = true
    }

    // ---- provider worker --------------------------------------------------
    Process {
        id: whichOpencode

        command: ["sh", "-c", "command -v opencode 2>/dev/null || printf '%s' \"$HOME/.bun/bin/opencode\""]
        running: pane.wanted

        stdout: StdioCollector {
            onStreamFinished: {
                var found = String(this.text || "").trim();
                if (found !== "")
                    pane.opencodeBin = found;
                credentialProc.running = true;
            }
        }

    }

    Process {
        id: credentialProc

        command: [pane.opencodeBin, "api", "get", "/api/credential"]
        workingDirectory: pane.home

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var data = JSON.parse(String(this.text || "").trim());
                    for (var i = 0; i < (data.data || []).length; i++) {
                        var item = data.data[i];
                        if (item.integrationID === "opencode-go" && item.value && item.value.type === "key" && item.value.key) {
                            pane.providerKey = item.value.key;
                            break;
                        }
                    }
                } catch (e) {
                }

                if (pane.providerKey !== "" && !translator.running) {
                    translator.environment = ({ "QUICK_TRANSLATE_KEY": pane.providerKey });
                    translator.running = true;
                }
            }
        }

        stderr: StdioCollector {
        }

    }

    Process {
        id: translator

        running: false
        stdinEnabled: false
        command: ["python3", pane.serverPath]
        workingDirectory: pane.home
        environment: ({ "QUICK_TRANSLATE_KEY": pane.providerKey })

        onStarted: translator.stdinEnabled = true

        onExited: (code) => {
            translator.stdinEnabled = false;
            if (pane.busyDirect) {
                pane.clearPending();
                pane.appendError("The translation helper stopped (code " + code + ").");
            }
            if (pane.providerKey !== "" && pane.translatorRestarts < 5) {
                pane.translatorRestarts++;
                translatorRestart.restart();
            }
        }

        stdout: SplitParser {
            onRead: (line) => pane.translatorLine(line)
        }

        stderr: SplitParser {
            onRead: (line) => {
                pane.translatorStderr = line;
            }
        }

    }

    Timer {
        id: translatorRestart

        interval: 1500
        onTriggered: {
            if (pane.providerKey !== "" && !translator.running) {
                translator.environment = ({ "QUICK_TRANSLATE_KEY": pane.providerKey });
                translator.running = true;
            }
        }
    }

    Timer {
        id: keepalive

        interval: 120000
        repeat: true
        running: translator.running
        onTriggered: {
            if (translator.running && translator.stdinEnabled)
                translator.write(JSON.stringify({ "warm": true }) + "\n");
        }
    }

    Process {
        id: fallback

        stdout: StdioCollector {
            id: fallbackOut
        }

        stderr: StdioCollector {
            id: fallbackErr
        }

        onExited: (code) => pane.finishFallback(code, fallbackOut.text, fallbackErr.text)
    }

    Timer {
        id: timeout

        interval: 60000
        repeat: false
        onTriggered: {
            if (pane.busyDirect) {
                pane.clearPending();
                translator.running = false;
                pane.appendError("The translation timed out.");
                return;
            }

            if (!fallback.running)
                return;

            fallback.running = false;
            pane.clearPending();
            pane.appendError("The translation timed out. Is the OpenCode service running?");
        }
    }

    Process {
        id: clipboardTypes

        command: ["wl-paste", "--list-types"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: pane.clipboardTypesReady(this.text)
        }

    }

    Process {
        id: clipboardSave

        property string pastePath: ""
        running: false

        onExited: (code) => pane.clipboardSaved(code, clipboardSave.pastePath)
    }

    // ---- UI ---------------------------------------------------------------
    LanguageRail {
        id: rail

        x: pane.pad
        y: Theme.dp(8)
        width: pane.width - pane.pad * 2
        // Match the launcher's mode-pill height (34 * launcherScale) instead
        // of the standalone rail's taller 34 dp, so the smaller labels do not
        // float in extra vertical padding.
        height: Math.round(34 * face.cs)
        languages: pane.languages
        current: pane.targetCode
        labelSize: pane.languageLabelSize > 0 ? pane.languageLabelSize : Theme.fs(13)
        onSelected: (code) => pane.selectLanguage(code)
        onPasteImageRequested: pane.pasteImage()
        onTextTyped: (text) => pane.typeIntoInputRequested(text)
        onLeaveRequested: (backward) => backward ? pane.tabsFocusRequested() : pane.focusInputRequested()
    }

    Rectangle {
        x: pane.pad
        y: rail.y + rail.height + Theme.dp(8)
        width: pane.width - pane.pad * 2
        height: 1
        color: Theme.divider
    }

    ListView {
        id: list

        x: pane.pad
        y: rail.y + rail.height + Theme.dp(12)
        width: pane.width - pane.pad * 2
        height: Math.max(0, pane.height - y - Theme.dp(8))
        clip: true
        spacing: Theme.dp(8)
        model: messages
        boundsBehavior: Flickable.StopAtBounds
        onCountChanged: pane.scrollToEnd()
        onContentHeightChanged: pane.scrollToEnd()

        delegate: Item {
            id: turn

            width: ListView.view.width
            height: (preview.visible ? preview.height + Theme.dp(4) : 0) + bubble.height

            Image {
                id: preview

                readonly property real maxWidth: 240
                readonly property real ratio: implicitWidth > 0 ? implicitHeight / implicitWidth : 0.75

                visible: (model.imageUrl || "") !== ""
                x: turn.width - width
                width: implicitWidth > 0 ? Math.min(maxWidth, implicitWidth) : maxWidth
                height: width * (ratio > 0 ? ratio : 0.75)
                source: model.imageUrl || ""
                sourceSize.width: 240
                sourceSize.height: 240
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
            }

            MessageBubble {
                id: bubble

                y: preview.visible ? preview.height + Theme.dp(4) : 0
                width: turn.width
                kind: model.kind
                text: model.text
                order: index
                languageName: model.label || pane.languageName(model.lang)
            }

        }

        footer: Item {
            width: list.width
            height: pane.busy ? Theme.dp(52) : 0
            visible: pane.busy

            Rectangle {
                x: 0
                y: 0
                width: Theme.dp(132)
                height: Theme.dp(44)
                radius: Theme.dp(22)
                color: Theme.assistantBubble

                LoadingMorph {
                    x: Theme.dp(12)
                    anchors.verticalCenter: parent.verticalCenter
                    size: Theme.dp(22)
                    color: Theme.accent
                    running: pane.busy
                }

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.dp(42)
                    anchors.verticalCenter: parent.verticalCenter
                    text: pane.pendingKind === "meta" ? "Thinking" : "Translating"
                    color: Theme.subtext
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fs(12)
                    font.variableAxes: Theme.axes(Theme.fs(12), 500, 0)
                }

            }

        }

    }

    Text {
        visible: messages.count === 0 && !pane.busy
        anchors.centerIn: list
        width: Math.max(0, list.width - Theme.dp(40))
        text: "Type a sentence and press Enter.\nUse > for a question or refinement."
        color: Theme.subtext
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fs(14 * 0.8)
        font.variableAxes: Theme.axes(Theme.fs(14 * 0.8), 420, 0)
        opacity: 0.8
    }

    ListModel {
        id: messages
    }

}

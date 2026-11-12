pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lucidui/translations.js" as Catalog

// Translations for the shell's own interface.
//
// The source strings stay in English in the QML files, wrapped as
// `Tr.t("Save")`. When the session language is French, `t()` returns the
// entry from lucidui/translations.js; otherwise it returns the source string
// untouched, so switching language never needs a reverse dictionary.
//
// The language is chosen from, in order: LUCID_LANG, ~/.config/lucid/language
// (written by Settings > General), and the session's LC_ALL/LC_MESSAGES/LANG.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") || ""

    // System/session language. Only French and English ship today; anything
    // else falls back to the English source strings.
    readonly property string systemLanguage: {
        const raw = (Quickshell.env("LUCID_LANG")
            || Quickshell.env("LC_ALL")
            || Quickshell.env("LC_MESSAGES")
            || Quickshell.env("LANG")
            || "en").toLowerCase();
        return raw.indexOf("fr") === 0 ? "fr" : "en";
    }

    // Empty means "follow the system". Persisted in ~/.config/lucid/language.
    property string overrideLanguage: ""

    readonly property string language: root.overrideLanguage !== "" ? root.overrideLanguage : root.systemLanguage
    readonly property bool isFrench: root.language === "fr"
    // convenient for settings pages: "Français" / "English"
    readonly property string languageName: root.isFrench ? "Français" : "English"

    function normalize(code) {
        const c = String(code || "").toLowerCase();
        if (c.indexOf("fr") === 0)
            return "fr";

        if (c.indexOf("en") === 0)
            return "en";

        return "";
    }

    // Translate one source string.
    function t(text) {
        if (!root.isFrench || text === undefined || text === null)
            return text;

        const value = Catalog.fr[text];
        return value === undefined ? text : value;
    }

    // Translate and substitute %1 … %9.
    function fmt(text) {
        let out = root.t(text);
        for (let i = 1; i < arguments.length; i++)
            out = out.replace("%" + i, String(arguments[i]));

        return out;
    }

    // Pick the singular or plural source string, then translate it.
    function n(singular, plural, count) {
        return root.t(Number(count) === 1 ? singular : plural);
    }

    // Write the choice and switch live. "" follows the system again.
    function setLanguage(code) {
        const next = root.normalize(code);
        root.overrideLanguage = next;
        root.writeLanguage(next);
    }

    function writeLanguage(code) {
        if (root.home === "")
            return ;

        const value = code === "fr" || code === "en" ? code : "";
        langWriter.command = ["sh", "-c", "mkdir -p \"$HOME/.config/lucid\" && printf '%s\\n' '" + value + "' > \"$HOME/.config/lucid/language\""];
        langWriter.running = true;
    }

    Component.onCompleted: langFile.reload()

    FileView {
        id: langFile

        path: root.home + "/.config/lucid/language"
        watchChanges: true
        blockLoading: true
        onLoaded: root.overrideLanguage = root.normalize(langFile.text())
        onFileChanged: reload()
        onLoadFailed: root.overrideLanguage = ""
    }

    Process {
        id: langWriter

        onExited: langFile.reload()
    }

}

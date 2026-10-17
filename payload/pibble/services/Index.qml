pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Pibble's own search index (PDFs, Zen domains) behind the apps grid. The
// index scripts (services/pibble-pdf-index.sh,
// services/pibble-zen-domains-index.sh) maintain small `id<TAB>value` text
// files under ~/.cache; this service parses them - milliseconds at daemon
// start, versus Quickshell re-parsing a thousand generated .desktop files
// (measured 2s -> 15-24s cold start with 1117 of those, see Apps.all).
//
// Each entry is a plain { id, name, icon, indexPdfPath/indexUrl } object, the
// same shape the grid already reads off a DesktopEntry or a Steam game (see
// services/Steam.qml), so sorting, prefix filtering, gating and launch-count
// ranking all work unchanged. Launching is what branches (see
// LauncherWindow.launch): PDFs open via xdg-open, domains via Zen.
Singleton {
    id: root

    readonly property string cacheDir: {
        const xdg = Quickshell.env("XDG_CACHE_HOME");
        return xdg ? xdg : Quickshell.env("HOME") + "/.cache";
    }

    // All index entries, alphabetically sorted. Empty until the FileViews
    // below load (same async pattern as Steam.games).
    property var entries: []

    function parse(text: string, kind: string): var {
        const out = [];
        for (const line of text.split("\n")) {
            if (!line.trim())
                continue;
            const tab = line.indexOf("\t");
            if (tab < 0)
                continue;
            const id = line.slice(0, tab);
            const value = line.slice(tab + 1);
            if (!value)
                continue;
            if (kind === "pdf") {
                if (!id.startsWith("pibble-pdf-"))
                    continue;
                let base = value.split("/").pop();
                base = base.replace(/\.[pP][dD][fF]$/, "");
                out.push({
                    id: id,
                    name: base + " (PDF)",
                    icon: "application-pdf",
                    indexPdfPath: value
                });
            } else {
                if (!id.startsWith("pibble-web-"))
                    continue;
                const host = value.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, "");
                if (!host)
                    continue;
                out.push({
                    id: id,
                    name: host + " (Web)",
                    icon: "zen-browser",
                    indexUrl: value
                });
            }
        }
        return out;
    }

    function rebuild(): void {
        const out = [];
        if (pdfFile.loaded)
            for (const e of root.parse(pdfFile.text(), "pdf"))
                out.push(e);
        if (webFile.loaded)
            for (const e of root.parse(webFile.text(), "web"))
                out.push(e);
        out.sort((a, b) => a.name.localeCompare(b.name));
        root.entries = out;
    }

    FileView {
        id: pdfFile
        path: root.cacheDir + "/pibble-pdf-index.txt"
        watchChanges: true
        onLoaded: root.rebuild()
        onFileChanged: reload()
    }
    FileView {
        id: webFile
        path: root.cacheDir + "/pibble-zen-domains.txt"
        watchChanges: true
        onLoaded: root.rebuild()
        onFileChanged: reload()
    }
}

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs
import qs.lucidui

// Copy and download controls shared by media cards and the lightbox. Only the
// URL handling lives here; callers decide where the cluster sits.
RowLayout {
    id: actions

    // `url` is the fallback for both actions. Callers can separate the link
    // users should copy from the direct media file they should download.
    property string url: ""
    property string copyUrl: ""
    property string downloadUrl: ""
    property string filename: ""
    // The media type, so Copy can put bytes or a file on the clipboard
    // instead of only the URL. Link/embed cards fall back to their poster.
    property string mediaKind: "link"
    property string posterUrl: ""
    property string buttonVariant: "tonal"
    property string buttonSize: "xs"
    property bool compact: true

    readonly property string copyTarget: String(actions.copyUrl || actions.url || "")
    readonly property string downloadTarget: String(actions.downloadUrl || actions.url || "")
    readonly property bool available: actions.copyTarget !== "" || actions.downloadTarget !== ""
    property bool copied: false
    property bool copying: false
    property bool downloading: false
    property string downloadStatus: ""

    spacing: Theme.dp(actions.compact ? 4 : 6)
    visible: actions.available

    function localPath(value) {
        var text = String(value || "");
        if (text.indexOf("file://") !== 0)
            return "";
        try {
            return decodeURIComponent(text.slice(7));
        } catch (error) {
            return text.slice(7);
        }
    }

    function copy() {
        if (!actions.available || actions.copying)
            return ;
        var source = actions.downloadTarget;
        var kind = String(actions.mediaKind || "");
        if ((kind === "link" || kind === "embed") && String(actions.posterUrl || "") !== "") {
            source = String(actions.posterUrl);
            kind = "image";
        }
        if (source === "" || kind === "link" || kind === "embed") {
            var text = actions.localPath(actions.copyTarget);
            Quickshell.execDetached(["wl-copy", "--", text !== "" ? text : actions.copyTarget]);
            actions.copied = true;
            copiedTimer.restart();
            return ;
        }

        var local = actions.localPath(source);
        if (local !== "")
            source = "file://" + local;

        var script = 'set -e; dir="${XDG_CACHE_HOME:-$HOME/.cache}/lucid-social/clipboard"; mkdir -p "$dir"; src="$1"; kind="$2"; '
            + 'case "$src" in file://*) path="${src#file://}";; *) name=$(basename "${src%%\?*}"); [ -n "$name" ] || name=media; '
            + 'hash=$(printf %s "$src" | md5sum | cut -c1-12); ext="${name##*.}"; [ "$ext" = "$name" ] && ext=""; '
            + 'path="$dir/$hash${ext:+.$ext}"; if [ ! -s "$path" ]; then curl -4 -L --fail --silent --show-error --max-time 180 -o "$path" "$src"; fi;; esac; '
            + 'if [ "$kind" = "image" ]; then ffmpeg -hide_banner -loglevel error -nostdin -y -i "$path" -f image2pipe -vcodec png - | wl-copy --type image/png; '
            + 'else printf "file://%s\r\n" "$path" | wl-copy --type text/uri-list; fi';
        actions.copying = true;
        copyProc.command = ["sh", "-c", script, "sh", source, kind];
        copyProc.running = true;
    }

    function downloadName() {
        if (String(actions.filename || "").trim() !== "")
            return String(actions.filename).trim();
        var path = String(actions.downloadTarget || "").split("?")[0].split("#")[0];
        var name = path.slice(path.lastIndexOf("/") + 1);
        return name !== "" ? name : "download";
    }

    function download() {
        if (actions.downloadTarget === "" || actions.downloading)
            return ;
        var local = actions.localPath(actions.downloadTarget);
        var script = local !== ""
            ? 'dir=$(xdg-user-dir DOWNLOAD 2>/dev/null || echo "$HOME/Downloads"); mkdir -p "$dir"; src="$1"; name="$2"; [ -n "$name" ] || name=$(basename "$src"); [ -n "$name" ] || name=download; name=$(printf %s "$name" | tr / _); target="$dir/$name"; base="${name%.*}"; ext="${name##*.}"; [ "$base" = "$name" ] && ext=""; n=1; while [ -e "$target" ]; do target="$dir/$base-$n${ext:+.$ext}"; n=$((n+1)); done; cp -- "$src" "$target"'
            : 'dir=$(xdg-user-dir DOWNLOAD 2>/dev/null || echo "$HOME/Downloads"); mkdir -p "$dir"; name="$1"; [ -n "$name" ] || name=download; name=$(printf %s "$name" | tr / _); target="$dir/$name"; base="${name%.*}"; ext="${name##*.}"; [ "$base" = "$name" ] && ext=""; n=1; while [ -e "$target" ]; do target="$dir/$base-$n${ext:+.$ext}"; n=$((n+1)); done; curl -L --fail --silent --show-error -o "$target" "$2"';
        actions.downloading = true;
        actions.downloadStatus = Tr.t("Downloading…");
        downloadProc.command = ["sh", "-c", script, "sh", local !== "" ? local : actions.downloadName(), actions.downloadTarget];
        downloadProc.running = true;
    }

    Timer {
        id: copiedTimer

        interval: 1400
        onTriggered: actions.copied = false
    }

    Process {
        id: copyProc

        running: false
        command: []

        onExited: (code) => {
            actions.copying = false;
            if (code === 0) {
                actions.copied = true;
                copiedTimer.restart();
            } else {
                actions.downloadStatus = Tr.t("Copy failed");
                clearStatus.restart();
            }
        }
    }

    Process {
        id: downloadProc

        running: false
        command: []

        onExited: (code) => {
            actions.downloading = false;
            actions.downloadStatus = code === 0 ? Tr.t("Saved to Downloads") : Tr.t("Download failed");
            clearStatus.restart();
        }
    }

    Timer {
        id: clearStatus

        interval: 2200
        onTriggered: actions.downloadStatus = ""
    }

    IconButton {
        icon: actions.copied ? "check" : "content_copy"
        variant: actions.buttonVariant
        size: actions.buttonSize
        // Material draws these on a 24px grid. At the 20px a size-s button
        // defaults to, the copy glyph's two pages merge into one solid block
        // and the whole thing reads as low resolution. Keep the container and
        // draw the glyph at its design size in the outlined weight, which is
        // where the page edges and the download tray stay legible.
        iconPx: Theme.dp(24)
        disabled: actions.copying
        tooltip: actions.copying ? Tr.t("Copying…") : (actions.copied ? Tr.t("Copied") : Tr.t("Copy media"))
        onClicked: actions.copy()
    }

    IconButton {
        icon: "download"
        variant: actions.buttonVariant
        size: actions.buttonSize
        iconPx: Theme.dp(24)
        disabled: actions.downloading
        tooltip: actions.downloadStatus !== "" ? actions.downloadStatus : Tr.t("Download")
        onClicked: actions.download()
    }
}

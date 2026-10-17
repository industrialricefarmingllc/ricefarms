pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Installed Steam games behind the apps grid. Steam never writes one
// .desktop entry per game (only Steam itself has one), so nothing installed
// via Steam would ever surface through DesktopEntries.applications -
// Apps.all merges this scan's games in alongside those instead.
//
// Each game is a plain { id, name, icon, steamAppId, isSteam } object, the
// same shape the grid already reads off a DesktopEntry (name/icon/id), so
// sorting, fuzzy filtering, launch-count ranking and icon warm-up all work
// unchanged. Launching is the one place they differ: there is no desktop id
// for gtk-launch, so LauncherWindow launches them via the Steam client
// directly (steam -silent -applaunch <appid>, which keeps its window shut).
Singleton {
    id: root

    // `steam_app_<appid>` ids, so launch counts never collide with a
    // .desktop id and stay stable across rescans. icon is an absolute
    // librarycache path (portrait cover preferred, header/hero/logo
    // fallbacks) or empty, which the tile renders as initials - same as
    // an icon-less desktop entry. Steam tiles center-crop it to square
    // (see the apps grid), so wide/tall stills both fill the tile.
    property var games: []
    // raw stdout of the scan `games` was last built from; see where it's compared
    property string lastScanText: ""
    // Never restarts a scan in flight, and floored to one start per 15s
    // once results exist (rescan fires on every launcher open) - the
    // library barely changes between opens, and a scan is a handful of
    // small-file reads either way.
    property double _lastScanStart: 0
    function rescan(): void {
        if (scan.running)
            return;
        const now = Date.now();
        if (root.games.length > 0 && now - root._lastScanStart < 15000)
            return;
        root._lastScanStart = now;
        scan.running = false;
        Qt.callLater(() => scan.running = true);
    }
    Process {
        id: scan
        running: true
        command: ["bash", "-c", `
            roots=()
            for cand in "$HOME/.local/share/Steam" "$HOME/.steam/steam"; do
                [ -d "$cand" ] || continue
                real=$(realpath "$cand" 2>/dev/null || printf '%s' "$cand")
                dup=0
                for e in "\${roots[@]}"; do [ "$e" = "$real" ] && dup=1 && break; done
                [ "$dup" = "1" ] || roots+=("$real")
            done
            [ "\${#roots[@]}" -eq 0 ] && exit 0
            # extra libraries from libraryfolders.vdf plus each root itself;
            # arrays (not word splitting) so paths with spaces survive
            libs=()
            for r in "\${roots[@]}"; do
                dup=0
                for e in "\${libs[@]}"; do [ "$e" = "$r" ] && dup=1 && break; done
                [ "$dup" = "1" ] || libs+=("$r")
                vf="$r/steamapps/libraryfolders.vdf"
                [ -f "$vf" ] || continue
                while IFS= read -r line; do
                    case "$line" in *"path"*) ;; *) continue;; esac
                    p=$(printf '%s' "$line" | sed -n 's/.*"path"[[:space:]]*"\\([^"]*\\)".*/\\1/p')
                    [ -n "$p" ] || continue
                    [ -d "$p" ] || continue
                    realp=$(realpath "$p" 2>/dev/null || printf '%s' "$p")
                    dup=0
                    for e in "\${libs[@]}"; do [ "$e" = "$realp" ] && dup=1 && break; done
                    [ "$dup" = "1" ] || libs+=("$realp")
                done < "$vf"
            done
            seen=""
            for lib in "\${libs[@]}"; do
                for acf in "$lib"/steamapps/appmanifest_*.acf; do
                    [ -f "$acf" ] || continue
                    base=$(basename "$acf")
                    appid=$(printf '%s' "$base" | sed -n 's/appmanifest_\\([0-9]*\\)\\.acf/\\1/p')
                    [ -n "$appid" ] || continue
                    case " $seen " in *" $appid "*) continue;; esac
                    seen="$seen $appid"
                    name=$(sed -n 's/^[[:space:]]*"name"[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$acf" | head -n 1)
                    installdir=$(sed -n 's/^[[:space:]]*"installdir"[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$acf" | head -n 1)
                    [ -n "$name" ] || continue
                    # no empty/tabbed columns: the QML side splits on TAB
                    name=$(printf '%s' "$name" | tr '\\t\\n\\r' '   ')
                    installdir=$(printf '%s' "$installdir" | tr '\\t\\n\\r' '   ')
                    # runtimes / compat tools are installed apps too, but
                    # nobody launches them: Proton and the Steam Linux
                    # Runtimes by install dir, the redistributables by name,
                    # and the known tool appids as a backstop
                    case "$installdir" in Proton*|SteamLinuxRuntime*|Steamworks*) continue;; esac
                    lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
                    case "$lower" in proton*|"steam linux runtime"*|"steamworks common"*) continue;; esac
                    case "$appid" in 228980|1493710|1628350|2180100|4183110|1070560|1391110|1580130) continue;; esac
                    # per-game art Steam already keeps locally: the
                    # portrait cover first, then the header/hero stills and
                    # the transparent logo last. Empty when none is cached,
                    # which the tile renders as initials.
                    icon=""
                    for rt in "\${roots[@]}"; do
                        for ic in "$rt/appcache/librarycache/$appid/library_600x900.jpg" "$rt/appcache/librarycache/$appid/header.jpg" "$rt/appcache/librarycache/$appid/library_hero.jpg" "$rt/appcache/librarycache/$appid/logo.png" "$rt/appcache/librarycache/\${appid}_icon.jpg"; do
                            if [ -s "$ic" ]; then icon="$ic"; break 2; fi
                        done
                    done
                    printf '%s\\t%s\\t%s\\n' "$appid" "$name" "$icon"
                done
            done`]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text === root.lastScanText)
                    return;
                root.lastScanText = text;
                const out = [];
                for (const line of text.split("\n")) {
                    if (!line.trim())
                        continue;
                    const parts = line.split("\t");
                    if (parts.length < 2)
                        continue;
                    const appid = (parts[0] ?? "").trim();
                    const name = (parts[1] ?? "").trim();
                    const icon = (parts[2] ?? "").trim();
                    if (!appid || !name)
                        continue;
                    out.push({
                        id: "steam_app_" + appid,
                        name,
                        icon,
                        steamAppId: appid,
                        isSteam: true
                    });
                }
                out.sort((a, b) => a.name.localeCompare(b.name));
                root.games = out;
            }
        }
    }
}

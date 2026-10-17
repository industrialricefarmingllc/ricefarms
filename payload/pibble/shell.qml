// pibble - a desktop shell for wlr-layer-shell compositors.
// Copyright (C) 2026 Kian Blakley
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Notifications
import "root:/config"
import "root:/flyouts"
import "root:/launcher"
import "root:/services"
import "root:/startup"

// This file is only the wiring: it binds the three persisted stores to disk,
// puts up the four windows, and exposes the IPC the `pibble` script talks to.
// Everything else lives under:
//
//   config/    persisted settings and what the settings UI knows about them
//   services/  the shell's data sources - theme, wallpapers, clipboard, apps…
//   ui/        reusable settings controls, and the custom-page contract
//   launcher/  the launcher window, its state, and one file per pane
//   flyouts/   the volume and notification OSDs
//   startup/   invisible surfaces that only exist to measure the output
//
// Those layers only ever point one way - launcher/flyouts → ui → services →
// config - which is what keeps the directories acyclic.
ShellRoot {
    id: root

    // Adapters are singletons (so every reference is a plain `Settings.foo`);
    // these bind them to their files. A singleton can't be reparented into a
    // FileView's default property, which is why the two halves live apart.
    SettingsStore {}
    NotifCacheStore {}
    LaunchCountsStore {}

    // Each of these is a distinct wlr-layer-shell surface with its own
    // namespace, so a compositor can carry per-window rules (blur, in
    // particular) for them independently. See README.md for the table.
    LauncherWindow {
        id: launcher
    }
    // Launch-morph stage (see services/Morph.qml): separate window so the
    // launcher closes and releases focus the instant an app spawns.
    MorphOverlay {}
    VolumeOsd {}
    NotificationFlyout {}

    XrayScaleProbe {}

    // The shell runs as a persistent daemon; the launcher window is toggled
    // over IPC - `qs -p <repo> ipc call launcher toggle`, which is what the
    // `pibble` script wraps.
    IpcHandler {
        target: "launcher"

        // `page` is "" for a plain toggle (`pibble toggle`) or a pane id for
        // `pibble toggle <page>`. Closed: opens straight onto that page. Open
        // and already showing it: closes, so re-pressing the same page's
        // keybind acts like a normal toggle. Open and showing something else:
        // switches to it and stays open - a different page's keybind reads as
        // "take me there", not "close everything".
        function toggle(page: string): void {
            const target = LauncherState.resolvePageArg(page);
            if (launcher.shown && !LauncherState.exiting) {
                if (target && LauncherState.pane !== target)
                    LauncherState.setPane(target);
                else
                    launcher.exit();
            } else {
                launcher.open(target);
            }
        }
        // "show" would collide with the `qs ipc show` CLI subcommand
        function open(): void {
            if (!launcher.shown || LauncherState.exiting)
                launcher.open("");
        }
        function close(): void {
            launcher.hardClose();
        }
        // TEMPORARY debug 2: runs the exact focus branch onLaunchRequested
        // uses, for the first app whose name starts with the prefix.
        function testFocus(query: string): string {
            const q = (query || "").toLowerCase();
            for (const a of Apps.all) {
                if (a.name && a.name.toLowerCase().startsWith(q)) {
                    const addr = launcher.findExistingWindow(a);
                    if (!addr)
                        return "no window for " + a.name;
                    try {
                        Hyprland.dispatch("hl.dsp.focus({window='address:" + addr + "'})");
                        return "dispatched " + addr;
                    } catch (e) {
                        return "dispatch threw: " + e;
                    }
                }
            }
            return "no app starts with '" + query + "'";
        }
        function matchApp(query: string): string {
            const q = (query || "").toLowerCase();
            let tls = [];
            try {
                tls = Hyprland.toplevels ? Hyprland.toplevels.values : [];
            } catch (e) {
                return "toplevels error: " + e;
            }
            let tlInfo = "tls=" + tls.length;
            try {
                const sample = [];
                for (let i = 0; i < Math.min(5, tls.length); i++) {
                    const t = tls[i];
                    let cls = "?";
                    try {
                        cls = (t.lastIpcObject && t.lastIpcObject.class) ? t.lastIpcObject.class : ("wayland:" + (t.wayland ? t.wayland.appId : "null"));
                    } catch (e2) {
                        cls = "err";
                    }
                    sample.push(cls);
                }
                tlInfo += " [" + sample.join(", ") + "]";
            } catch (e) {
                tlInfo += " sample-err";
            }
            for (const a of Apps.all) {
                if (a.name && a.name.toLowerCase().startsWith(q)) {
                    const addr = launcher.findExistingWindow(a);
                    return "entry=" + a.name + " id=" + a.id + " sc=" + (a.startupClass || "(none)")
                        + " cands=" + launcher.entryClassCandidates(a).join(",")
                        + " fuzzy=" + launcher.entryFuzzyCandidates(a).join(",")
                        + " addr=" + (addr || "(none)") + " " + tlInfo;
                }
            }
            return "no app starts with '" + query + "' " + tlInfo;
        }
        function replay(): void {
            Notifier.replay();
        }
    }
    // Morph control over IPC (`pibble killflights`): the launcher window
    // has no business reaching into flights, so the morph owns its own
    // target. One function today; grows here if the chord gains siblings.
    IpcHandler {
        target: "morph"

        // Returns whether anything was killed (see Morph.killFlights):
        // the chord falls through to closing the focused window on false.
        function killFlights(): bool {
            return Morph.killFlights();
        }
    }
}

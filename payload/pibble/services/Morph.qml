pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Android-style launch morphs: when an app launches from the grid, a small
// Theme-surfaced container starts at the tile's rect and expands into the
// window's real rect once it maps, icon centered throughout - then fades,
// revealing the window underneath.
//
// This file is only the model and the matching: what is flying, where from,
// where to (all GLOBAL coords - per-screen stages in MorphOverlay convert to
// local), and which mapped window belongs to which launch. Rendering lives
// in launcher/MorphOverlay.qml (separate, input-transparent windows, so the
// launcher itself closes the instant the app spawns and focus is released
// immediately - consecutive launches just append more morphs).
//
// Window matching without a PID (gtk-launch double-forks, so none survives):
// every sighting stamps first-seen times per client address. A launch claims
// the first client seen *after* it that matches the entry's intended
// class/name. Pre-existing windows are seen on the first poll and never
// claimable, which is also what makes back-to-back launches of the same app
// assign correctly.
//
// Covering (NOT hiding): per-window opacity overrides were proven dead on
// this compositor (accepted with ok, zero visual effect), and no hiding
// primitive exists that survives without a config reload. Instead the event
// bridge reports each new window WITH its geometry, and the overlay draws an
// opaque stand-in over it from that first tick; the morph flies into the
// stand-in, and both fade together to reveal the window. The only uncovered
// window is the ~milliseconds between map and the first sighting.
Singleton {
    id: root

    // Roles per row: mid, matchKey, icon, isSteam,
    // fromGX/GY/GW/GH (global source),
    // toGX/GY/GW/GH (global flight target, on landing),
    // covGX/GY/GW/GH + covOn + wsOk (opaque stand-in over the live window),
    // candGX/GY/GW/GH + candMon + candStamp (settling flight candidate),
    // monId (routing: launcher monitor while waiting, target at landing),
    // phase ("wait" | "morph" | "fade"), born, addr.
    property ListModel morphs: ListModel {}
    // address -> first-seen Date.now(). Never cleared: addresses are unique
    // per window, so this only grows by windows mapped while morphs pend.
    property var seenAddrs: ({})
    property int seq: 0
    // Morphs still waiting on their window: the only thing the poll serves.
    // Maintained by setPhase, never written elsewhere.
    property int pending: 0
    // Rows needing attention (wait OR morph): drives settle + watchdog.
    // (pending alone can't: it hits zero at first landing, which used to
    // silence settle mid-flight - freezing the cover and stranding the
    // retarget path. That was the persistent "misaligned" bug.)
    property int active: 0
    // Mutation stamp: bumped on EVERY model write (append/set/remove).
    // Stage routing reads it instead of trusting ListModel.dataChanged,
    // which proved unreliable - a row migrating monitors via set() never
    // flipped stage visibility and flights rendered into dark stages.
    property int rev: 0
    function touch(): void {
        root.rev++;
    }

    // Monitor geometry from the compositor itself (hyprctl monitors -j),
    // fetched once at startup: name -> {id, x, y}. This is the single
    // source of truth for stage routing and global/local conversion.
    // Quickshell's Hyprland.monitorFor() answers STUBS (id -1, x/y 0) until
    // long after load - and id can go real while x/y are still stub-zero,
    // which misplaced early waiter renders by the full origin. Never trust
    // it directly; monGeo() below falls back to it only when the cache
    // misses (first 100ms of daemon life, effectively never a real launch).
    property var monGeos: ({})
    property int geosAt: 0
    function monGeo(name: string): var {
        if (name && root.monGeos[name])
            return root.monGeos[name];
        return null;
    }
    function monGeoById(id: int): var {
        for (const n in root.monGeos)
            if (root.monGeos[n].id === id)
                return root.monGeos[n];
        return null;
    }
    // Persisted predictions, loaded once at startup (see rememberGeo).
    FileView {
        path: Quickshell.statePath("morph-geos.json")
        onLoaded: {
            try {
                const o = JSON.parse(text());
                if (o && typeof o === "object")
                    root.lastGeos = o;
            } catch (e) {}
        }
    }
    // A launch that never maps (slow game, failed spawn) must not hold a
    // morph - or the poll - open forever.
    readonly property int mapTimeoutMs: 1500
    // Cap for held goo: the spring settled but no window ever claimed it
    // (key mismatch, failed spawn). Slow-but-matching launches claim well
    // before this and morph normally; without the cap a miss would sit on
    // the predicted target until the 8s reap.
    readonly property int holdTimeoutMs: 2000
    // Freshness floor: a client first seen within this of the launch is the
    // launcher/poll catching up, not the app mapping.
    readonly property int freshFloorMs: 120
    // A flight target must sit still this long before the morph commits:
    // tiled retile animations sweep transient geometries past first.
    readonly property int settleMs: 300
    // Below this a sighting is a window mid-configure (or junk), never a
    // flight target. (No separate cover threshold: the cover shares the
    // candidate - a small-transient cover is worse than none, it reads as
    // a second, misplaced morph.)
    readonly property int minFlight: 80
    // Consecutive sightings must agree within this to count as settled.
    readonly property real settleSlop: 6
    // Concurrent morph cap: beyond it the oldest waiting one bows out.
    readonly property int maxMorphs: 4

    // Live window workspace (for the reveal trip back) + the window
    // hider: the app maps milliseconds after spawn but the morph runs
    // ~1.5s, so the window parks on a silent special workspace for the
    // flight and returns exactly when the goo fades. No compositor
    // opacity tricks - per-window opacity overrides were proven dead.
    // Lua-form dispatch (see killOne below): native `dispatcher args`
    // syntax is a parse error on this compositor. window.move is silent
    // (active workspace untouched - verified live).
    function moveWindow(addr: string, ws: string): void {
        if (!addr || !ws)
            return;
        // follow = false: the window moves in the background while the user
        // stays on whatever workspace they switched to after launching.
        Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.window.move({ workspace = "' + ws + '", window = "address:' + addr + '", follow = false })']);
    }
    // Pin a freshly mapped window back to the workspace its launch was
    // initiated on. Only fires when the window visibly followed a post-launch
    // switch (it landed on the *current* focused workspace instead of the
    // origin): a window that landed anywhere else is rule-forced (e.g. a
    // `workspace` windowrule) and is left alone. Unknown origin/current
    // (-1, bridge dead) fails visible rather than risk breaking rules.
    function pinToOrigin(addr: string, claimedWsid: int, originWs: int): void {
        if (!addr || !(claimedWsid > 0) || !(originWs > 0))
            return;
        if (claimedWsid === originWs)
            return;
        if (root.activeWs <= 0)
            return;
        if (claimedWsid !== root.activeWs)
            return;
        root.moveWindow(addr, String(originWs));
    }
    // No more hiding: every claimed window used to park on special:morph
    // for the flight, but a window that the compositor moves itself (new
    // apps landing on other workspaces, launchers exiting mid-flight)
    // came back to the WRONG place - or never came back. The goo is opaque
    // and covers the spawn flash on its own; the window simply appears
    // underneath and is revealed at fade. No hide, no reveal, no strand.
    function hideWindow(addr: string): void {
    }
    function revealWindow(m): void {
    }
    // Recently landed rows, for the chord kill below: the flight only lasts
    // ~1s (far shorter than human reaction time), so by the time C-BackSpace,
    // x lands the row is usually already faded and gone - with no row left,
    // there is no address left to kill. finish() parks {addr, at} here;
    // killFlights() spends them one-shot (see there).
    // RETIRED (kept for the finish() writer below, do not read): killing
    // finished rows closed unrelated windows - a dead row's address can be
    // reused by the compositor within seconds (observed live: chord closed
    // a settled app minutes after its morph). The chord kills live rows
    // only now; this list only feeds the parking backstop.
    property var recentDone: []
    // Slow launches: a cold app (Discord, games) maps long after its row
    // bowed out (~1s), so no row is left to claim it and the chord finds no
    // address. Every spawn is therefore remembered briefly ({mid, matchKey,
    // born}, 60s TTL); a window that maps with no live row to claim it is
    // tied back to its launch here (see onOpenLine) instead of being lost.
    property var pendingLaunches: []
    // Windows tied to launches after their rows died (see above):
    // {addr, at}. RETIRED as chord fuel (same address-reuse hazard as
    // recentDone): recording only now, never killed.
    property var chordTargets: []
    function pruneLaunches(): void {
        const now = Date.now();
        root.pendingLaunches = root.pendingLaunches.filter(l => l && !l.done && now - l.born < 60000).slice(-20);
    }
    function satisfyLaunch(mid: int): void {
        for (const l of root.pendingLaunches)
            if (l && l.mid === mid)
                l.done = true;
    }
    // Morph-less launch pin (plain launches with no tile rect, browser
    // fallback with no entry at all): no visual row, just an origin-tagged
    // memory so a window mapping within the TTL still pins back to the
    // launch desktop (see onOpenLine/trackLateWindow). mid -1 marks
    // rows that never had a morph to satisfy.
    function pinLaunch(matchKey: string, originWs: int): void {
        if (!(originWs > 0))
            return;
        root.pruneLaunches();
        root.pendingLaunches.push({ mid: -1, matchKey: (matchKey || "").toLowerCase(), born: Date.now(), originWs: originWs });
    }
    // Chord kill (C-BackSpace, x): closes the window of a LIVE morph row
    // only (claimed address, still morphing). Nothing else is a safe
    // target: recently finished rows may already be gone with their
    // address reused (a late kill would close an unrelated window), and
    // unclaimed rows have no address at all. One press, one flight.
    // NOTE: this compositor evaluates `hyprctl dispatch` arguments as lua
    // (native `dispatcher args` syntax is a parse error - verified live), so
    // kills go through hl.dsp.window.close({window=...}), not killwindow.
    function killOne(addr: string): void {
        if (!addr)
            return;
        Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.window.close({ window = "address:' + addr + '" })']);
    }
    // Returns whether anything was actually killed. The chord (see the
    // tmux x bind) uses it to fall through to closing the focused window
    // when no flight/recent launch exists - so the chord closes ANY window,
    // preferring in-flight/recent launches. Goo-bow-out still happens
    // regardless (side effect, not counted).
    function killFlights(): bool {
        let killed = false;
        for (let i = 0; i < root.morphs.count; i++) {
            const m = root.morphs.get(i);
            if (m.phase !== "morph" && m.phase !== "fade")
                continue;
            if (m.addr) {
                root.killOne(m.addr);
                killed = true;
            }
            if (m.phase === "morph")
                root.setPhase(i, "fade");
        }
        const now = Date.now();
        for (const r of root.recentDone) {
            if (r.addr && now - r.at < 8000) {
                root.killOne(r.addr);
                killed = true;
            }
        }
        root.recentDone = [];
        for (const r of root.chordTargets) {
            if (r.addr && now - r.at < 20000) {
                root.killOne(r.addr);
                killed = true;
            }
        }
        root.chordTargets = [];
        return killed;
    }
    // The morph starts the instant the app spawns - before the window
    // maps - aimed here (centered where the window will open), then
    // steers onto the live rect when the claim lands. Persisted across
    // restarts (see morph-geos.json): an in-memory map would go blank on
    // every reboot and every prediction would miss. Zero-history launches
    // predict a near-fullscreen rect on the launch monitor instead.
    property var lastGeos: ({})

    function rememberGeo(i: int): void {
        const m = root.morphs.get(i);
        if (!m || !m.matchKey || m.candMon === undefined || m.candMon < 0)
            return;
        root.lastGeos[m.matchKey] = { x: m.candGX, y: m.candGY, w: m.candGW, h: m.candGH, mon: m.candMon };
        const keys = Object.keys(root.lastGeos);
        if (keys.length > 40) {
            const fresh = {};
            keys.slice(-40).forEach(k => fresh[k] = root.lastGeos[k]);
            root.lastGeos = fresh;
        }
        root.persistGeos();
    }

    function persistGeos(): void {
        // Direct argv exec, no shell: paths may contain anything except
        // NUL and this never quotes.
        try {
            Quickshell.execDetached(["python3", "-c", "import sys; open(sys.argv[2], 'w').write(sys.argv[1])",
                JSON.stringify(root.lastGeos), Quickshell.statePath("morph-geos.json")]);
        } catch (e) {}
    }

    // entry: DesktopEntries row (or Steam's plain object); r: tile rect in
    // the launcher surface's coords; monId/orgX/orgY: that surface's monitor
    // (id for stage routing, origin for the global conversion).
    // originWs: workspace id the launch was initiated on (focused workspace
    // at Enter time, passed by the caller - falls back to the bridged
    // activeWs when omitted/invalid). Stored per row as `ws`: the flight
    // hides off-origin, and the claim below pins the window back to it when
    // it followed a post-launch switch instead.
    // Returns whether a morph row was actually queued (false = plain launch,
    // caller keeps the ordinary animated close).
    function spawn(entry, r, monId, orgX, orgY, originWs): bool {
        if (!entry || !r || r.width <= 0 || monId === undefined || monId < 0)
            return false;
        // A nonsense origin (e.g. an undefined monitor property) must never
        // produce a NaN flight - no morph, never no launch.
        if (!Number.isFinite(orgX + orgY))
            return false;
        // Keep the monitor cache fresh across hot-plugs: at most one
        // background refresh per minute, only around real launches.
        if (Date.now() - root.geosAt > 60000 && !monitorsProc.running)
            monitorsProc.running = true;
        while (root.morphs.count >= root.maxMorphs) {
            // Oldest first; every row is mid-flight (spawn flies
            // immediately), so bow out the oldest - worst case the cap is
            // hit by stale rows the watchdog is about to reap anyway.
            let done = false;
            for (let i = 0; i < root.morphs.count; i++) {
                if (root.morphs.get(i).phase === "morph") {
                    root.setPhase(i, "fade");
                    done = true;
                    break;
                }
            }
            if (!done)
                root.finish(0);
        }
        root.seq++;
        // Immediate flight: the goo is visible from the spawn frame,
        // aimed at the predicted target - never a dead dot sitting on
        // the tile while the window maps. The claim steers it onto the
        // real rect (see landFromCandidate); unclaimed rows hold the
        // settled goo, then bow out with the spring.
        const key = ((entry.startupClass || entry.name) || "").toLowerCase();
        const lg = root.lastGeos[key];
        // Zero-history fallback: a fresh window on a tiling compositor
        // usually takes the whole workspace, so predict a near-fullscreen
        // rect on the launch monitor (centered, expanded) instead of the
        // tile - the claim steers onto the real rect either way.
        const mg = root.monGeoById(monId);
        // Zero-history fallback clears the reserved edges (Lucid's bar
        // among them) with room to spare, plus a breathing gap - never
        // the tile, never under the bar.
        const fx = mg ? mg.x + (mg.rl || 0) + 40 : r.x + orgX;
        const fy = mg ? mg.y + (mg.rt || 0) + 16 : r.y + orgY;
        const fw = mg && mg.w > 0 ? mg.w - (mg.rl || 0) - (mg.rr || 0) - 80 : 1200;
        const fh = mg && mg.h > 0 ? mg.h - (mg.rt || 0) - (mg.rb || 0) - 56 : 750;
        root.morphs.append({
            mid: root.seq,
            matchKey: key,
            icon: entry.icon || "",
            isSteam: entry.isSteam === true,
            fromGX: r.x + orgX, fromGY: r.y + orgY, fromGW: r.width, fromGH: r.height,
            toGX: lg ? lg.x : fx, toGY: lg ? lg.y : fy,
            toGW: lg ? lg.w : fw, toGH: lg ? lg.h : fh,
            covGX: 0, covGY: 0, covGW: 0, covGH: 0, covOn: false, wsOk: true,
            candGX: 0, candGY: 0, candGW: 0, candGH: 0, candMon: -1, candStamp: 0,
            monId: lg ? lg.mon : monId,
            ws: (originWs > 0) ? originWs : root.activeWs,
            wsid: -1,
            phase: "morph",
            born: Date.now(),
            addr: ""
        });
        root.pending++;
        // Remember the launch for the chord kill's slow-app path (see
        // pendingLaunches): matched when its window maps, even if the row
        // above is long gone by then. originWs rides along so a late
        // window (cold app mapping after its row bowed out) still pins
        // back to the launch desktop (see trackLateWindow).
        root.pruneLaunches();
        const origin = (originWs > 0) ? originWs : root.activeWs;
        root.pendingLaunches.push({ mid: root.seq, matchKey: key, born: Date.now(), originWs: origin });
        // Don't wait a whole interval for the first look (poll fallback; the
        // event listener usually claims first).
        root.poll();
        root.touch();
        root.active++;
        return true;
    }

    function rowOf(mid: int): int {
        for (let i = 0; i < root.morphs.count; i++)
            if (root.morphs.get(i).mid === mid)
                return i;
        return -1;
    }

    // The one funnel for phase changes: keeps `pending` exact so the
    // poll runs only while a morph is actually waiting on a window. The
    // flight itself then runs with zero process churn behind it.
    // `active` (settle/watchdog scope) additionally survives into morph.
    function setPhase(i: int, p: string): void {
        const was = root.morphs.get(i).phase;
        // Idempotent lands must not replay the flight: ListModel notifies
        // even on same-value sets, and the view restarts the spring on
        // every phase notification.
        if (was === p)
            return;
        if (was === "wait" && p !== "wait")
            root.pending = Math.max(0, root.pending - 1);
        if ((was === "wait" || was === "morph") && p !== "wait" && p !== "morph")
            root.active = Math.max(0, root.active - 1);
        root.morphs.setProperty(i, "phase", p);
        root.touch();
    }

    // View-side: the flight animation landed - start the fade. Container
    // and cover fade together (same opacity), which reads as the window
    // fading in underneath.
    function beginFade(mid: int): void {
        const i = root.rowOf(mid);
        if (i >= 0 && root.morphs.get(i).phase === "morph") {
            // Flight over: the window returns from its parking spot as
            // the goo fades, reading as one transforming into the other.
            root.revealWindow(root.morphs.get(i));
            root.morphs.setProperty(i, "phase", "fade");
            root.touch();
        }
    }

    function finish(i: int): void {
        if (i < 0 || i >= root.morphs.count)
            return;
        const m = root.morphs.get(i);
        if (m.phase === "wait")
            root.pending = Math.max(0, root.pending - 1);
        else if (m.phase === "morph" && !m.addr)
            root.pending = Math.max(0, root.pending - 1);
        if (m.phase === "wait" || m.phase === "morph")
            root.active = Math.max(0, root.active - 1);
        delete root.retargetCount[m.mid];
        // Remember landed rows for the chord kill (see recentDone): only
        // rows with a claimed address, only the last few seconds' worth.
        if (m.addr) {
            const now = Date.now();
            const done = root.recentDone.filter(r => r.addr && now - r.at < 8000);
            done.push({ addr: m.addr, at: now });
            root.recentDone = done.slice(-20);
        }
        // Backstop: never strand a window on the parking workspace, no
        // matter which path removed its row (reveal is a harmless no-op
        // for already-visible windows).
        root.revealWindow(m);
        root.morphs.remove(i);
        root.touch();
    }

    function remove(mid: int): void {
        root.finish(root.rowOf(mid));
    }

    function matches(client, key: string): bool {
        if (!key)
            return true; // no key: any fresh window is plausibly ours
        const hay = ((client.initialClass || "") + "\n" + (client.class || "") + "\n" + (client.title || "")).toLowerCase();
        return hay.indexOf(key) >= 0 || key.indexOf((client.initialClass || client.class || "").toLowerCase()) >= 0;
    }

    // One sighting of a claimed address (event bundle or poll fetch):
    // refresh the cover at once, and record the flight candidate.
    // The cover follows EVERY sighting (even within slop): it must stay
    // glued to the live window. The candidate only renews on real change,
    // so settle can OBSERVE stillness (re-stamping identical sightings
    // would keep every window "moving" forever).
    // Morph-phase rows keep cover-tracking; nothing else about them moves.
    function sight(i: int, addr: string, x: real, y: real, w: real, h: real, wsOk: bool, mon: int, wsid: int): void {
        const m = root.morphs.get(i);
        if (!m)
            return;
        if (m.phase !== "wait" && m.phase !== "morph")
            return;
        if (!m.addr) {
            if (!addr)
                return;
            root.morphs.setProperty(i, "addr", addr);
            root.satisfyLaunch(m.mid);
            if (wsid > 0)
                root.morphs.setProperty(i, "wsid", wsid);
            // Launch-desktop pin: the app maps on whatever workspace is
            // focused at map time, so a switch between Enter and map lands
            // it on the wrong desktop. Move it back to the origin when it
            // visibly followed the switch (see pinToOrigin) - silent, the
            // user stays where they switched to.
            root.pinToOrigin(addr, wsid, m.ws);
            // Immediate-morph rows were counted pending at spawn (the poll
            // must run to find their window); the claim releases it. Wait
            // rows keep the funnel accounting in setPhase.
            if (m.phase === "morph")
                root.pending = Math.max(0, root.pending - 1);
            // Window just mapped: park it on the silent special workspace
            // for the flight (see hideWindow), revealed at beginFade.
            root.hideWindow(addr);
            root.touch();
        }
        // Live workspace for the reveal trip back.
        if (wsid > 0 && root.morphs.get(i).wsid !== wsid)
            root.morphs.setProperty(i, "wsid", wsid);
        if (w >= root.minFlight && h >= root.minFlight)
            root.morphs.set(i, { covGX: x, covGY: y, covGW: w, covGH: h, covOn: true, wsOk: wsOk });
        if (m.phase !== "wait" && m.phase !== "morph")
            return root.touch();
        if (m.phase === "morph") {
            // Immediate flight, first sighting: record the candidate and
            // steer onto it (see landFromCandidate).
            if (m.candStamp <= 0 && w >= root.minFlight && h >= root.minFlight) {
                root.morphs.set(i, {
                    candGX: x, candGY: y, candGW: w, candGH: h,
                    candMon: mon, candStamp: Date.now()
                });
                root.touch();
                root.landFromCandidate(i);
            }
            return root.touch();
        }
        if (w < root.minFlight || h < root.minFlight)
            return;
        const slop = root.settleSlop;
        if (m.candStamp > 0 && mon === m.candMon
                && Math.abs(x - m.candGX) <= slop && Math.abs(y - m.candGY) <= slop
                && Math.abs(w - m.candGW) <= slop && Math.abs(h - m.candGH) <= slop)
            return;
        const first = m.candStamp <= 0;
        root.morphs.set(i, {
            candGX: x, candGY: y, candGW: w, candGH: h,
            candMon: mon, candStamp: Date.now()
        });
        root.touch();
        // Fly at the FIRST plausible geometry instead of waiting out the
        // settle window with a breathing waiter: the dead time between map
        // and motion was the whole perceived lag. Settle still commits the
        // final target (see checkSettle), which retargets once, smoothly.
        if (first)
            root.landFromCandidate(i);
    }

    function poll(): void {
        if (!clientsProc.running)
            clientsProc.running = true;
    }

    Timer {
        id: pollTimer
        // Only the fallback for a dead listener: brisk while anything waits,
        // silent otherwise (the event path claims first and costs nothing).
        interval: 40
        repeat: true
        running: root.pending > 0 && !eventsProc.running
        onTriggered: root.poll()
    }

    Process {
        id: clientsProc
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: root.onClients(text)
        }
    }

    // One-shot at startup (plus on listener death, in case outputs moved):
    // monitor id/origin per name. Drives stage routing + conversion; the
    // poll above never needs it.
    Process {
        id: monitorsProc
        command: ["hyprctl", "monitors", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const arr = JSON.parse(text);
                    if (Array.isArray(arr)) {
                        const geos = {};
                        for (const m of arr) {
                            if (!m.name)
                                continue;
                            // width/height are PHYSICAL px, x/y logical -
                            // divide by scale or predictions land off-center
                            // bottom-right (observed live on a 1.6x output).
                            const sc = m.scale > 0 ? m.scale : 1;
                            // Reserved edges are logical [left, top, right,
                            // bottom] (top == Lucid's bar height where one
                            // is reserved); the fallback clears them.
                            const rs = m.reserved || [0, 0, 0, 0];
                            geos[m.name] = { id: m.id, x: m.x, y: m.y,
                                w: m.width / sc, h: m.height / sc,
                                rl: rs[0] || 0, rt: rs[1] || 0, rr: rs[2] || 0, rb: rs[3] || 0 };
                        }
                        root.monGeos = geos;
                        root.geosAt = Date.now();
                    }
                } catch (e) {}
            }
        }
    }
    Timer {
        id: monitorsKick
        interval: 1500
        running: true
        repeat: false
        onTriggered: {
            if (!monitorsProc.running)
                monitorsProc.running = true;
        }
    }

    function findClient(clients, addr: string): var {
        for (const c of clients)
            if (String(c.address || "") === addr)
                return c;
        return null;
    }

    function onClients(text: string): void {
        let clients = null;
        try {
            clients = JSON.parse(text);
        } catch (e) {
            return;
        }
        if (!Array.isArray(clients))
            return;
        const now = Date.now();
        for (const c of clients) {
            const addr = String(c.address || "");
            if (!addr || addr in root.seenAddrs)
                continue;
            root.seenAddrs[addr] = now;
        }
        for (let i = 0; i < root.morphs.count; i++) {
            const m = root.morphs.get(i);
            if (m.phase !== "wait" && m.phase !== "morph")
                continue;
            if (m.addr) {
                // Already claimed: refresh cover + candidate from the live
                // rect (cover keeps tracking through the flight); vanish
                // the cover if the window went away.
                const known = root.findClient(clients, m.addr);
                if (known) {
                    const at = known.at || [0, 0];
                    const size = known.size || [0, 0];
                    const kw = known.workspace;
                    const kid = (kw && typeof kw === "object") ? kw.id : kw;
                    root.sight(i, m.addr, at[0], at[1], size[0], size[1], true, known.monitor, Number(kid));
                } else if (m.phase === "morph") {
                    // App window closed mid-flight: bow out the goo with
                    // it (no reveal - the window is gone).
                    root.setPhase(i, "fade");
                } else {
                    root.morphs.setProperty(i, "covOn", false);
                    root.touch();
                }
                continue;
            }
            if (m.phase !== "wait" && m.phase !== "morph")
                continue;
            for (const c of clients) {
                const addr = String(c.address || "");
                if (!addr || root.seenAddrs[addr] <= m.born + root.freshFloorMs)
                    continue;
                if (root.claimed(addr, m.mid))
                    continue;
                if (!root.matches(c, m.matchKey))
                    continue;
                const at = c.at || [0, 0];
                const size = c.size || [0, 0];
                const cw = c.workspace;
                const cwid = (cw && typeof cw === "object") ? cw.id : cw;
                root.sight(i, addr, at[0], at[1], size[0], size[1], true, c.monitor, Number(cwid));
                break;
            }
        }
    }

    function claimed(addr: string, mid: int): bool {
        for (let i = 0; i < root.morphs.count; i++) {
            const m = root.morphs.get(i);
            if (m.addr === addr && m.mid !== mid)
                return true;
        }
        return false;
    }

    // --- event listener (primary detector) ---
    // A persistent python bridge over the compositor event socket (see
    // services/morph-events.py): each new window arrives WITH its geometry,
    // sub-millisecond, instead of poll ticks. Anything it can't do, the
    // poll above still covers.
    property string eventsScript: {
        const p = Quickshell.env("PIBBLE_MORPH_EVENTS");
        return p ? p : "";
    }
    property int eventCursor: 0
    // Focused workspace id, streamed by the event bridge (WS lines): a
    // flight stays on the workspace it launched on - switching desktops
    // mid-flight hides it there instead of drawing over the wrong one.
    // -1 (bridge dead / not yet seeded) means unknown: fail visible.
    property int activeWs: -1

    Process {
        id: eventsProc
        command: root.eventsScript ? ["python3", root.eventsScript] : []
        running: !!root.eventsScript
        stdout: StdioCollector {
            waitForEnd: false
            onTextChanged: root.onEventText(text)
        }
        stderr: StdioCollector {
            waitForEnd: false
            onTextChanged: console.warn("morph-events:", text.slice(-300))
        }
        onExited: (code) => {
            // Compositor restart, crash, missing python: the poll covers
            // the gap (see pollTimer's listenerAlive gate); re-establish
            // after a beat.
            if (root.eventsScript)
                listenerRestart.restart();
        }
    }

    Timer {
        id: listenerRestart
        interval: 1000
        onTriggered: {
            if (root.eventsScript && !eventsProc.running)
                eventsProc.running = true;
        }
    }

    function onEventText(text: string): void {
        const fresh = text.slice(root.eventCursor);
        root.eventCursor = text.length;
        for (const line of fresh.split("\n")) {
            if (line.startsWith("OPEN "))
                root.onOpenLine(line);
            else if (line.startsWith("GEOM "))
                root.onGeomLine(line);
            else if (line.startsWith("WS ")) {
                const id = Number(line.slice(3));
                if (Number.isFinite(id))
                    root.activeWs = id;
            }
        }
    }

    // Streamed re-describes (see the bridge): same trailing numerics as
    // OPEN, no names. Only refreshes already-claimed rows - claiming stays
    // with OPEN/fresh-match so a stray line can never adopt a window.
    function onGeomLine(line: string): void {
        const parts = line.split(" ").filter(p => p.length > 0);
        if (parts.length !== 9 || parts[0] !== "GEOM")
            return;
        const nums = parts.slice(2).map(Number);
        if (nums.some(v => !Number.isFinite(v)))
            return;
        const addr = parts[1];
        for (let i = 0; i < root.morphs.count; i++) {
            const m = root.morphs.get(i);
            if ((m.phase !== "wait" && m.phase !== "morph") || m.addr !== addr)
                continue;
            root.sight(i, addr, nums[0], nums[1], nums[2], nums[3], nums[5] === 1, nums[6], nums[4]);
            break;
        }
    }

    // Trailing seven tokens are numeric (x y w h wsid active monid); the
    // title between class and those may hold spaces, so parse from the end.
    function onOpenLine(line: string): void {
        const parts = line.split(" ").filter(p => p.length > 0);
        if (parts.length < 10 || parts[0] !== "OPEN")
            return;
        const tail = parts.slice(-7).map(Number);
        if (tail.some(v => !Number.isFinite(v)))
            return;
        const addr = parts[1];
        const cls = parts[2] || "";
        let claimedRow = false;
        for (let i = 0; i < root.morphs.count; i++) {
            const m = root.morphs.get(i);
            if ((m.phase !== "wait" && m.phase !== "morph") || m.addr)
                continue;
            if (root.claimed(addr, m.mid))
                continue;
            if (!root.matches({ initialClass: cls, class: cls, title: "" }, m.matchKey))
                continue;
            // Claim + first sighting in one tick: the cover is up within
            // milliseconds of map. Flight waits for settle (see below).
            root.sight(i, addr, tail[0], tail[1], tail[2], tail[3], tail[5] === 1, tail[6], tail[4]);
            if (!clientsProc.running)
                clientsProc.running = true; // keep sightings coming till settle
            claimedRow = true;
            break; // one event, one claim (addresses are unique)
        }
        if (!claimedRow)
            root.trackLateWindow(addr, cls, tail[4]);
    }
    // Slow-app path for the chord kill (see pendingLaunches): a window that
    // mapped with no live row to claim it (row bowed out before a cold app
    // mapped) is tied back to the youngest awaiting launch it matches. Only
    // genuinely fresh maps arrive here (OPEN lines), pre-existing windows
    // never do, so no freshFloor guard is needed. Recording only: no
    // parking, no cover, no flight - plus the launch-desktop pin, so a cold
    // app mapping after a switch still lands on the origin (tail wsid is the
    // workspace it actually mapped on).
    function trackLateWindow(addr: string, cls: string, wsid: int): void {
        if (!addr)
            return;
        root.pruneLaunches();
        const now0 = Date.now();
        for (let k = root.pendingLaunches.length - 1; k >= 0; k--) {
            const l = root.pendingLaunches[k];
            if (!l || l.done)
                continue;
            // Morph-less pins (browser fallback, plain launches) carry an
            // empty/broad key: only honour them while fresh (15s) so a stale
            // pin can't claim an unrelated later window. Morph-backed
            // entries keep the full 60s TTL for cold apps.
            if (l.mid === -1 && now0 - l.born > 15000)
                continue;
            if (!root.matches({ initialClass: cls, class: cls, title: "" }, l.matchKey))
                continue;
            l.done = true;
            if (l.originWs > 0 && wsid > 0)
                root.pinToOrigin(addr, wsid, l.originWs);
            const now = Date.now();
            const kept = root.chordTargets.filter(r => r && r.addr && now - r.at < 20000);
            kept.push({ addr: addr, at: now });
            root.chordTargets = kept.slice(-20);
            return;
        }
    }

    // Promotes settled candidates to flights. Runs on its own cadence (not
    // the poll's): geometry reads must be spaced to observe stillness.
    // 60ms: the cover chases a retile-animated window in small steps, so a
    // slow chase reads as misalignment (the window outruns it mid-flight).
    Timer {
        id: settle
        interval: 60
        repeat: true
        running: root.active > 0
        onTriggered: root.checkSettle()
    }

    function checkSettle(): void {
        const now = Date.now();
        let needFetch = false;
        for (let i = 0; i < root.morphs.count; i++) {
            const m = root.morphs.get(i);
            if ((m.phase !== "wait" && m.phase !== "morph") || !m.addr)
                continue;
            if (m.phase === "wait" && !m.wsOk) {
                // A window on a workspace nobody is looking at gets no
                // flight: the stage would draw over the wrong desktop. Bow
                // out so the window simply appears when its workspace is
                // viewed.
                root.setPhase(i, "fade");
                continue;
            }
            if (now - m.born > root.mapTimeoutMs) {
                // Never settled: wait rows fly to the latest candidate if
                // there is one worth flying to, else bow out in place.
                // (Flying rows just finish their flight; the fade reveals
                // wherever the window is, cover-tracked throughout.)
                if (m.phase === "wait") {
                    if (m.candStamp > 0 && m.candGW >= root.minFlight && m.candGH >= root.minFlight)
                        root.landFromCandidate(i);
                    else
                        root.setPhase(i, "fade");
                }
                continue;
            }
            if (m.candStamp <= 0) {
                needFetch = true;
                continue;
            }
            if (now - m.candStamp >= root.settleMs) {
                // Settled: wait rows take off (usually already flying - the
                // first candidate lands immediately from sight()); morph
                // rows re-aim once, smoothly (see commitSettled). No-op
                // when already aiming there.
                if (m.phase === "wait")
                    root.landFromCandidate(i);
                else
                    root.commitSettled(i);
                continue;
            }
            // Still settling: keep the sightings coming every tick so the
            // cover tracks the live window instead of freezing on the first
            // (usually transient) geometry until landing.
            needFetch = true;
        }
        if (needFetch && !clientsProc.running)
            clientsProc.running = true;
    }

    // Retarget budget per morph: the provisional flight may chase a moving
    // window, but unbounded restarts would never land. Two retargets cover
    // a retile sweep; after that it flies to the last target while the
    // (live-bound) cover keeps tracking regardless.
    property var retargetCount: ({})

    // Settle commit: point an already-flying row at the settled candidate.
    // Routing (monId) is fixed at first landing - a monitor hop mid-flight
    // is rarer than the teleport a re-route would cause.
    function commitSettled(i: int): void {
        const m = root.morphs.get(i);
        if (!m || m.phase !== "morph")
            return;
        const slop = root.settleSlop;
        if (Math.abs(m.candGX - m.toGX) <= slop && Math.abs(m.candGY - m.toGY) <= slop
                && Math.abs(m.candGW - m.toGW) <= slop && Math.abs(m.candGH - m.toGH) <= slop)
            return; // already aiming there
        if ((root.retargetCount[m.mid] || 0) >= 2)
            return;
        root.retargetCount[m.mid] = (root.retargetCount[m.mid] || 0) + 1;
        root.morphs.set(i, {
            toGX: m.candGX, toGY: m.candGY, toGW: m.candGW, toGH: m.candGH
        });
        root.rememberGeo(i);
        root.touch();
    }

    // Flight commit from the settled candidate. Target stays global - each
    // stage converts to its own local. Routing flips to the window's
    // monitor, so the flight renders on the screen the window is on.
    // Also serves immediate flights: their first claim steers the
    // predicted flight onto the real rect (setPhase is idempotent, so no
    // replay), and banks the geometry for the next launch.
    function landFromCandidate(i: int): void {
        const m = root.morphs.get(i);
        if (!m || (m.phase !== "wait" && m.phase !== "morph"))
            return;
        // set() applies all roles before notifying, so the view's phase
        // handler already sees the endpoints.
        root.morphs.set(i, {
            toGX: m.candGX, toGY: m.candGY, toGW: m.candGW, toGH: m.candGH,
            monId: m.candMon,
            covGX: m.candGX, covGY: m.candGY, covGW: m.candGW, covGH: m.candGH
        });
        root.rememberGeo(i);
        root.touch();
        root.setPhase(i, "morph");
    }
    // Time-based backstop for rows the event path never claimed (dead
    // listener without poll, vanished windows): finish off wait rows past
    // their timeout and reap the long-dead. Claimed rows are the settle
    // timer's business above.
    Timer {
        id: watchdog
        interval: 500
        repeat: true
        running: root.active > 0
        onTriggered: root.checkTimeouts()
    }

    function checkTimeouts(): void {
        const now = Date.now();
        for (let i = 0; i < root.morphs.count; i++) {
            const m = root.morphs.get(i);
            if (m.phase !== "wait" || m.addr)
                continue;
            if (now - m.born > root.mapTimeoutMs)
                root.setPhase(i, "fade"); // never mapped: bow out in place
        }
        for (let i = 0; i < root.morphs.count; i++) {
            const m = root.morphs.get(i);
            if (m.phase !== "morph" || m.addr)
                continue;
            if (now - m.born > root.holdTimeoutMs)
                root.setPhase(i, "fade"); // held goo, never claimed: bow out
        }
        for (let j = root.morphs.count - 1; j >= 0; j--) {
            if (now - root.morphs.get(j).born > 8000)
                root.finish(j);
        }
    }
}

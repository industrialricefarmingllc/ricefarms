#include "GooMorph.hpp"
#include "GooConfig.hpp"
#include "GooPass.hpp"
#include "GooTransition.hpp"

#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <string>
#include <tuple>
#include <unordered_map>
#include <vector>

namespace goo {

namespace {

CFunctionHook* G_ROUND = nullptr;
void* G_HANDLE = nullptr;

TransitionManager G_MGR;
std::unordered_map<MONITORID, WORKSPACEID>     G_LASTACTIVE;
std::unordered_map<WORKSPACEID, PHLWORKSPACEREF> G_WSREFS;
std::unordered_map<MONITORID, int>             G_DBGCOUNT;
// Frozen per-transition ranks: (monitor, old, new, window) -> rank01, fixed
// at first sight. Participant sets can shift mid-flight (popups, background
// apps mapping); recomputing rank from the live set would teleport localT.
// Frozen ranks make mid-flight timing strictly monotonic.
std::map<std::tuple<MONITORID, WORKSPACEID, WORKSPACEID, const void*>, double> G_RANKS;
void clearRanks(MONITORID mon) {
    for (auto it = G_RANKS.begin(); it != G_RANKS.end();) {
        if (std::get<0>(it->first) == mon)
            it = G_RANKS.erase(it);
        else
            ++it;
    }
}
// This frame's outgoing morphed rects per monitor (global logical px),
// drained by the tip element at POST_WINDOWS.
std::unordered_map<MONITORID, std::vector<SMorphTip>> G_TIPS;

CHyprSignalListener G_WS_LISTEN;
CHyprSignalListener G_STAGE_LISTEN;
void finishMon(MONITORID mon);
// Sustain heartbeat: native slide (which schedules frames via its own tick)
// ends at ~400ms, but per-window durations run to duration+spread (900ms).
// Frame-driven damage alone starves past the native end: the animation
// freezes mid-flight showing restored values, and a later random frame
// finishes it = visible "jump to final". This event-loop timer (independent
// of frames) damages transitioning monitors and expires finished ones until
// none remain, then disarms. Hard expiry (total+1s) bounds everything.
SP<CEventLoopTimer> G_SUSTAIN;
void sustainTick();
double totalDurationMs() {
    return (double)getFloat(Key::DURATION_MS, 400.0f) + (double)getFloat(Key::DUR_SPREAD, 500.0f);
}
void sustainTick() {
    bool any = false;
    for (auto& [monId, mon] : G_MGR.liveMonitors()) {
        any = true;
        g_pHyprRenderer->damageMonitor(mon);
        const auto* tr = G_MGR.get(monId);
        const double total = totalDurationMs();
        auto         tOpt  = G_MGR.progress(monId, total);
        const bool   done  = (tOpt && *tOpt >= 1.0);
        bool         stale = false;
        if (tr) {
            const double ageMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tr->t0).count();
            stale              = ageMs > total + 1000.0;
        }
        if (done || stale || !tr)
            finishMon(monId);
    }
    if (G_SUSTAIN) {
        if (any)
            G_SUSTAIN->updateTimeout(std::chrono::milliseconds(32));
        else
            G_SUSTAIN->updateTimeout(std::nullopt);
    }
}
void armSustain() {
    if (!G_SUSTAIN) {
        G_SUSTAIN = makeShared<CEventLoopTimer>(
            std::nullopt, [](SP<CEventLoopTimer>, void*) { sustainTick(); }, nullptr);
        if (g_pEventLoopManager)
            g_pEventLoopManager->addTimer(G_SUSTAIN);
    }
    if (G_SUSTAIN)
        G_SUSTAIN->updateTimeout(std::chrono::milliseconds(32));
}
// In-flight warps, keyed by shared ownership (a window closed mid-transition
// stays alive until POST drains its entry — restore never dangles). Warps
// persist from the render hook to RENDER_POST of the same frame: the
// renderer's surface elements sample window geometry AFTER the hook returns,
// so immediate restore would un-warp before the draw (content unscaled,
// top-left-anchored frame only). POST drains unconditionally every frame, so
// nothing strands across frames. Safe against the 0.0-cull trap: fade floor
// is 0.02, windows always render, hooks always run, POST always drains.
struct WindowPtrHash {
    size_t operator()(const PHLWINDOW& w) const noexcept {
        return std::hash<const void*>{}(static_cast<const void*>(w.get()));
    }
};
struct WindowPtrEq {
    bool operator()(const PHLWINDOW& a, const PHLWINDOW& b) const noexcept { return a.get() == b.get(); }
};
std::unordered_map<PHLWINDOW, SMorphSave, WindowPtrHash, WindowPtrEq> G_SAVES;

using RoundingFn = float (*)(Desktop::View::CWindow*);
RoundingFn g_roundOrig = nullptr;

// Debug log: ~/.cache/hypr-goo-workspaces/debug.log — begins, throttled
// per-window role/warp samples, finishes. Size-capped; never throws.
void dbgLog(const std::string& msg) {
    try {
        const char* home = std::getenv("HOME");
        if (!home || !*home)
            return;
        const std::string dir = std::string(home) + "/.cache/hypr-goo-workspaces";
        std::error_code ec;
        std::filesystem::create_directories(dir, ec);
        const std::string path = dir + "/debug.log";
        if (std::filesystem::file_size(path, ec) > 256 * 1024)
            std::filesystem::remove(path, ec);
        std::ofstream f(path, std::ios::app);
        if (!f)
            return;
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
        f << "[" << ms << "] " << msg << "\n";
    } catch (...) {}
}

struct SDirRes {
    int  side     = 1; // +1: new enters from right/bottom, -1: left/top
    bool vertical = false;
};

SDirRes resolveDirection(WORKSPACEID oldId, WORKSPACEID newId, PHLMONITOR oldMon, PHLMONITOR newMon) {
    const std::string mode = getString(Key::DIRECTION, "auto");
    if (mode == "left" || mode == "backward")
        return {-1, false};
    if (mode == "right" || mode == "forward")
        return {1, false};
    if (mode == "up")
        return {-1, true};
    if (mode == "down")
        return {1, true};
    // auto:
    // 1. cross-monitor jump: aim along the physical monitor offset, so the
    //    morph heads for the real edge between the screens.
    if (oldMon && newMon && oldMon != newMon) {
        const Vector2D oc = oldMon->m_position + oldMon->m_size / 2.0;
        const Vector2D nc = newMon->m_position + newMon->m_size / 2.0;
        const double dx   = nc.x - oc.x, dy = nc.y - oc.y;
        if (std::abs(dx) >= std::abs(dy))
            return {dx >= 0 ? 1 : -1, false};
        return {dy >= 0 ? 1 : -1, true};
    }
    // 2. same monitor, workspace grid rows of 10 (1-9, 11-19, 21-29, ...):
    //    row jumps are vertical moves, in-row jumps horizontal.
    const long long diff = (long long)newId - (long long)oldId;
    if (diff != 0 && diff % 10 == 0)
        return {diff > 0 ? 1 : -1, true};
    // 3. legacy vertical override, else horizontal by ID order.
    if (getInt(Key::VERTICAL, 0) != 0)
        return {newId >= oldId ? 1 : -1, true};
    return {(newId >= oldId) ? 1 : -1, false};
}

// Restore + drop one monitor's in-flight warps (or all when
// MONITOR_INVALID). Called from RENDER_POST (every frame, unconditional) and
// finish paths. Writes are guarded: a window whose values already match is
// left alone (no animvar churn, no damage storms).
void restoreSaves(MONITORID mon) {
    for (auto it = G_SAVES.begin(); it != G_SAVES.end();) {
        if (mon != MONITOR_INVALID && it->second.mon != mon) {
            ++it;
            continue;
        }
        PHLWINDOW w = it->first;
        if (w.get()) {
            auto& posVar  = w->positionAnimation();
            auto& sizeVar = w->sizeAnimation();
            if (posVar && posVar->value() != it->second.pos)
                posVar->setValueAndWarp(it->second.pos);
            if (sizeVar && sizeVar->value() != it->second.size)
                sizeVar->setValueAndWarp(it->second.size);
            if (it->second.alphaWarped) {
                auto& aVar = w->alpha(Desktop::View::WINDOW_ALPHA_MOVE_FROM_WORKSPACE);
                if (aVar && aVar->value() != it->second.alphaFrom)
                    aVar->setValueAndWarp(it->second.alphaFrom);
            }
            // Stretch flag rides with the rest: read at element-draw time
            // (after the hook), so it must persist exactly like geometry.
            if (it->second.warped && w->m_animatingIn != it->second.wasAnimatingIn)
                w->m_animatingIn = it->second.wasAnimatingIn;
        }
        it = G_SAVES.erase(it);
    }
}
// finish() + drop pending tip rects: a released transition must never paint
// again (stale rects would ghost under the next transition). In-flight warps
// are POST-drained regardless; finishMon only drops transition state + tips.
void finishMon(MONITORID mon) {
    PHLMONITOR m;
    if (const auto* tr = G_MGR.get(mon))
        m = tr->mon.lock();
    G_MGR.finish(mon);
    clearRanks(mon);
    G_TIPS.erase(mon);
    // Final repaint insurance: unpinning changes what renders; never leave
    // the last morphed pixels to a random future frame.
    if (m)
        g_pHyprRenderer->damageMonitor(m);
}

void onWorkspaceActive(PHLWORKSPACE ws) {
    if (!ws || ws->m_isSpecialWorkspace)
        return;
    auto mon = ws->m_monitor.lock();
    if (!mon)
        return;
    const MONITORID monId   = mon->m_id;
    const WORKSPACEID newId = ws->m_id;

    G_WSREFS[newId] = ws;

    const auto it = G_LASTACTIVE.find(monId);
    const WORKSPACEID oldId = it == G_LASTACTIVE.end() ? WORKSPACE_INVALID : it->second;
    G_LASTACTIVE[monId]     = newId;

    if (oldId == WORKSPACE_INVALID || oldId == newId)
        return;
    if (getInt(Key::ENABLED, 1) == 0)
        return;

    finishMon(monId);

    PHLWORKSPACE oldWs;
    if (auto oit = G_WSREFS.find(oldId); oit != G_WSREFS.end()) {
        if (auto locked = oit->second.lock(); locked && !locked->inert())
            oldWs = locked;
    }

    PHLMONITOR oldMon;
    if (oldWs)
        oldMon = oldWs->m_monitor.lock();
    const SDirRes dir = resolveDirection(oldId, newId, oldMon, mon);
    G_MGR.begin(monId, oldId, newId, dir.side, dir.vertical, oldWs, ws, mon);
    clearRanks(monId); // new transition, new ranks (stale ones would teleport timing)
    armSustain();
    G_DBGCOUNT[monId] = 0;

    if (oldWs)
        oldWs->m_forceRendering = true;

    char buf[256];
    std::snprintf(buf, sizeof(buf), "begin mon=%lld old=%lld new=%lld side=%d %s oldWs=%p newWs=%p", (long long)monId, (long long)oldId,
                  (long long)newId, dir.side, dir.vertical ? "vert" : "horiz", (void*)oldWs.get(), (void*)ws.get());
    dbgLog(buf);

    g_pHyprRenderer->damageMonitor(mon);
}

void onRenderStage(eRenderStage stage) {
    // End-of-frame drain: every warp created this frame is restored and
    // dropped here, unconditionally (morph on or off, idle or mid-flight).
    // Animvar writes need no GL context, so RENDER_POST is fine. Throttled
    // probe proves emission in the debug log.
    if (stage == RENDER_POST) {
        const size_t n = G_SAVES.size();
        restoreSaves(MONITOR_INVALID);
        if (n > 0) {
            static int logged = 0;
            if (logged < 10) {
                ++logged;
                char buf[128];
                std::snprintf(buf, sizeof(buf), "post-restore drained n=%zu", n);
                dbgLog(buf);
            }
        }
        return;
    }
    if (stage != RENDER_POST_WINDOWS)
        return;
    if (getInt(Key::ENABLED, 1) == 0 || g_pHyprRenderer->m_bRenderingSnapshot)
        return;
    const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
    if (!mon || mon->isMirror())
        return;
    const auto* tr = G_MGR.get(mon->m_id);
    if (!tr || tr->finished)
        return;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CGooPassElement>(&G_MGR, mon->m_id, tr->side, tr->vertical));
    // Droplet tip: same slot, independent switch. takeTips drains the store
    // so a skipped frame can't replay stale rects.
    if (getInt(Key::TIP_ENABLE, 1) != 0) {
        auto tips = takeTips(mon->m_id);
        if (!tips.empty())
            g_pHyprRenderer->m_renderPass.add(makeUnique<CGooTipElement>(&G_MGR, mon->m_id, tr->side, tr->vertical, std::move(tips)));
    }
}

float hkGooRounding(Desktop::View::CWindow* self) {
    const float base = g_roundOrig ? g_roundOrig(self) : 0.0f;
    if (!self || getInt(Key::ENABLED, 1) == 0)
        return base;
    const float droplet = getFloat(Key::DROPLET, 0.0f);
    if (!(droplet > 0.0f) || self->m_pinned || self->onSpecialWorkspace())
        return base;
    const MONITORID monId = self->monitorID();
    const auto* tr        = G_MGR.get(monId);
    if (!tr || tr->finished)
        return base;
    if (G_MGR.roleFor(monId, self->workspaceID(), self->m_workspace) == Role::NONE)
        return base;
    // Full transition length: base duration + per-window spread (slowest).
    const double dur = totalDurationMs();
    auto tOpt        = G_MGR.progress(monId, dur);
    if (!tOpt)
        return base;
    const double t = *tOpt;
    if (t <= 0.0)
        return base;
    if (t >= 1.0) {
        finishMon(monId);
        return base;
    }
    return base + droplet * (float)std::sin(3.14159265358979323846 * t);
}

} // namespace

void initMorph(void* handle) {
    G_HANDLE = handle;
    registerConfig(handle);

    G_WS_LISTEN    = Event::bus()->m_events.workspace.active.listen(onWorkspaceActive);
    G_STAGE_LISTEN = Event::bus()->m_events.render.stage.listen(onRenderStage);

    for (const auto& match : HyprlandAPI::findFunctionsByName(handle, "rounding")) {
        if (!(match.demangled.contains("rounding") && match.demangled.contains("CWindow")))
            continue;
        if (match.demangled.contains("roundingPower"))
            continue;
        G_ROUND = HyprlandAPI::createFunctionHook(handle, match.address, (void*)hkGooRounding);
        if (G_ROUND && G_ROUND->hook()) {
            g_roundOrig = reinterpret_cast<RoundingFn>(G_ROUND->m_original);
            break;
        }
        G_ROUND = nullptr;
    }
    if (!g_roundOrig)
        HyprlandAPI::addNotification(handle, "[gooworkspaces] rounding hook failed — droplet rounding off", CHyprColor{1, 0.2, 0.2, 1},
                                     5000);
}

void exitMorph() {
    G_WS_LISTEN.reset();
    G_STAGE_LISTEN.reset();
    if (G_ROUND && G_HANDLE) {
        HyprlandAPI::removeFunctionHook(G_HANDLE, G_ROUND);
        G_ROUND = nullptr;
    }
    g_roundOrig = nullptr;
    G_HANDLE    = nullptr;
    if (G_SUSTAIN) {
        G_SUSTAIN->updateTimeout(std::nullopt);
        G_SUSTAIN.reset();
    }
    for (const auto& [monId, _] : G_LASTACTIVE)
        finishMon(monId);
    G_LASTACTIVE.clear();
    G_WSREFS.clear();
    G_DBGCOUNT.clear();
    G_TIPS.clear();
}

SMorphSave beginWindowMorph(PHLWINDOW window, PHLMONITOR monitor, bool ignorePosition, bool standalone) {
    SMorphSave save;
    if (!window || !monitor || g_pHyprRenderer->m_bRenderingSnapshot)
        return save;
    // Self-heal FIRST (before every gate incl. ENABLED/role): the move-from
    // channel is exclusively ours (native resets it on map and never drives
    // it on switches), so a window rendering with it off 1.0 AND no live map
    // entry is holding poison — force it back. (With a live entry, the
    // restore-first below handles it.) Guarded write: zero churn steady.
    // Snapshots above stay excluded (never inject morph into captures).
    {
        auto& av = window->alpha(Desktop::View::WINDOW_ALPHA_MOVE_FROM_WORKSPACE);
        if (av && av->value() != 1.0f && G_SAVES.find(window) == G_SAVES.end())
            av->setValueAndWarp(1.0f);
    }
    if (ignorePosition || standalone)
        return save;
    if (getInt(Key::ENABLED, 1) == 0)
        return save;

    const MONITORID monId = monitor->m_id;

    // Lazy seeding: every monitor renders continuously, so by the time the
    // user switches workspaces this is long populated.
    if (!G_LASTACTIVE.contains(monId))
        G_LASTACTIVE[monId] = monitor->activeWorkspaceID();
    if (window->m_workspace) {
        const WORKSPACEID wid = window->workspaceID();
        auto it               = G_WSREFS.find(wid);
        if (it == G_WSREFS.end() || it->second.expired())
            G_WSREFS[wid] = window->m_workspace;
    }

    const auto* tr = G_MGR.get(monId);
    if (!tr)
        return save;
    if (tr->finished) {
        finishMon(monId); // lazy release if nothing else got there first
        return save;
    }

    // Progress FIRST (before the role gate): any window observed on a live
    // transition advances time, and expiry finishes here. A transition can
    // therefore never leak its force-render flag, even if no window matches
    // a role or the tick never fires (tick is gated on native animations).
    // Full length (slowest window): base duration + per-window spread.
    const double dur = totalDurationMs();
    auto tOpt        = G_MGR.progress(monId, dur);
    if (!tOpt)
        return save;
    const double t = *tOpt;
    if (t >= 1.0) {
        finishMon(monId);
        return save;
    }

    // Pinned/sticky and special-workspace windows stay put.
    if (window->m_pinned || (window->m_workspace && window->m_workspace->m_isSpecialWorkspace))
        return save;

    const Role role = G_MGR.roleFor(monId, window->workspaceID(), window->m_workspace);
    // Self-cleaning: a window with no transition role has no legitimate
    // reason to sit off 1.0 on the move-from channel (only this morph writes
    // it, and native resets it on map) — yet a poisoned capture + drained
    // entry can self-perpetuate 0.0 forever (each visit re-poisons from the
    // stuck value). Force it back; write only on deviation (no churn).
    if (role == Role::NONE) {
        auto& av = window->alpha(Desktop::View::WINDOW_ALPHA_MOVE_FROM_WORKSPACE);
        if (av && av->value() != 1.0f)
            av->setValueAndWarp(1.0f);
        auto& n = G_DBGCOUNT[monId];
        if (n < 6) {
            n++;
            char buf[256];
            std::snprintf(buf, sizeof(buf), "roleNONE mon=%lld winWs=%lld winWsPtr=%p tr(old=%lld new=%lld) class=%s", (long long)monId,
                          (long long)window->workspaceID(), (void*)window->m_workspace.get(), (long long)tr->oldId, (long long)tr->newId,
                          window->m_class.c_str());
            dbgLog(buf);
        }
        return save;
    }

    const bool vertical = tr->vertical;
    const double monLen = vertical ? monitor->m_size.y : monitor->m_size.x;
    if (!(monLen > 0.0))
        return save;

    auto& posVar  = window->positionAnimation();
    auto& sizeVar = window->sizeAnimation();
    if (!posVar || !sizeVar)
        return save;

    // Restore-first: this window may already be warped by an earlier pass of
    // the SAME frame (MAIN then POPUP) — restore clean first so warps never
    // compound, then compute fresh below. Guarded (map hit only).
    if (auto sit = G_SAVES.find(window); sit != G_SAVES.end()) {
        posVar->setValueAndWarp(sit->second.pos);
        sizeVar->setValueAndWarp(sit->second.size);
        if (sit->second.alphaWarped) {
            auto& aVar = window->alpha(Desktop::View::WINDOW_ALPHA_MOVE_FROM_WORKSPACE);
            if (aVar)
                aVar->setValueAndWarp(sit->second.alphaFrom);
        }
    }
    const Vector2D origPos  = posVar->value();
    const Vector2D origSize = sizeVar->value();
    if (!(origSize.x > 1.0) || !(origSize.y > 1.0))
        return save;

    // Rank-spread stagger: enumerate this transition's participants (same
    // gates as the warp below), sort by address (stable within the
    // transition), rank 0..1 — full-spread delays for ANY window count, so
    // two windows always split ~85% of the reserve instead of hash-colliding
    // into lag-or-nothing. Creation order usually puts the focused window
    // first, so it leads rather than lags.
    double rank01 = 0.0;
    const void* self = static_cast<const void*>(window.get());
    const auto rankKey = std::make_tuple(monId, tr->oldId, tr->newId, self);
    if (auto rit = G_RANKS.find(rankKey); rit != G_RANKS.end()) {
        rank01 = rit->second; // frozen: mid-flight set shifts can't teleport timing
    } else {
        std::vector<const void*> parts;
        for (auto const& w : Desktop::windowState()->windows()) {
            if (!w || w->m_pinned || (w->m_workspace && w->m_workspace->m_isSpecialWorkspace))
                continue;
            if (G_MGR.roleFor(monId, w->workspaceID(), w->m_workspace) == Role::NONE)
                continue;
            parts.push_back(static_cast<const void*>(w.get()));
        }
        std::sort(parts.begin(), parts.end());
        size_t idx = 0;
        for (; idx < parts.size() && parts[idx] != self; ++idx)
            ;
        const size_t denom = parts.size() > 1 ? parts.size() - 1 : 1;
        rank01             = (double)(idx < parts.size() ? idx : 0) / (double)denom;
        G_RANKS[rankKey]   = rank01;
    }
    const Vector2D center = origPos + origSize / 2.0;
    const double localT = jitteredT(t, rank01, static_cast<const void*>(window.get()), (long long)tr->oldId, (long long)tr->newId);

    Transform trf = G_MGR.transformFor(role, localT, monLen, tr->side, tr->vertical);
    // Genie suck: migrate the scale anchor toward the edge-center point P so
    // the window quad itself converges there — outgoing shrinks INTO P
    // (leading edge arrives first), incoming grows OUT OF P. No extra pixels
    // are drawn, so this cannot ghost. e2 eases across the whole transition.
    {
        const double pull = (double)getFloat(Key::GENIE_PULL, 1.0f);
        if (pull > 0.0) {
            double de = localT;
            if (de < 0.0)
                de = 0.0;
            if (de > 1.0)
                de = 1.0;
            de *= de * (3.0 - 2.0 * de);
            const Vector2D P = edgeCenterPoint(monitor->m_position, monitor->m_size, tr->side, tr->vertical);
            const double k   = role == Role::OUTGOING ? pull * de : pull * (1.0 - de);
            const Vector2D suck = (P - center) * k;
            trf.anchorShift.x += suck.x;
            trf.anchorShift.y += suck.y;
        }
    }
    const Vector2D anchor  = center + trf.anchorShift;
    const Vector2D newSize = {origSize.x * trf.scaleX, origSize.y * trf.scaleY};
    const Vector2D newPos  = anchor - newSize / 2.0 + trf.offset;

    auto& n = G_DBGCOUNT[monId];
    if (n < 2000) { // uncapped for jump forensics: full transition incl. END
        n++;
        char buf[256];
        std::snprintf(buf, sizeof(buf), "role%c mon=%lld winWs=%lld t=%.2f off=(%.0f,%.0f) sc=(%.2f,%.2f) a=%.2f class=%s",
                      role == Role::INCOMING ? 'I' : 'O', (long long)monId, (long long)window->workspaceID(), localT, trf.offset.x,
                      trf.offset.y, trf.scaleX, trf.scaleY, trf.alpha, window->m_class.c_str());
        dbgLog(buf);
    }

    save.pos    = origPos;
    save.size   = origSize;
    save.mon    = monId;
    save.warped = true;
    // Content stretch: upstream's UV path crops a sub-full-size box 1:1
    // UNLESS m_animatingIn (their FIXME: "probably do this for in anims on
    // all views"). A workspace grow IS an in-animation: set the flag so the
    // full buffer stretches into the warped box (content scales, centered),
    // restored synchronously below — same hook call, cannot strand.
    save.wasAnimatingIn    = window->m_animatingIn;
    window->m_animatingIn  = true;
    posVar->setValueAndWarp(newPos);
    sizeVar->setValueAndWarp(newSize);
    // Persist to RENDER_POST (same frame): surface elements sample window
    // geometry AFTER the hook returns, so immediate restore would un-warp
    // before the draw (frame-only scale, unscaled content). POST drains
    // unconditionally, so nothing strands across frames.
    // Outgoing dim 1.0 -> fade_out_min on the upstream move-from-workspace
    // channel (the designated alpha layer for exactly this).
    if (role == Role::OUTGOING) {
        auto& aVar = window->alpha(Desktop::View::WINDOW_ALPHA_MOVE_FROM_WORKSPACE);
        if (aVar) {
            save.alphaFrom   = aVar->value();
            aVar->setValueAndWarp((float)trf.alpha);
            save.alphaWarped = true;
        }
    }
    G_SAVES[window] = save;

    // Morphing rects feed the funnel pass (POST_WINDOWS). Dedupe: a window
    // renders in several passes per frame; same box twice is one entry.
    // Outgoing AND incoming both record (leading/trailing points + emergence).
    {
        bool dup = false;
        for (const auto& e : G_TIPS[monId]) {
            if (std::abs(e.box.x - newPos.x) < 1.0 && std::abs(e.box.y - newPos.y) < 1.0 && std::abs(e.box.w - newSize.x) < 1.0 &&
                std::abs(e.box.h - newSize.y) < 1.0) {
                dup = true;
                break;
            }
        }
        if (!dup)
            G_TIPS[monId].push_back(SMorphTip{CBox{newPos.x, newPos.y, newSize.x, newSize.y}, tr->side, vertical, role});
    }

    // Self-sustaining frames until expiry (tick can't be relied on: it only
    // fires while native animations run).
    g_pHyprRenderer->damageMonitor(monitor);
    return save;
}

void endWindowMorph(PHLWINDOW window, const SMorphSave& save) {
    // Intentional no-op: surface elements sample geometry, alpha AND the
    // stretch flag AFTER this hook returns (their draws execute when the
    // pass submits, not when queued) — restoring here would un-warp before
    // the draw. Everything persists to RENDER_POST of the same frame, which
    // restores + drops it all: bounded per frame, nothing strands.
    (void)window;
    (void)save;
}

std::vector<SMorphTip> takeTips(MONITORID mon) {
    auto it = G_TIPS.find(mon);
    if (it == G_TIPS.end())
        return {};
    auto out = std::move(it->second);
    G_TIPS.erase(it);
    return out;
}

} // namespace goo

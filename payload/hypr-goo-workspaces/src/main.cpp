// hypr-goo-workspaces: gooey/liquid workspace-switch window animations.
//
// Outgoing windows stretch toward the side the new workspace enters from
// (ainalem "Gooey radio buttons" morph); incoming windows grow from a
// condensed blob with wobble + overshoot (konstantindenerz "Blob Switch").
// See README.md for the full reference mapping and config docs.
//
// Mechanism: on workspace.active we open a per-monitor transition and pin
// the outgoing workspace with m_forceRendering so its windows still reach
// renderWindow. The renderWindow hook then temporarily warps each
// participating window's position/size animvars around the original call
// (setValueAndWarp => no fighting with the layout's own animation goals)
// and restores them immediately after. A tick listener damages participating
// monitors every frame until the transition ends.

#include "Config.hpp"
#include "GooPass.hpp"
#include "GooTransition.hpp"

#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/helpers/memory/Memory.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/Renderer.hpp>

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

#define GOO_NAME    "hypr-goo-workspaces"
#define GOO_DESC    "Gooey workspace-switch window animations (blob morph out, blob grow in)"
#define GOO_AUTHOR  "Lucid"
#define GOO_VERSION "0.3.0"

HANDLE         PHANDLE = nullptr;
CFunctionHook* G_HOOK  = nullptr;
CFunctionHook* G_HOOK_ROUND = nullptr;

goo::TransitionManager G_MGR;
// Last active workspace id per monitor, seeded lazily from events (the first
// switch after (re)load only records state, it doesn't animate).
std::unordered_map<MONITORID, WORKSPACEID>   G_LASTACTIVE;
std::unordered_map<WORKSPACEID, PHLWORKSPACEREF> G_WSREFS;

CHyprSignalListener G_LISTEN_WS;
CHyprSignalListener G_LISTEN_TICK;
CHyprSignalListener G_LISTEN_STAGE;

// Debug log: ~/.cache/hypr-goo-workspaces/debug.log — transition begins,
// throttled per-window role samples (the mismatch revealer), finishes.
// Size-capped; never throws.
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

std::unordered_map<MONITORID, int> G_DBGCOUNT; // role samples logged per transition

using RenderWindowFn = void (*)(Render::IHyprRenderer*, PHLWINDOW, PHLMONITOR, const Time::steady_tp&, bool, Render::eRenderPassMode, bool,
                                bool);
RenderWindowFn g_originalRenderWindow = nullptr;

using RoundingFn = float (*)(Desktop::View::CWindow*);
RoundingFn g_originalRounding = nullptr;

// Droplet rounding: participating windows gain extra corner rounding peaking
// mid-transition (leading-edge-rounds-first feel, like a droplet). Purely
// visual — rounding() feeds rendering, not layout or input.
float hkRounding(Desktop::View::CWindow* self) {
    const float base = g_originalRounding ? g_originalRounding(self) : 0.0f;
    if (!self || goo::getInt(goo::Key::ENABLED, 1) == 0)
        return base;
    const float droplet = goo::getFloat(goo::Key::DROPLET, 28.0f);
    if (!(droplet > 0.0f) || self->m_pinned || self->onSpecialWorkspace())
        return base;
    const MONITORID monId = self->monitorID();
    const auto* tr        = G_MGR.get(monId);
    if (!tr || tr->finished)
        return base;
    if (G_MGR.roleFor(monId, self->workspaceID(), self->m_workspace) == goo::Role::NONE)
        return base;
    const double dur = (double)goo::getFloat(goo::Key::DURATION_MS, 550.0f);
    auto tOpt        = G_MGR.progress(monId, dur);
    if (!tOpt)
        return base;
    const double t = *tOpt;
    if (t <= 0.0 || t >= 1.0)
        return base;
    return base + droplet * (float)std::sin(3.14159265358979323846 * t);
}

// Screen-space goo insertion: exactly one POST_WINDOWS per monitor render,
// after all workspace windows but before top/overlay layers and the cursor.
void onRenderStage(eRenderStage stage) {
    if (stage != RENDER_POST_WINDOWS)
        return;
    if (goo::getInt(goo::Key::ENABLED, 1) == 0 || g_pHyprRenderer->m_bRenderingSnapshot)
        return;
    if (goo::getFloat(goo::Key::GOO_STRENGTH, 0.4f) <= 0.0f)
        return;
    const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
    if (!mon || mon->isMirror())
        return;
    const auto* tr = G_MGR.get(mon->m_id);
    if (!tr || tr->finished)
        return;
    const bool vertical = goo::getInt(goo::Key::VERTICAL, 0) != 0;
    g_pHyprRenderer->m_renderPass.add(makeUnique<goo::CGooPassElement>(&G_MGR, mon->m_id, tr->side, vertical));
}

int resolveSide(WORKSPACEID oldId, WORKSPACEID newId) {
    const std::string mode = goo::getString(goo::Key::DIRECTION, "auto");
    if (mode == "forward")
        return 1;
    if (mode == "backward")
        return -1;
    // auto: higher id => new workspace enters from the right/bottom.
    return (newId >= oldId) ? 1 : -1;
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
        return; // first sighting or re-activation: nothing to morph
    if (goo::getInt(goo::Key::ENABLED, 1) == 0)
        return;

    // A new switch mid-transition retargets: release the previous outgoing
    // workspace first so it isn't force-rendered forever.
    G_MGR.finish(monId);

    PHLWORKSPACE oldWs;
    if (auto oit = G_WSREFS.find(oldId); oit != G_WSREFS.end()) {
        if (auto locked = oit->second.lock(); locked && !locked->inert())
            oldWs = locked;
    }

    const int side = resolveSide(oldId, newId);
    G_MGR.begin(monId, oldId, newId, side, oldWs, ws, mon);
    G_DBGCOUNT[monId] = 0;

    if (oldWs)
        oldWs->m_forceRendering = true;

    {
        char buf[256];
        std::snprintf(buf, sizeof(buf), "begin mon=%lld old=%lld new=%lld side=%d oldWs=%p newWs=%p", (long long)monId, (long long)oldId,
                      (long long)newId, side, (void*)oldWs.get(), (void*)ws.get());
        dbgLog(buf);
    }

    g_pHyprRenderer->damageMonitor(mon);
}

void onTick() {
    if (goo::getInt(goo::Key::ENABLED, 1) == 0)
        return;
    const double dur = (double)goo::getFloat(goo::Key::DURATION_MS, 550.0f);
    // Drive time + damage; the renderWindow hook does the morphing.
    // Collect monitor ids first: finish() mutates manager state.
    std::vector<MONITORID> mons;
    for (const auto& [monId, _] : G_LASTACTIVE)
        mons.push_back(monId);
    for (const MONITORID monId : mons) {
        const auto* tr = G_MGR.get(monId);
        if (!tr)
            continue;
        if (tr->finished) {
            G_MGR.finish(monId);
            continue;
        }
        auto t = G_MGR.progress(monId, dur);
        if (auto m = tr->mon.lock())
            g_pHyprRenderer->damageMonitor(m);
        if (t && *t >= 1.0) {
            G_MGR.finish(monId);
            char buf[128];
            std::snprintf(buf, sizeof(buf), "finish mon=%lld (tick)", (long long)monId);
            dbgLog(buf);
        }
    }
}

void hkRenderWindow(Render::IHyprRenderer* self, PHLWINDOW window, PHLMONITOR monitor, const Time::steady_tp& now, bool decorate,
                    Render::eRenderPassMode passMode, bool ignorePosition, bool standalone) {
    if (!g_originalRenderWindow)
        return;

    const bool enabled = goo::getInt(goo::Key::ENABLED, 1) != 0;
    if (!enabled || !window || !monitor || g_pHyprRenderer->m_bRenderingSnapshot) {
        g_originalRenderWindow(self, window, monitor, now, decorate, passMode, ignorePosition, standalone);
        return;
    }

    const MONITORID monId = monitor->m_id;

    // Lazy seeding: every monitor renders continuously, so by the time the
    // user switches workspaces this is long populated — the first switch
    // after (re)load animates fully. Workspace objects are harvested from
    // live windows for the same reason (feeds the outgoing force-render).
    if (!G_LASTACTIVE.contains(monId))
        G_LASTACTIVE[monId] = monitor->activeWorkspaceID();
    if (window->m_workspace) {
        const WORKSPACEID wid = window->workspaceID();
        auto it               = G_WSREFS.find(wid);
        if (it == G_WSREFS.end() || it->second.expired())
            G_WSREFS[wid] = window->m_workspace;
    }

    const auto* tr        = G_MGR.get(monId);
    if (!tr || tr->finished) {
        if (tr && tr->finished)
            G_MGR.finish(monId); // lazy release if tick hasn't run yet
        g_originalRenderWindow(self, window, monitor, now, decorate, passMode, ignorePosition, standalone);
        return;
    }

    // Pinned/sticky and special-workspace windows stay put: they don't
    // conceptually leave or enter.
    if (window->m_pinned || (window->m_workspace && window->m_workspace->m_isSpecialWorkspace)) {
        g_originalRenderWindow(self, window, monitor, now, decorate, passMode, ignorePosition, standalone);
        return;
    }

    const goo::Role role = G_MGR.roleFor(monId, window->workspaceID(), window->m_workspace);
    if (role == goo::Role::NONE) {
        // Sampled: if transitions run yet every window lands here, the IDs
        // (or pointers) genuinely mismatch — the log proves it either way.
        auto& n = G_DBGCOUNT[monId];
        if (tr && n < 6) {
            n++;
            char buf[256];
            std::snprintf(buf, sizeof(buf), "roleNONE mon=%lld winWs=%lld winWsPtr=%p tr(old=%lld new=%lld) class=%s", (long long)monId,
                          (long long)window->workspaceID(), (void*)window->m_workspace.get(), (long long)tr->oldId, (long long)tr->newId,
                          window->m_class.c_str());
            dbgLog(buf);
        }
        g_originalRenderWindow(self, window, monitor, now, decorate, passMode, ignorePosition, standalone);
        return;
    }

    const double dur = (double)goo::getFloat(goo::Key::DURATION_MS, 550.0f);
    auto tOpt        = G_MGR.progress(monId, dur);
    if (!tOpt) {
        g_originalRenderWindow(self, window, monitor, now, decorate, passMode, ignorePosition, standalone);
        return;
    }
    const double t = *tOpt;
    if (t >= 1.0) {
        G_MGR.finish(monId);
        g_originalRenderWindow(self, window, monitor, now, decorate, passMode, ignorePosition, standalone);
        return;
    }

    const bool vertical = goo::getInt(goo::Key::VERTICAL, 0) != 0;
    const double monLen = vertical ? monitor->m_size.y : monitor->m_size.x;
    if (!(monLen > 0.0)) {
        g_originalRenderWindow(self, window, monitor, now, decorate, passMode, ignorePosition, standalone);
        return;
    }

    auto& posVar  = window->positionAnimation();
    auto& sizeVar = window->sizeAnimation();
    if (!posVar || !sizeVar) {
        g_originalRenderWindow(self, window, monitor, now, decorate, passMode, ignorePosition, standalone);
        return;
    }

    const Vector2D origPos  = posVar->value();
    const Vector2D origSize = sizeVar->value();
    if (!(origSize.x > 1.0) || !(origSize.y > 1.0)) {
        g_originalRenderWindow(self, window, monitor, now, decorate, passMode, ignorePosition, standalone);
        return;
    }

    // Cascade stagger: windows near the entry edge lead, far ones follow.
    // Uses the unwarped geometry (read before any modification).
    const Vector2D center   = origPos + origSize / 2.0;
    const double monMin     = vertical ? monitor->m_position.y : monitor->m_position.x;
    const double centerAx   = vertical ? center.y : center.x;
    const double localT     = goo::staggeredT(t, centerAx, monMin, monLen, tr->side);

    const goo::Transform trf = G_MGR.transformFor(role, localT, monLen, tr->side);

    // Scale about the (possibly pulled) anchor, then apply the slide offset.
    const Vector2D anchor  = center + trf.anchorShift;
    const Vector2D newSize = {origSize.x * trf.scaleX, origSize.y * trf.scaleY};
    const Vector2D newPos  = anchor - newSize / 2.0 + trf.offset;

    auto& n = G_DBGCOUNT[monId];
    if (n < 14) {
        n++;
        char buf[256];
        std::snprintf(buf, sizeof(buf), "role%c mon=%lld winWs=%lld t=%.2f off=(%.0f,%.0f) sc=(%.2f,%.2f) class=%s",
                      role == goo::Role::INCOMING ? 'I' : 'O', (long long)monId, (long long)window->workspaceID(), localT, trf.offset.x,
                      trf.offset.y, trf.scaleX, trf.scaleY, window->m_class.c_str());
        dbgLog(buf);
    }

    posVar->setValueAndWarp(newPos);
    sizeVar->setValueAndWarp(newSize);
    g_originalRenderWindow(self, window, monitor, now, decorate, passMode, ignorePosition, standalone);
    posVar->setValueAndWarp(origPos);
    sizeVar->setValueAndWarp(origSize);

    // Keep frames coming until the transition ends (tick also damages, this
    // covers tick-less paths).
    g_pHyprRenderer->damageMonitor(monitor);
}

} // namespace

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;
    goo::registerConfig(handle);

    G_LISTEN_WS    = Event::bus()->m_events.workspace.active.listen(onWorkspaceActive);
    G_LISTEN_TICK  = Event::bus()->m_events.tick.listen(onTick);
    G_LISTEN_STAGE = Event::bus()->m_events.render.stage.listen(onRenderStage);

    for (const auto& match : HyprlandAPI::findFunctionsByName(PHANDLE, "renderWindow")) {
        if (!(match.demangled.contains("renderWindow") && match.demangled.contains("IHyprRenderer")))
            continue;
        G_HOOK = HyprlandAPI::createFunctionHook(PHANDLE, match.address, (void*)hkRenderWindow);
        if (G_HOOK && G_HOOK->hook()) {
            g_originalRenderWindow = reinterpret_cast<RenderWindowFn>(G_HOOK->m_original);
            break;
        }
        G_HOOK = nullptr;
    }
    if (!g_originalRenderWindow)
        HyprlandAPI::addNotification(PHANDLE, "[gooworkspaces] renderWindow hook failed — animations disabled",
                                     CHyprColor{1, 0.2, 0.2, 1}, 5000);

    // Droplet rounding: CWindow::rounding(). Non-critical — geometry morphs
    // work without it, so failure only notifies.
    for (const auto& match : HyprlandAPI::findFunctionsByName(PHANDLE, "rounding")) {
        if (!(match.demangled.contains("rounding") && match.demangled.contains("CWindow")))
            continue;
        // Skip roundingPower and any overload with parameters: exact
        // `rounding()` takes only the implicit this.
        if (match.demangled.contains("roundingPower"))
            continue;
        G_HOOK_ROUND = HyprlandAPI::createFunctionHook(PHANDLE, match.address, (void*)hkRounding);
        if (G_HOOK_ROUND && G_HOOK_ROUND->hook()) {
            g_originalRounding = reinterpret_cast<RoundingFn>(G_HOOK_ROUND->m_original);
            break;
        }
        G_HOOK_ROUND = nullptr;
    }
    if (!g_originalRounding)
        HyprlandAPI::addNotification(PHANDLE, "[gooworkspaces] rounding hook failed — droplet rounding off",
                                     CHyprColor{1, 0.2, 0.2, 1}, 5000);

    return {GOO_NAME, GOO_DESC, GOO_AUTHOR, GOO_VERSION};
}

APICALL EXPORT void PLUGIN_EXIT() {
    G_LISTEN_WS.reset();
    G_LISTEN_TICK.reset();
    G_LISTEN_STAGE.reset();
    if (G_HOOK) {
        HyprlandAPI::removeFunctionHook(PHANDLE, G_HOOK);
        G_HOOK = nullptr;
    }
    if (G_HOOK_ROUND) {
        HyprlandAPI::removeFunctionHook(PHANDLE, G_HOOK_ROUND);
        G_HOOK_ROUND = nullptr;
    }
    g_originalRenderWindow = nullptr;
    g_originalRounding     = nullptr;
    // Release any pinned outgoing workspaces.
    for (const auto& [monId, _] : G_LASTACTIVE)
        G_MGR.finish(monId);
    G_LASTACTIVE.clear();
    G_WSREFS.clear();
}

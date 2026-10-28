// liquid-glass-hypr: real-time liquid glass for layer surfaces.
//
// Architecture: the glass is drawn inside the compositor render pass, where
// the pixels already live. Per frame, per matched layer surface:
//   region blit (0.2ms) -> half-res blur pyramid (0.5ms) -> glass quads (0.5ms)
// while the original renderLayer draws content crisply on top. Nothing is
// read back, encoded, written to disk, or re-decoded — that whole pipeline
// (previously ~150-250ms per update, ~5fps) is gone.

#include "Config.hpp"
#include "Glass.hpp"
#include "GlassPass.hpp"
#include "BorderGlass.hpp"
#include "GooMorph.hpp"
#include "WindowGlass.hpp"

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/types.hpp>

#include <memory>
#include <chrono>
#include <cmath>
#include <thread>
#include <unordered_map>

namespace {

#define LG_NAME "liquid-glass-hypr"
#define LG_DESC "Real-time liquid glass for layers + windows (in-render-pass) + gooey workspace morph"
#define LG_AUTHOR "Lucid"
#define LG_VERSION "0.8.33"

HANDLE PHANDLE = nullptr;
CFunctionHook* G_HOOK = nullptr;
CFunctionHook* G_HOOK_WIN = nullptr;
CFunctionHook* G_HOOK_RB1 = nullptr;
CFunctionHook* G_HOOK_RB2 = nullptr;
CFunctionHook* G_HOOK_SH = nullptr;
// Intentionally leaked (never freed, not even on unload): destroying GL
// objects (framebuffers, programs) outside a frame — which is exactly when
// PLUGIN_EXIT and dlclose static destructors run — SEGVs in the driver.
// Observed twice. A few MB per hot-reload is the correct trade; the OS
// reclaims everything at process exit.
auto* LAYERS = new std::unordered_map<void*, std::shared_ptr<CGlassLayer>>();
auto* WINDOWS = new std::unordered_map<void*, std::shared_ptr<CWindowGlass>>();

void pruneDead() {
    std::erase_if(*LAYERS, [](const auto& pair) { return !pair.second->get(); });
}

void pruneDeadWindows() {
    for (auto it = WINDOWS->begin(); it != WINDOWS->end();) {
        if (!it->second->get()) {
            it->second->damageLast(); // repaint before forgetting
            it = WINDOWS->erase(it);
        } else {
            ++it;
        }
    }
}

using RenderLayerFn = void (*)(Render::IHyprRenderer*, PHLLS, PHLMONITOR, const Time::steady_tp&, bool, bool);
RenderLayerFn g_originalRenderLayer = nullptr;

void hkRenderLayer(Render::IHyprRenderer* self, PHLLS surface, PHLMONITOR monitor, const Time::steady_tp& now, bool popups, bool lockscreen) {
    // Never inject into snapshots (e.g. layer fade-out captures): the
    // snapshot framebuffer starts transparent/black and the surface may be
    // half-destroyed — sampling it bakes garbage and touching its members
    // can fault (observed SEGV in namespaceAllowed via onUnmap).
    if (g_pHyprRenderer->m_bRenderingSnapshot) {
        g_originalRenderLayer(self, surface, monitor, now, popups, lockscreen);
        return;
    }

    // NOTE: elements must be added HERE (during layer rendering), not in
    // beginRender: beginRender() starts with m_renderPass.clear(), which
    // deletes anything queued before it. Elements are discardable (damage-
    // gated in render()): static frames skip all blit/blur/draw work and the
    // GPU sleeps; backdrop/tune/bounds changes damage us back as needed.
    if (!popups && surface && surface->m_mapped && lg::getInt("plugin:liquidglass:enabled", 1)
        && lg::namespaceAllowed(surface->m_namespace)) {
        pruneDead();
        auto* raw = surface.get();
        auto it = LAYERS->find(raw);
        if (it == LAYERS->end() || !it->second->get())
            it = LAYERS->emplace(raw, std::make_shared<CGlassLayer>(surface)).first;
        CGlassPassElement::SData data{it->second};
        g_pHyprRenderer->m_renderPass.add(makeUnique<CGlassPassElement>(data));
    }

    g_originalRenderLayer(self, surface, monitor, now, popups, lockscreen);
}

using RenderWindowFn = void (*)(Render::IHyprRenderer*, PHLWINDOW, PHLMONITOR, const Time::steady_tp&, bool,
                                Render::eRenderPassMode, bool, bool);
RenderWindowFn g_originalRenderWindow = nullptr;

void hkRenderWindow(Render::IHyprRenderer* self, PHLWINDOW window, PHLMONITOR monitor, const Time::steady_tp& now,
                    bool decorate, Render::eRenderPassMode passMode, bool ignorePosition, bool standalone) {
    // Same snapshot rule as layers: never inject into captures.
    if (g_pHyprRenderer->m_bRenderingSnapshot) {
        g_originalRenderWindow(self, window, monitor, now, decorate, passMode, ignorePosition, standalone);
        return;
    }

    // Workspace morph (goo): warp first so the glass snapshot below samples
    // morphed geometry and the glass follows the morph; restore last.
    // No-op unless the window participates in a live transition.
    const auto gooSave = goo::beginWindowMorph(window, monitor, ignorePosition, standalone);

    // Main passes only (ALL and MAIN; never POPUP or snapshots): the POPUP
    // pass re-renders for popups, and snapshots are excluded above.
    // Verified against the binary: renderAllClientsForWorkspace and
    // renderWorkspaceWindows call renderWindow with r9d=0 (ALL) for content
    // and r9d=2 (POPUP) for popups — MAIN-only would never fire.
    // Elements are added here (during window rendering), never in
    // beginRender — see hkRenderLayer.
    const bool mainPass = passMode == Render::RENDER_PASS_ALL || passMode == Render::RENDER_PASS_MAIN;
    const bool popupPass = passMode == Render::RENDER_PASS_POPUP;
    // Glass stays on during a goo workspace morph: beginWindowMorph() has
    // already warped the window, so snapshot() samples the morphed geometry
    // and the glass rides the same motion as the content. The shared backdrop
    // is disabled for the transition (see onWindowStage/snapshot); each glass
    // pane takes a live per-window capture instead.
    // Under-glass only, and only for translucent classes (default
    // plugin:liquidglass:windows = "kitty,zen"): the glass draws BEFORE the
    // window content, so fully opaque windows would cover it completely —
    // drawing there is pure waste and is never submitted. There is
    // deliberately NO on-top/rim overdraw pass anymore (removed): edge glass
    // over regular windows is gone entirely.
    const bool glassEnabled = lg::getInt("plugin:liquidglass:enabled", 1) != 0;
    if (mainPass && glassEnabled && window && lg::windowAllowed(window->m_class)) {
        pruneDeadWindows();
        auto* raw = window.get();
        auto it = WINDOWS->find(raw);
        if (it == WINDOWS->end() || !it->second->get())
            it = WINDOWS->emplace(raw, std::make_shared<CWindowGlass>(window)).first;
        // Geometry snapshot NOW (hook-time renderModif), pixels LATER in the
        // element (proven target space). Skips damage inside and yield null.
        if (auto draw = it->second->snapshot(monitor)) {
            CWindowGlassPassElement::SData data{it->second, *draw, false};
            g_pHyprRenderer->m_renderPass.add(makeUnique<CWindowGlassPassElement>(data));
        }
    }

    // Record the draw order for shared-backdrop eligibility. This must happen
    // after snapshot() (so a glass window never overlaps itself) and for
    // non-glass windows too (they also invalidate the pre-window backdrop).
    // Popup passes record the parent box conservatively: a menu drawn before
    // a later glass window must force that window back to a live capture
    // rather than a pre-window backdrop that predates the popup.
    if ((mainPass || popupPass) && glassEnabled && window)
        lg::noteWindowBox(window, monitor);

    // Tiling resize shrink: Hyprland's animated window path stretches the
    // stale content buffer into the smaller box, so the area leaving view is
    // visibly squeezed. m_animatingIn controls upstream's UV path: leave it
    // off for shrinking frames so the old buffer is cropped 1:1 instead.
    // Only for non-goo resizes; goo owns this flag during workspace morphs.
    bool cropShrink = false;
    bool prevAnimatingIn = false;
    if (!goo::transitioning(monitor->m_id) && window) {
        auto& sv = window->sizeAnimation();
        if (sv && sv->isBeingAnimated()) {
            const auto v = sv->value();
            const auto g = sv->goal();
            if (g.x < v.x - 0.5 || g.y < v.y - 0.5) {
                prevAnimatingIn = window->m_animatingIn;
                window->m_animatingIn = false;
                cropShrink = true;
            }
        }
    }

    g_originalRenderWindow(self, window, monitor, now, decorate, passMode, ignorePosition, standalone);
    if (cropShrink)
        window->m_animatingIn = prevAnimatingIn;
    goo::endWindowMorph(window, gooSave);
}

} // namespace

namespace lg {
// A window belongs to the frame if its workspace is the active/special one,
// or if it is being force-rendered / slid / morphed. During a goo transition
// the outgoing workspace has m_forceRendering set; those windows still draw
// and must count as shared-backdrop consumers.
static bool workspaceRenders(PHLWORKSPACE ws, PHLWORKSPACE active, PHLWORKSPACE special) {
    if (!ws)
        return false;
    if (ws == active || ws == special || ws->m_forceRendering)
        return true;
    const auto off = ws->m_renderOffset->value();
    return ws->m_renderOffset->isBeingAnimated() || ws->m_alpha->isBeingAnimated() ||
        std::abs(off.x) > 0.5 || std::abs(off.y) > 0.5 || ws->m_alpha->value() < 0.999f;
}

int windowGlassCount(PHLMONITOR monitor) {
    if (!monitor)
        return 0;
    int count = 0;
    for (const auto& [key, glass] : *WINDOWS) {
        const auto win = glass ? glass->get() : nullptr;
        if (!win || !win->m_isMapped || win->isHidden() || win->monitorID() != monitor->m_id)
            continue;
        if (!win->m_pinned &&
            !workspaceRenders(win->m_workspace, monitor->m_activeWorkspace, monitor->m_activeSpecialWorkspace))
            continue;
        if (lg::windowAllowed(win->m_class) && !win->opaque())
            ++count;
    }
    return count;
}

bool windowGlassNeedsFrame(PHLMONITOR monitor, const CBox& damage) {
    if (!monitor || damage.w <= 0 || damage.h <= 0)
        return false;
    const float scale = monitor->m_scale > 0.0f ? monitor->m_scale : 1.0f;
    const CBox dmgLogical{damage.x / scale, damage.y / scale, damage.w / scale, damage.h / scale};
    for (const auto& [key, glass] : *WINDOWS) {
        const auto win = glass ? glass->get() : nullptr;
        if (!win || !win->m_isMapped || win->isHidden() || win->monitorID() != monitor->m_id)
            continue;
        if (!win->m_pinned &&
            !workspaceRenders(win->m_workspace, monitor->m_activeWorkspace, monitor->m_activeSpecialWorkspace))
            continue;
        if (!lg::windowAllowed(win->m_class) || win->opaque())
            continue;
        if (const auto bounds = glass->glassBounds(); bounds && !bounds->intersection(dmgLogical).empty())
            return true;
    }
    return false;
}
} // namespace lg

void* lg::pluginHandle() {
    return PHANDLE;
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;
    lg::registerConfig(handle);
    goo::initMorph(handle);
    lg::initWindowFocus();

    auto matches = HyprlandAPI::findFunctionsByName(PHANDLE, "renderLayer");
    for (const auto& match : matches) {
        if (match.demangled.contains("renderLayer") && match.demangled.contains("LayerSurface")) {
            G_HOOK = HyprlandAPI::createFunctionHook(PHANDLE, match.address, (void*)hkRenderLayer);
            if (G_HOOK && G_HOOK->hook()) {
                g_originalRenderLayer = reinterpret_cast<RenderLayerFn>(G_HOOK->m_original);
                break;
            }
            G_HOOK = nullptr;
        }
    }
    if (!g_originalRenderLayer)
        HyprlandAPI::addNotification(PHANDLE, "[liquidglass] renderLayer hook failed — effect disabled", CHyprColor{1, 0.2, 0.2, 1}, 5000);

    // Full-window glass (kitty takeover): single unambiguous symbol
    // (Render::IHyprRenderer::renderWindow — Screenshare's unrelated
    // renderWindow is excluded by the IHyprRenderer match).
    for (const auto& match : HyprlandAPI::findFunctionsByName(PHANDLE, "renderWindow")) {
        if (!(match.demangled.contains("renderWindow") && match.demangled.contains("IHyprRenderer")))
            continue;
        G_HOOK_WIN = HyprlandAPI::createFunctionHook(PHANDLE, match.address, (void*)hkRenderWindow);
        if (G_HOOK_WIN && G_HOOK_WIN->hook()) {
            g_originalRenderWindow = reinterpret_cast<RenderWindowFn>(G_HOOK_WIN->m_original);
            break;
        }
        G_HOOK_WIN = nullptr;
    }
    if (!g_originalRenderWindow)
        HyprlandAPI::addNotification(PHANDLE, "[liquidglass] renderWindow hook failed — window glass disabled",
                                     CHyprColor{1, 0.2, 0.2, 1}, 5000);

    // Window borders: both renderBorder overloads. Discriminated by gradient
    // count in the demangled signature (1 vs 2 CGradientValueData params).
    // Either may fail independently — the other still replaces its case —
    // but a missing hook means flat borders for that case, so say so.
    auto rbMatches = HyprlandAPI::findFunctionsByName(PHANDLE, "renderBorder");
    for (const auto& match : rbMatches) {
        if (!match.demangled.contains("renderBorder") || !match.demangled.contains("CHyprOpenGLImpl"))
            continue;
        const std::string& d = match.demangled;
        size_t grads = 0, pos = 0;
        while ((pos = d.find("CGradientValueData", pos)) != std::string::npos) {
            grads++;
            pos += 18;
        }
        if (grads == 1 && !lg::g_origRenderBorder1) {
            G_HOOK_RB1 = HyprlandAPI::createFunctionHook(PHANDLE, match.address, (void*)lg::hkRenderBorder1);
            if (G_HOOK_RB1 && G_HOOK_RB1->hook())
                lg::g_origRenderBorder1 = reinterpret_cast<lg::RenderBorder1Fn>(G_HOOK_RB1->m_original);
            else
                G_HOOK_RB1 = nullptr;
        } else if (grads == 2 && !lg::g_origRenderBorder2) {
            G_HOOK_RB2 = HyprlandAPI::createFunctionHook(PHANDLE, match.address, (void*)lg::hkRenderBorder2);
            if (G_HOOK_RB2 && G_HOOK_RB2->hook())
                lg::g_origRenderBorder2 = reinterpret_cast<lg::RenderBorder2Fn>(G_HOOK_RB2->m_original);
            else
                G_HOOK_RB2 = nullptr;
        }
    }
    if (!lg::g_origRenderBorder1 || !lg::g_origRenderBorder2)
        HyprlandAPI::addNotification(PHANDLE, "[liquidglass] renderBorder hook failed — window borders stay flat",
                                     CHyprColor{1, 0.2, 0.2, 1}, 5000);

    // Window drop shadows: single non-overloaded decoration method.
    // NOTE: the match must be "::draw(" -- a bare "DropShadowDecoration::draw"
    // also matches drawShadowInternal (CBox, int, float, ...), which nm -D
    // lists FIRST. Hooking that one installs our (deco, PHLMONITOR, float)
    // hook on the wrong signature: monitorLive() then reads a CBox as a
    // shared_ptr, bails, and every shadow draw is dropped -> no window
    // shadows at all, ever.
    for (const auto& match : HyprlandAPI::findFunctionsByName(PHANDLE, "DropShadowDecoration")) {
        if (!match.demangled.contains("DropShadowDecoration::draw("))
            continue;
        G_HOOK_SH = HyprlandAPI::createFunctionHook(PHANDLE, match.address, (void*)lg::hkDropShadowDraw);
        if (G_HOOK_SH && G_HOOK_SH->hook())
            lg::g_origDropShadowDraw = reinterpret_cast<lg::DropShadowDrawFn>(G_HOOK_SH->m_original);
        else
            G_HOOK_SH = nullptr;
        break;
    }
    if (!lg::g_origDropShadowDraw)
        HyprlandAPI::addNotification(PHANDLE, "[liquidglass] drop-shadow hook failed — window shadows stay on",
                                     CHyprColor{1, 0.2, 0.2, 1}, 5000);

    return {LG_NAME, LG_DESC, LG_AUTHOR, LG_VERSION};
}

APICALL EXPORT void PLUGIN_EXIT() {
    // Morph first: releases outgoing workspaces + rounding hook while the
    // renderer is still up. Then the glass unhooks below.
    goo::exitMorph();
    lg::exitWindowFocus();
    // Unhook only. Everything else is intentionally leaked: freeing GL state
    // here (or in dlclose static destructors) runs without a current GL
    // context and SEGVs. See LAYERS above. A short grace lets any queued
    // pass finish before the .so is unmapped.
    if (G_HOOK) {
        HyprlandAPI::removeFunctionHook(PHANDLE, G_HOOK);
        G_HOOK = nullptr;
    }
    if (G_HOOK_WIN) {
        HyprlandAPI::removeFunctionHook(PHANDLE, G_HOOK_WIN);
        G_HOOK_WIN = nullptr;
    }
    if (G_HOOK_RB1) {
        HyprlandAPI::removeFunctionHook(PHANDLE, G_HOOK_RB1);
        G_HOOK_RB1 = nullptr;
    }
    if (G_HOOK_RB2) {
        HyprlandAPI::removeFunctionHook(PHANDLE, G_HOOK_RB2);
        G_HOOK_RB2 = nullptr;
    }
    if (G_HOOK_SH) {
        HyprlandAPI::removeFunctionHook(PHANDLE, G_HOOK_SH);
        G_HOOK_SH = nullptr;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
}

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
#include "WindowWash.hpp"
#include "WindowEink.hpp"

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/workspace/HLWorkspace.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/desktop/view/window/WindowPresentation.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/Context.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/types.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>

#include <memory>
#include <fstream>
#include <chrono>
#include <cmath>
#include <thread>
#include <unordered_map>

namespace {

#define LG_NAME "liquid-glass-hypr"
#define LG_DESC "Real-time liquid glass for layers + windows (in-render-pass) + gooey workspace morph"
#define LG_AUTHOR "Lucid"
#define LG_VERSION "0.8.36"

HANDLE PHANDLE = nullptr;
CFunctionHook* G_HOOK = nullptr;
CFunctionHook* G_HOOK_WIN = nullptr;
CFunctionHook* G_HOOK_RB1 = nullptr;
CFunctionHook* G_HOOK_RB2 = nullptr;
CFunctionHook* G_HOOK_SH = nullptr;
CFunctionHook* G_HOOK_END = nullptr;
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

CHyprSignalListener G_MOUSE_MOVE;
CHyprSignalListener G_RIM_STAGE;

// Pointer motion must rotate the rim on every glass surface, not only the one
// under the pointer. Damage the known edge bands of every tracked surface.
void damageAllGlassRims() {
    if (lg::getInt("plugin:liquidglass:rim_follow", 1) == 0)
        return;
    // Glass bodies off: tracked layers still carry the rim-only overlay, so
    // their edge bands must follow the cursor too. Window glass objects only
    // exist in full-glass mode (the renderBorder loop below covers windows).
    for (const auto& [_, layer] : *LAYERS)
        if (layer)
            layer->damageRim();
    if (lg::getInt("plugin:liquidglass:enabled", 1) != 0) {
        for (const auto& [_, glass] : *WINDOWS)
            if (glass)
                glass->damageRim();
    }

    // Opaque windows use the renderBorder rim; damage their edge bands too.
    if (lg::getInt("plugin:liquidglass:window_borders", 0) == 1
        && lg::getInt("plugin:liquidglass:rim_light", 1) == 1) {
        for (const auto& w : Desktop::windowState()->windows()) {
            if (!w || !w->mapped() || w->isHidden())
                continue;
            const Vector2D pos = w->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
            const Vector2D size = w->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
            if (size.x <= 0 || size.y <= 0)
                continue;
            const float pad = 12.0f;
            g_pHyprRenderer->damageBox(CBox{pos.x - pad, pos.y - pad, size.x + pad * 2.0f, pad});
            g_pHyprRenderer->damageBox(CBox{pos.x - pad, pos.y + size.y, size.x + pad * 2.0f, pad});
            g_pHyprRenderer->damageBox(CBox{pos.x - pad, pos.y, pad, size.y});
            g_pHyprRenderer->damageBox(CBox{pos.x + size.x, pos.y, pad, size.y});
        }
    }
}

static std::chrono::steady_clock::time_point s_lastMoveDamage{};
void onMouseMove(Vector2D, Event::SCallbackInfo&) {
    const auto now = std::chrono::steady_clock::now();
    if (s_lastMoveDamage.time_since_epoch().count() != 0 && now - s_lastMoveDamage < std::chrono::milliseconds(16))
        return;
    s_lastMoveDamage = now;
    damageAllGlassRims();
}

// The input event can be absent for some devices / consumed motions. The
// render stage always runs for the frame the cursor move scheduled; compare
// the global pointer there and damage every glass rim when it actually moved.
void onRimStage(const Event::SRenderStageEvent&) {
    if (!g_pInputManager || lg::getInt("plugin:liquidglass:rim_follow", 1) == 0)
        return;
    static Vector2D last{-1e9, -1e9};
    const Vector2D cur = g_pInputManager->getMouseCoordsInternal();
    if (!std::isfinite(cur.x) || !std::isfinite(cur.y))
        return;
    if (std::abs(cur.x - last.x) < 0.5 && std::abs(cur.y - last.y) < 0.5)
        return;
    last = cur;
    damageAllGlassRims();
}

// CHyprOpenGLImpl::end() is end(CRenderContext&): the hook must forward the
// context or the original runs on a garbage reference (SEGV in scissor()).
using EndFn = void (*)(Render::GL::CHyprOpenGLImpl*, Render::CRenderContext&);
EndFn g_originalEnd = nullptr;

void hkEnd(Render::GL::CHyprOpenGLImpl* self, Render::CRenderContext& ctx) {
    auto& rd   = ctx.m_data;
    auto  out  = rd.outFB;
    auto  main = rd.mainFB;
    auto  mon  = rd.pMonitor.lock();
    auto  damage = rd.finalDamage;
    const bool td = rd.transformDamage;
    const bool normal = ctx.m_mode == Render::RENDER_MODE_NORMAL;

    g_originalEnd(self, ctx);

    // The scene/work buffer was copied to the output above. Apply the wash
    // only to the output, so the work buffer used by glass backdrop capture
    // never contains the wash (no cross-framebuffer feedback).
    if (normal && out && mon && out.get() != main.get()) {
        lg::drawQueuedWash(mon, out, damage, td);
        // Screencopy reads the mirror, which Hyprland filled from the work
        // buffer before the screen shader and the wash. Refresh it from the
        // finished output so a saved screenshot matches the screen.
        lg::mirrorFromOutput(mon, out, damage, td);
    } else if (mon)
        lg::clearQueuedWash(mon);
}

using RenderLayerFn = void (*)(Render::IHyprRenderer*, Render::CRenderContext&, PHLLS, PHLMONITOR, const Time::steady_tp&, bool, bool, bool);
RenderLayerFn g_originalRenderLayer = nullptr;

void hkRenderLayer(Render::IHyprRenderer* self, Render::CRenderContext& ctx, PHLLS surface, PHLMONITOR monitor, const Time::steady_tp& now, bool popups, bool lockscreen, bool workspaceScene) {
    // Never inject into snapshots (e.g. layer fade-out captures): the
    // snapshot framebuffer starts transparent/black and the surface may be
    // half-destroyed — sampling it bakes garbage and touching its members
    // can fault (observed SEGV in namespaceAllowed via onUnmap).
    if (ctx.m_renderingSnapshot) {
        g_originalRenderLayer(self, ctx, surface, monitor, now, popups, lockscreen, workspaceScene);
        return;
    }

    // NOTE: elements must be added HERE (during layer rendering), not in
    // beginRender: beginRender() starts with m_renderPass.clear(), which
    // deletes anything queued before it. Elements are discardable (damage-
    // gated in render()): static frames skip all blit/blur/draw work and the
    // GPU sleeps; backdrop/tune/bounds changes damage us back as needed.
    const bool glassOn = lg::getInt("plugin:liquidglass:enabled", 1) != 0;
    const bool rimOn = lg::getInt("plugin:liquidglass:rim_light", 1) == 1
        && lg::getFloat("plugin:liquidglass:rim_strength", 1.0f) > 0.0f
        && lg::getInt("plugin:liquidglass:glass_rim", 1) == 1;
    const bool rimOnly = !glassOn && rimOn;
    std::shared_ptr<CGlassLayer> rimLayer;
    if (!popups && surface && surface->mapped() && (glassOn || rimOnly)
        && lg::namespaceAllowed(surface->m_namespace)) {
        pruneDead();
        auto* raw = surface.get();
        auto it = LAYERS->find(raw);
        if (it == LAYERS->end() || !it->second->get())
            it = LAYERS->emplace(raw, std::make_shared<CGlassLayer>(surface)).first;
        if (glassOn) {
            CGlassPassElement::SData data{it->second, CGlassPassElement::EPhase::Glass};
            ctx.m_pass.add(makeUnique<CGlassPassElement>(data));
        } else {
            // Rim-only: capture the backdrop before the content, draw the
            // rim over the content after it (see hkRenderLayer's tail).
            CGlassPassElement::SData cap{it->second, CGlassPassElement::EPhase::RimCapture};
            ctx.m_pass.add(makeUnique<CGlassPassElement>(cap));
            rimLayer = it->second;
        }
    }

    g_originalRenderLayer(self, ctx, surface, monitor, now, popups, lockscreen, workspaceScene);

    if (rimLayer) {
        CGlassPassElement::SData rim{rimLayer, CGlassPassElement::EPhase::RimDraw};
        ctx.m_pass.add(makeUnique<CGlassPassElement>(rim));
    }

    if (!popups && !lockscreen && surface && surface->mapped()) {
        if (auto wash = lg::washTexture()) {
            lg::queueLayerWash(surface, monitor);
        }
    }
}

using RenderWindowFn = void (*)(Render::IHyprRenderer*, Render::CRenderContext&, PHLWINDOW, PHLMONITOR, const Render::SWindowRenderPresentation&, const Time::steady_tp&, bool,
                                Render::eRenderPassMode, bool, bool);
RenderWindowFn g_originalRenderWindow = nullptr;

void hkRenderWindow(Render::IHyprRenderer* self, Render::CRenderContext& ctx, PHLWINDOW window, PHLMONITOR monitor, const Render::SWindowRenderPresentation& presentation, const Time::steady_tp& now,
                    bool decorate, Render::eRenderPassMode passMode, bool ignorePosition, bool standalone) {
    // Same snapshot rule as layers: never inject into captures.
    if (ctx.m_renderingSnapshot) {
        g_originalRenderWindow(self, ctx, window, monitor, presentation, now, decorate, passMode, ignorePosition, standalone);
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
    if (mainPass && glassEnabled && window && lg::windowAllowed(window->metadata().appID())) {
        pruneDeadWindows();
        auto* raw = window.get();
        auto it = WINDOWS->find(raw);
        if (it == WINDOWS->end() || !it->second->get())
            it = WINDOWS->emplace(raw, std::make_shared<CWindowGlass>(window)).first;
        // Geometry snapshot NOW (hook-time renderModif), pixels LATER in the
        // element (proven target space). Skips damage inside and yield null.
        if (auto draw = it->second->snapshot(monitor, presentation)) {
            CWindowGlassPassElement::SData data{it->second, *draw, false};
            ctx.m_pass.add(makeUnique<CWindowGlassPassElement>(data));
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
                prevAnimatingIn = window->presentation().animatingIn();
                window->presentation().setAnimatingIn(false);
                cropShrink = true;
            }
        }
    }

    g_originalRenderWindow(self, ctx, window, monitor, presentation, now, decorate, passMode, ignorePosition, standalone);

    if (mainPass && !ctx.m_renderingSnapshot && window && window->mapped() && !window->isHidden()) {
        lg::queueWindowWash(window, monitor, presentation);
        eink::addWindowPass(ctx, window, monitor, presentation);
    }

    if (cropShrink)
        window->presentation().setAnimatingIn(prevAnimatingIn);
    goo::endWindowMorph(window, gooSave);
}

} // namespace

namespace lg {
bool glassWindowBorderAt(const CBox& box, PHLMONITOR monitor) {
    // Rim-only (glass master off): no glass pane exists to own the edge, so a
    // stale tracked pane must never suppress the renderBorder rim.
    if (lg::getInt("plugin:liquidglass:enabled", 1) == 0)
        return false;
    for (const auto& [_, glass] : *WINDOWS) {
        if (!glass)
            continue;
        const auto win = glass->get();
        if (!win || !win->mapped() || win->isHidden() || !windowAllowed(win->metadata().appID()))
            continue;
        if (glass->borderBoxMatches(box, monitor))
            return true;
    }
    return false;
}

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
        if (!win || !win->mapped() || win->isHidden() || win->monitorID() != monitor->m_id)
            continue;
        if (!(win->m_state & Desktop::View::WINDOW_STATE_PINNED) &&
            !workspaceRenders(win->m_workspace, monitor->m_activeWorkspace, monitor->m_activeSpecialWorkspace))
            continue;
        if (lg::windowAllowed(win->metadata().appID()) && !win->presentation().opaque())
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
        if (!win || !win->mapped() || win->isHidden() || win->monitorID() != monitor->m_id)
            continue;
        if (!(win->m_state & Desktop::View::WINDOW_STATE_PINNED) &&
            !workspaceRenders(win->m_workspace, monitor->m_activeWorkspace, monitor->m_activeSpecialWorkspace))
            continue;
        if (!lg::windowAllowed(win->metadata().appID()) || win->presentation().opaque())
            continue;
        if (const auto bounds = glass->glassBounds(); bounds && !bounds->intersection(dmgLogical).empty())
            return true;
    }
    return false;
}

// True when every damaged pixel lies inside one glass window's last painted
// bounds. The shared pre-window backdrop is the wallpaper/bottom layers, not
// window content, so damage confined to a glass pane (typing, video, cursor
// inside the terminal) cannot change it. The caller can then reuse the
// previous full-monitor capture instead of blitting the whole monitor again.
bool windowGlassContentOnly(PHLMONITOR monitor, const CBox& damage) {
    if (!monitor || damage.w <= 0 || damage.h <= 0)
        return false;
    const float scale = monitor->m_scale > 0.0f ? monitor->m_scale : 1.0f;
    const CBox dmgLogical{damage.x / scale, damage.y / scale, damage.w / scale, damage.h / scale};
    for (const auto& [key, glass] : *WINDOWS) {
        const auto win = glass ? glass->get() : nullptr;
        if (!win || !win->mapped() || win->isHidden() || win->monitorID() != monitor->m_id)
            continue;
        if (!(win->m_state & Desktop::View::WINDOW_STATE_PINNED) &&
            !workspaceRenders(win->m_workspace, monitor->m_activeWorkspace, monitor->m_activeSpecialWorkspace))
            continue;
        if (!lg::windowAllowed(win->metadata().appID()) || win->presentation().opaque())
            continue;
        const auto bounds = glass->glassBounds();
        if (!bounds)
            continue;
        if (dmgLogical.x >= bounds->x - 1.0 && dmgLogical.y >= bounds->y - 1.0 &&
            dmgLogical.x + dmgLogical.w <= bounds->x + bounds->w + 1.0 &&
            dmgLogical.y + dmgLogical.h <= bounds->y + bounds->h + 1.0)
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
    G_MOUSE_MOVE = Event::bus()->m_events.input.mouse.move.listen(onMouseMove);
    G_RIM_STAGE = Event::bus()->m_events.render.stage.listen(onRimStage);

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

    for (const auto& match : HyprlandAPI::findFunctionsByName(PHANDLE, "end")) {
        if (!match.demangled.contains("CHyprOpenGLImpl::end"))
            continue;
        G_HOOK_END = HyprlandAPI::createFunctionHook(PHANDLE, match.address, (void*)hkEnd);
        if (G_HOOK_END && G_HOOK_END->hook()) {
            g_originalEnd = reinterpret_cast<EndFn>(G_HOOK_END->m_original);
            break;
        }
        G_HOOK_END = nullptr;
    }
    std::ofstream("/tmp/lucid-wash.log", std::ios::app) << "init end=" << (g_originalEnd ? 1 : 0) << "\n";
    if (!g_originalEnd)
        HyprlandAPI::addNotification(PHANDLE, "[liquidglass] end hook failed — wash overlay disabled",
                                     CHyprColor{1, 0.2, 0.2, 1}, 5000);

    return {LG_NAME, LG_DESC, LG_AUTHOR, LG_VERSION};
}

APICALL EXPORT void PLUGIN_EXIT() {
    // Morph first: releases outgoing workspaces + rounding hook while the
    // renderer is still up. Then the glass unhooks below.
    goo::exitMorph();
    lg::exitWindowFocus();
    G_MOUSE_MOVE.reset();
    G_RIM_STAGE.reset();
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
    if (G_HOOK_END) {
        HyprlandAPI::removeFunctionHook(PHANDLE, G_HOOK_END);
        G_HOOK_END = nullptr;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
}

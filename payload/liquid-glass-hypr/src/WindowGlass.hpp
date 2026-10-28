#pragma once

// Full-window liquid glass for matched windows (kitty takeover).
//
// Same in-render-pass architecture as the layer pills (CGlassLayer): per
// frame the window renders, glass draws one quad over the whole window rect
// — region blit -> half-res blur pyramid -> glass.frag — straight into the
// current framebuffer, BEFORE the window content itself draws. Pixels never
// leave the GPU. The original renderWindow then draws the (translucent)
// terminal crisply on top: text stays opaque, the background lets the glass
// through.
//
// Scheduling is split in two, deliberately (v0.2.6 hybrid):
//   - hkRenderWindow calls snapshot(): geometry is sampled HERE — an exact
//     replication of upstream's REALPOS (geometric position + workspace
//     m_renderOffset + floating offset, pinned exempt) — sharing the live
//     state of the content draw that follows, and damage is issued HERE.
//   - The pass element then runs draw() with the snapshot in the same
//     execution context the layer pills use (proven target space), carrying
//     its own geometry copy so straddling windows can't alias monitors.
// A window with no match (or an unreadable-everything fallback) is skipped
// silently: glass simply doesn't draw there.
//
// Differences from the layer path, all deliberate:
//   - No geometry bridge: the window rect comes straight from the compositor
//     (CWindow::getWindowMainSurfaceBox), so glass tracks moves/resizes
//     exactly with zero IPC.
//   - Corner radii come from the window's own rounding() (windowrule +
//     decoration), converted to framebuffer px.
//   - Tint is the TERMINAL's background color (window_tint_file, default
//     ~/.config/kitty/matugen-colors.conf, last `background #rrggbb` wins), NOT the
//     dark/light theme tint the pills use. Falls back to the theme tint when
//     the file is unreadable.
//   - Fullscreen-coverage windows are skipped: nothing alive behind them, so
//     glass would only burn GPU to repaint the tint.

#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/render/Framebuffer.hpp>
#include <hyprland/src/render/Shader.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>

#include <chrono>

#include "Glass.hpp" // SGlassUniforms / SBlurUniforms (same glass.frag interface)

// One frame's worth of window glass inputs, sampled at hook time and owned
// by the pass element (per-monitor safe). Box/radii are monitor-local
// framebuffer px — exactly what projectBoxToTarget wants.
struct SWinDraw {
    CBox box{0, 0, 0, 0};
    float rad = 0;
    int tint = 0;
    // Workspace fade factor (m_alpha, pinned windows exempt — upstream
    // fadeAlpha replication): the glass fades with the window instead of
    // sitting solid under a ghost.
    float alphaMul = 1;
    // Active-window glow boost, already ramped (see m_glowAdd): added to
    // the edge glow weight uniform at draw time.
    float glowAdd = 0;
    // True when no earlier window overlaps this window's padded capture
    // region: the shared pre-window backdrop is valid for this one.
    bool useShared = true;
    // True when this frame's damage is content-only and the cached blurred
    // backdrop can be reused (no capture/blit/blur chain this frame).
    bool reuseCapture = false;
};

// Focus tracking for the active glow (init/exit called from main.cpp,
// mirroring goo::initMorph/exitMorph: listener reset before unhooks).
namespace lg {
void initWindowFocus();
void exitWindowFocus();
// Record a window's monitor-local framebuffer box in this frame's draw
// order. Used to decide whether a later glass window may use the shared
// pre-window backdrop (no earlier window may overlap its capture region).
void noteWindowBox(PHLWINDOW window, PHLMONITOR monitor);
// Number of mapped, translucent, allowed windows on this monitor. The
// shared pre-window capture only pays off with more than one consumer.
int windowGlassCount(PHLMONITOR monitor);
// True if the frame damage (monitor-local framebuffer px) intersects any
// glass window's last painted bounds. Avoids a full-monitor capture when a
// cursor or another window is the only thing repainting.
bool windowGlassNeedsFrame(PHLMONITOR monitor, const CBox& damage);
} // namespace lg

class CWindowGlass {
  public:
    explicit CWindowGlass(PHLWINDOW window);
    ~CWindowGlass() = default;

    [[nodiscard]] PHLWINDOW get() const { return m_window.lock(); }

    // Hook-time half: sample geometry (with live renderModif), issue damage,
    // resolve the tint. Returns a draw snapshot, or nullopt to skip (damage
    // for disappearing windows is handled inside).
    [[nodiscard]] std::optional<SWinDraw> snapshot(PHLMONITOR monitor);

    // Element-time half: capture -> pyramid -> glass quad from the snapshot.
    // overRim re-runs the same path on the composed framebuffer (window
    // included) with rim-only alpha.
    void draw(PHLMONITOR monitor, const SWinDraw& d, bool overRim = false);

    // Last snapshot union in monitor-local LOGICAL px (for the pass
    // element's boundingBox). Same contract as CGlassLayer::glassBounds.
    [[nodiscard]] std::optional<CBox> glassBounds() const {
        if (!m_boundsOk || m_boundsLog.w <= 0 || m_boundsLog.h <= 0)
            return std::nullopt;
        return m_boundsLog;
    }

    // True while a painted region exists that may need cleanup repaints.
    [[nodiscard]] bool needsCleanup() const { return m_boundsOk; }

    // Repaint the last-known region (used when the window disappears:
    // unmapped/hidden/fullscreen/destroyed) so no stale glass ghosts linger
    // after workspace switches, fullscreening or closes. No-op when clean.
    void damageLast();

  private:
    static constexpr int PAD_PX = 32; // refraction bleed around the window

    void ensureShaders();
    void ensureKawase(int hw, int hh, unsigned int format);
    void ensureChain(int hw, int hh, unsigned int format); // lazy: only when chain runs
    void ensureBokeh(int hw, int hh, unsigned int format); // lazy: only when bokeh on
    void kawaseDown(const SP<Render::IFramebuffer>& src, const SP<Render::IFramebuffer>& dst, float radius);
    void kawaseUp(const SP<Render::IFramebuffer>& src, const SP<Render::IFramebuffer>& dst, float radius);
    void bokehPass(float radius, float strength);

    PHLWINDOWREF m_window;

    SP<Render::IFramebuffer> m_halfA; // L0: capture at half res (uBlur source)
    SP<Render::IFramebuffer> m_halfB; // L1: quarter res
    SP<Render::IFramebuffer> m_halfC; // L2: eighth res
    SP<Render::IFramebuffer> m_halfT; // bokeh output (L0 size)
    SP<Render::IFramebuffer> m_sharp; // over-rim sharp capture (uSharp source)

    SP<CShader> m_glass;
    SP<CShader> m_kawDown;
    SP<CShader> m_kawUp;
    SP<CShader> m_bokeh;
    SGlassUniforms m_gu;
    SKawaseU m_kd;
    SKawaseU m_ku;
    SBokehU m_bo;
    bool m_shadersOk = false;

    // Own fullscreen unit quad. Same ownership rule as CGlassLayer: never
    // touch Hyprland's internal VAOs; leaked on unload (see main.cpp).
    GLuint m_vao = 0;
    GLuint m_vbo = 0;

    CBox m_boundsLog{0, 0, 0, 0};
    bool m_boundsOk = false;
    Vector2D m_lastMonPos{0, 0};
    std::string m_lastCls;
    uint64_t m_tuneGen = 0;
    // Cached blurred backdrop. Valid only while the window box, monitor,
    // capture scale and tune are unchanged; content-only damage inside a
    // non-overlapping window can reuse it without another blit.
    bool m_captureValid = false;
    CBox m_cacheBox{0, 0, 0, 0};
    MONITORID m_cacheMon = MONITOR_INVALID;
    float m_cacheMonScale = 0;
    Vector2D m_cacheMonSize{0, 0};
    int m_cacheCapDiv = 0;
    int m_cachePasses = -1;
    int m_cacheHw = 0, m_cacheHh = 0;
    bool m_cacheBokehOn = false;
    float m_cacheBokeh = 0;
    uint64_t m_cacheTuneGen = 0;
    // Active-glow ramp state: current boost, init flag (first snapshot snaps
    // so mid-session loads don't sweep), last step time.
    float m_glowAdd = 0;
    bool m_glowInit = false;
    std::chrono::steady_clock::time_point m_glowT{};
    // Window motion liquid: last target box/time and the smoothed stretch.
    CBox m_motionLast{0, 0, 0, 0};
    bool m_motionInit = false;
    std::chrono::steady_clock::time_point m_motionT{};
    float m_motionStretch = 0;
    // Tint-file stamp at last damage: kitty.conf edits repaint via
    // damage-on-change, same as the prefs/matugen tune generation.
    std::filesystem::file_time_type m_tintStamp = std::filesystem::file_time_type::min();
    bool m_haveTintStamp = false;
};

// Single render-pass element per glassed window draw. Same execution context
// as the layer pills (proven target space); geometry rides along owned.
class CWindowGlassPassElement : public IPassElement {
  public:
    struct SData {
        std::shared_ptr<CWindowGlass> glass;
        SWinDraw draw;
        bool overRim = false; // true: rim-only overdraw (executes after content)
    };

    explicit CWindowGlassPassElement(const SData& data);

    std::vector<UP<IPassElement>> draw() override;
    [[nodiscard]] bool                needsLiveBlur() override;
    [[nodiscard]] bool                needsPrecomputeBlur() override;
    [[nodiscard]] std::optional<CBox> boundingBox() override;
    [[nodiscard]] bool                disableSimplification() override;
    // PERF: discardable (false) like the layer pills: damage-on-change
    // (bounds/tune/tint/glow-ramp in snapshot()) already damages when glass
    // pixels go stale. Was true (forced every frame at monitor Hz even when
    // static: GPU never idled, input queued behind renders, 35% SM at idle).
    [[nodiscard]] bool                undiscardable() override { return false; }

    [[nodiscard]] const char* passName() override { return "CWindowGlassPassElement"; }
    [[nodiscard]] ePassElementType type() override { return EK_CUSTOM; }

  private:
    SData m_data;
};

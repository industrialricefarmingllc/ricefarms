#pragma once

// Per-layer-surface glass state.
//
// Every frame the surface renders, Glass::render() draws liquid glass behind
// each pill listed in the surface's geometry file, straight into the current
// framebuffer, before the layer content itself draws. Pixels never leave the
// GPU: region blit -> half-res blur pyramid -> glass quad. After this returns,
// the original renderLayer draws text/icons crisply on top.
//
// A surface with no (or unreadable) geometry file is skipped silently: glass
// simply doesn't draw there. That is also the no-plugin-misconfig fallback.

#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/render/Framebuffer.hpp>
#include <hyprland/src/render/Shader.hpp>

#include <filesystem>
#include <map>
#include <optional>
#include <cstdint>
#include <string>
#include <vector>

struct SPill {
    // Framebuffer-absolute px (converted at parse with the measured ratio).
    // projectBoxToTarget takes these directly (monitor-local fb px, same
    // convention as upstream MONITORBOX).
    float x = 0, y = 0, w = 0, h = 0;
    float r[4] = {0, 0, 0, 0}; // tl, tr, br, bl, framebuffer px
    float fl[2] = {0, 0}; // notch flare shoulders (left, right), fb px
    // Per-pill squircle smoothing override 0..1; -1 = follow the global
    // plugin:liquidglass:squircle_f. Lets animation geometry opt out: the
    // pibble launch reveal publishes its growing circle with sq: 0 so it
    // stays a true circle while everything else goes squircle.
    float sq = -1;
};

struct SGlassUniforms {
    GLint proj = -1;
    GLint pad = -1; // pill subrect inside the (shadow-expanded) draw quad
    GLint blur = -1;
    GLint sharp = -1;   // over-rim sharp capture (unit 1)
    GLint rimBlur = -1; // 0 regular, 1 over-rim sharp->r3 ramp
    GLint capOrigin = -1, capScale = -1;
    GLint baseColor = -1;
    GLint power = -1, shape = -1;
    GLint a = -1, b = -1, c = -1, d = -1, fpower = -1;
    GLint noise = -1;
    GLint glowW = -1, glowB = -1, glowE0 = -1, glowE1 = -1, glowT = -1;
    GLint usePill = -1, radii = -1, flare = -1, box = -1, opacity = -1;
    GLint squircleF = -1; // shared corner smoothing 0..1 (uSquircleF)
    GLint shadowColor = -1, shadowA = -1, shadowOff = -1, shadowBlur = -1;
    GLint ca = -1;
    GLint detail = -1; // detail preservation 0..1
    GLint lensBand = -1; // 0 full-field lens (pills), 1 band-confined (windows)
    GLint overRim = -1; // 0 glass under content, 1 rim-only overdraw
    GLint bevW = -1;    // precomputed bevel band (saves per-fragment log)
    GLint edgePx = -1;  // precomputed trio width (saves per-fragment log)
    GLint logCME = -1;  // precomputed log(uC*M_E) for f_func exp fast path
};

struct SKawaseU {
    GLint tex = -1, radius = -1, halfpixel = -1;
    GLint proj = -1;
};

struct SBokehU {
    GLint tex = -1, radius = -1, halfpixel = -1, bokeh = -1;
    GLint proj = -1;
};

struct SLayerRingU {
    GLint proj = -1, blur = -1, inner = -1, quad = -1, thick = -1, round = -1;
    GLint tint = -1, tint2 = -1, lerp = -1, tintMix = -1, a = -1;
    GLint throwMax = -1, winSize = -1, winR = -1, shape = -1;
    GLint lA = -1, lB = -1, lC = -1, lD = -1, lFPower = -1;
    GLint glowW = -1, glowE0 = -1, glowE1 = -1, glowT = -1, glowBias = -1;
    GLint radii = -1, useRadii = -1, winRadii = -1, fadeTop = -1, fadeMid = -1, fadeBottom = -1, fadeAng = -1;
    GLint frameEnable = -1, frameScale = -1, seed = -1, frieze = -1, gilt = -1, relief = -1;
    GLint shCol = -1, shA = -1, shOff = -1, shBlur = -1;
    GLint flare = -1, push = -1, squircleF = -1;
};

class CGlassLayer {
  public:
    explicit CGlassLayer(PHLLS surface);
    ~CGlassLayer() = default;

    [[nodiscard]] PHLLS get() const { return m_surface.lock(); }

    void render(PHLMONITOR monitor);

    // Union of last frame's pills in monitor-local LOGICAL px (for the pass
    // element's boundingBox). Lags one frame behind morphs; padded for the
    // shadow halo. Survives empty-geometry frames (file deleted) so the pass
    // keeps culling against the last known union instead of fullscreen.
    // Nullopt until the first successful render.
    [[nodiscard]] std::optional<CBox> glassBounds() const {
        if (m_boundsLog.w <= 0 || m_boundsLog.h <= 0)
            return std::nullopt;
        return m_boundsLog;
    }

  private:
    static constexpr int PAD_PX = 32; // refraction bleed around each pill

    // Geometry contract (qml/GlassLayout.qml):
    //   ~/.cache/liquid-glass-hypr/liquidglass-<name>-<MON>.json, one file
    //   per publisher:
    //   {"monitor":"DP-1","surface":{"w":2560,"h":780},"pills":[{x,y,w,h,
    //     "r":[tl,tr,br,bl]}, ...]}
    // Logical px, surface-relative. A file applies to this surface when its
    // surface size matches (epsilon 1px) — sizes are exact and distinctive
    // per widget surface, so no registry, lifecycle tracking, or dpr math.
    [[nodiscard]] bool loadGeometry(PHLMONITOR monitor, const CBox& surfBox, std::vector<SPill>& pills,
                                    bool forBorders = false);
    void ensureShaders();
    void ensureRing();
    void ensureKawase(int hw, int hh, unsigned int format);
    void ensureChain(int hw, int hh, unsigned int format); // lazy: only when passes>0
    void ensureBokeh(int hw, int hh, unsigned int format); // lazy: only when bokeh on
    void kawaseDown(const SP<Render::IFramebuffer>& src, const SP<Render::IFramebuffer>& dst, float radius);
    void kawaseUp(const SP<Render::IFramebuffer>& src, const SP<Render::IFramebuffer>& dst, float radius);
    void bokehPass(float radius, float strength);
    void blitRegion(SP<Render::IFramebuffer> src, int sx0, int sy0, int sx1, int sy1);
    void blurPyramid(float radius, int passes);
    void drawPill(const SPill& pill, const Vector2D& capSize);

    PHLLSREF m_surface;

    SP<Render::IFramebuffer> m_halfA; // L0: capture at half res (uBlur source)
    SP<Render::IFramebuffer> m_halfB; // L1: quarter res
    SP<Render::IFramebuffer> m_halfC; // L2: eighth res
    SP<Render::IFramebuffer> m_halfT; // bokeh output (L0 size)

    SP<CShader> m_glass;
    SP<CShader> m_kawDown;
    SP<CShader> m_kawUp;
    SP<CShader> m_bokeh;
    SP<CShader> m_ring;
    SGlassUniforms m_gu;
    SKawaseU m_kd;
    SKawaseU m_ku;
    SBokehU m_bo;
    SLayerRingU m_ru;
    bool m_shadersOk = false;
    bool m_ringOk = false;

    // Own fullscreen unit quad ([0,1] pos + uv). Never touch Hyprland's
    // internal VAOs: explicit ownership, zero coupling. Leaked with the rest
    // on unload (see main.cpp) — deleting GL objects off-context SEGVs.
    GLuint m_vao = 0;
    GLuint m_vbo = 0;

    // Last rendered pill union (logical, padded). See glassBounds().
    CBox m_boundsLog{0, 0, 0, 0};
    bool m_boundsOk = false;
    // Tune generation at last damage: prefs/matugen edits repaint via
    // damage-on-change instead of a damage-every-frame loop.
    uint64_t m_tuneGen = 0;

    // One geometry file per publisher (dock, bar, ...). Files are matched to
    // THIS surface by the surface's logical size, which QML reports exactly
    // and which is distinctive per widget surface. Parsed only on change.
    struct SGeoFile {
        std::filesystem::file_time_type stamp = std::filesystem::file_time_type::min();
        std::vector<SPill> pills; // surface-absolute logical px
        bool parsed = false;
    };
    std::map<std::string, SGeoFile> m_geoFiles;
};

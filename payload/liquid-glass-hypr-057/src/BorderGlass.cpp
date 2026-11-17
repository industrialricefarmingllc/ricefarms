#include "BorderGlass.hpp"
#include "Config.hpp"
#include "Shaders.hpp"
#include "WindowGlass.hpp"
#include "RimFollow.hpp"

#include <GLES3/gl32.h>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/Framebuffer.hpp>
#include <hyprland/src/render/Shader.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprutils/math/Misc.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <map>
#include <tuple>

using namespace Render;
using namespace Render::GL;

namespace lg {

RenderBorder1Fn g_origRenderBorder1 = nullptr;
RenderBorder2Fn g_origRenderBorder2 = nullptr;
DropShadowDrawFn g_origDropShadowDraw = nullptr;

namespace {

// Own scratch + shaders + unit quad. Separate from CGlassLayer's on purpose:
// border hooks can fire from any window pass, never nested inside a pill
// render, but sharing framebuffers across the two paths would alias lifetimes
// for zero benefit. Leaked on unload like everything else GL (main.cpp).
SP<Render::IFramebuffer> s_halfA;
SP<Render::IFramebuffer> s_halfB;
SP<Render::IFramebuffer> s_halfC;
SP<Render::IFramebuffer> s_halfT; // bokeh output (L0 size, same UV contract)
SP<CShader> s_ring;
SP<CShader> s_kawDown;
SP<CShader> s_kawUp;
SP<CShader> s_bokeh;
struct SRingU {
    GLint proj = -1, blur = -1, inner = -1, quad = -1, thick = -1, round = -1;
    GLint tint = -1, tint2 = -1, lerp = -1, tintMix = -1, a = -1;
    GLint throwMax = -1, winSize = -1, winR = -1, shape = -1;
    GLint lA = -1, lB = -1, lC = -1, lD = -1, lFPower = -1, logCME = -1;
    GLint glowW = -1, glowE0 = -1, glowE1 = -1, glowT = -1, glowBias = -1;
    GLint radii = -1, useRadii = -1, winRadii = -1, fadeTop = -1, fadeMid = -1, fadeBottom = -1, fadeAng = -1;
    GLint squircleF = -1;
    GLint frameEnable = -1, frameScale = -1, seed = -1, frieze = -1, gilt = -1, relief = -1;
    GLint rimLight = -1, rimStrength = -1, rimWidth = -1, rimAngle = -1, rimSplay = -1, rimShade = -1;
    GLint rimAtInner = -1, rimShift = -1;
    GLint rimSampleShift = -1;
    GLint rimOverlay = -1;
    GLint shCol = -1, shA = -1, shOff = -1, shBlur = -1;
    GLint flare = -1, push = -1;
} s_ru;
struct SKawaseU {
    GLint tex = -1, radius = -1, halfpixel = -1, proj = -1;
} s_kd;
SKawaseU s_ku;
struct SBokehU {
    GLint tex = -1, radius = -1, halfpixel = -1, bokeh = -1, proj = -1;
} s_bo;
GLuint s_vao = 0, s_vbo = 0;
bool s_ok = false;

// Cursor-following rim angle, one state per live border box. The border hook
// has no window pointer; the quantized box + monitor is its identity.
std::map<std::tuple<MONITORID, int, int, int, int>, lg::SRimFollowState> s_rimFollow;

// Second-half detection for the animated overload: same box twice in a row
// means grad2 of the border we just drew — cancel only.
CBox s_lastBox{0, 0, 0, 0};
bool s_haveLast = false;

static constexpr std::array<float, 9> FULLSCREEN_PROJECTION = {
    2.0f, 0.0f, 0.0f,
    0.0f, 2.0f, 0.0f,
    -1.0f, -1.0f, 1.0f,
};

static constexpr int RING_PAD_PX = 28; // bleed: lens throw + 1px push

static GLint loc(GLuint program, const char* name) {
    return glGetUniformLocation(program, name);
}

static GLuint fbId(const SP<Render::IFramebuffer>& fb) {
    return dynamic_cast<Render::GL::CGLFramebuffer*>(fb.get())->getFBID();
}

void ensure() {
    if (s_ok)
        return;
    if (!s_ring)
        s_ring = makeShared<CShader>();
    if (!s_kawDown)
        s_kawDown = makeShared<CShader>();
    if (!s_kawUp)
        s_kawUp = makeShared<CShader>();
    if (!s_bokeh)
        s_bokeh = makeShared<CShader>();
    if (!s_ring->createProgram(SHADERS.at("glass.vert"), SHADERS.at("ring.frag"), true)) {
        lg::notify("liquidglass: ring.frag failed to compile — window borders fall back to flat");
        return;
    }
    if (!s_kawDown->createProgram(SHADERS.at("glass.vert"), SHADERS.at("kawase_down.frag"), true)) {
        lg::notify("liquidglass: kawase_down.frag failed to compile — window borders fall back to flat");
        return;
    }
    if (!s_kawUp->createProgram(SHADERS.at("glass.vert"), SHADERS.at("kawase_up.frag"), true)) {
        lg::notify("liquidglass: kawase_up.frag failed to compile — window borders fall back to flat");
        return;
    }
    if (!s_bokeh->createProgram(SHADERS.at("glass.vert"), SHADERS.at("bokeh.frag"), true)) {
        lg::notify("liquidglass: bokeh.frag failed to compile — window borders fall back to flat");
        return;
    }
    const GLuint rp = s_ring->program();
    s_ru.proj = loc(rp, "proj");
    s_ru.blur = loc(rp, "uBlur");
    s_ru.inner = loc(rp, "uInner");
    s_ru.quad = loc(rp, "uQuadSize");
    s_ru.thick = loc(rp, "uThick");
    s_ru.round = loc(rp, "uRound");
    s_ru.tint = loc(rp, "uTint");
    s_ru.tint2 = loc(rp, "uTint2");
    s_ru.lerp = loc(rp, "uLerp");
    s_ru.tintMix = loc(rp, "uTintMix");
    s_ru.a = loc(rp, "uA");
    s_ru.throwMax = loc(rp, "uThrow");
    s_ru.winSize = loc(rp, "uWinSize");
    s_ru.winR = loc(rp, "uWinR");
    s_ru.shape = loc(rp, "uShape");
    s_ru.lA = loc(rp, "uLA");
    s_ru.lB = loc(rp, "uLB");
    s_ru.lC = loc(rp, "uLC");
    s_ru.lD = loc(rp, "uLD");
    s_ru.lFPower = loc(rp, "uLFPower");
    s_ru.logCME = loc(rp, "uLogCME");
    s_ru.glowW = loc(rp, "uGlowW");
    s_ru.glowE0 = loc(rp, "uGlowE0");
    s_ru.glowE1 = loc(rp, "uGlowE1");
    s_ru.glowT = loc(rp, "uGlowT");
    s_ru.glowBias = loc(rp, "uGlowBias");
    s_ru.radii = loc(rp, "uRadii");
    s_ru.useRadii = loc(rp, "uUseRadii");
    s_ru.winRadii = loc(rp, "uWinRadii");
    s_ru.squircleF = loc(rp, "uSquircleF");
    s_ru.fadeTop = loc(rp, "uFadeTop");
    s_ru.fadeMid = loc(rp, "uFadeMid");
    s_ru.fadeBottom = loc(rp, "uFadeBottom");
    s_ru.fadeAng = loc(rp, "uFadeAngle");
    s_ru.frameEnable = loc(rp, "uFrameEnable");
    s_ru.frameScale = loc(rp, "uFrameScale");
    s_ru.seed = loc(rp, "uSeed");
    s_ru.frieze = loc(rp, "uFrieze");
    s_ru.gilt = loc(rp, "uGilt");
    s_ru.relief = loc(rp, "uRelief");
    s_ru.rimLight = loc(rp, "uRimLight");
    s_ru.rimStrength = loc(rp, "uRimStrength");
    s_ru.rimWidth = loc(rp, "uRimWidth");
    s_ru.rimAngle = loc(rp, "uRimAngle");
    s_ru.rimSplay = loc(rp, "uRimSplay");
    s_ru.rimShade = loc(rp, "uRimShade");
    s_ru.rimAtInner = loc(rp, "uRimAtInner");
    s_ru.rimShift = loc(rp, "uRimShift");
    s_ru.rimSampleShift = loc(rp, "uRimSampleShift");
    s_ru.rimOverlay = loc(rp, "uRimOverlay");
    s_ru.shCol = loc(rp, "uShadowColor");
    s_ru.shA = loc(rp, "uShadowA");
    s_ru.shOff = loc(rp, "uShadowOff");
    s_ru.shBlur = loc(rp, "uShadowBlur");
    s_ru.flare = loc(rp, "uFlare");
    s_ru.push = loc(rp, "uPush");
    const GLuint kdp = s_kawDown->program();
    s_kd.proj = loc(kdp, "proj");
    s_kd.tex = loc(kdp, "uTex");
    s_kd.radius = loc(kdp, "uRadius");
    s_kd.halfpixel = loc(kdp, "uHalfpixel");
    const GLuint kup = s_kawUp->program();
    s_ku.proj = loc(kup, "proj");
    s_ku.tex = loc(kup, "uTex");
    s_ku.radius = loc(kup, "uRadius");
    s_ku.halfpixel = loc(kup, "uHalfpixel");
    const GLuint bop = s_bokeh->program();
    s_bo.proj = loc(bop, "proj");
    s_bo.tex = loc(bop, "uTex");
    s_bo.radius = loc(bop, "uRadius");
    s_bo.halfpixel = loc(bop, "uHalfpixel");
    s_bo.bokeh = loc(bop, "uBokeh");
    if (s_vao == 0) {
        static constexpr float QUAD[16] = {
            0.0f, 0.0f, 0.0f, 0.0f,
            1.0f, 0.0f, 1.0f, 0.0f,
            0.0f, 1.0f, 0.0f, 1.0f,
            1.0f, 1.0f, 1.0f, 1.0f,
        };
        glGenVertexArrays(1, &s_vao);
        glGenBuffers(1, &s_vbo);
        glBindVertexArray(s_vao);
        glBindBuffer(GL_ARRAY_BUFFER, s_vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(QUAD), QUAD, GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)0);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));
        glBindVertexArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
    }
    s_ok = true;
}

bool sameBox(const CBox& a, const CBox& b) {
    return a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h;
}

// Per-window frame seed from border geometry: stable for a given window
// placement/size, divergent across windows (FNV-style mix over quantized
// box + gradient lerp, so active/inactive can diverge too). seed_mode=0
// bypasses this and every window shares one frame.
float frameSeed(const CBox& box, float lerp) {
    uint64_t h = 1469598103934665603ULL;
    auto mix = [&](uint64_t v) {
        h ^= v + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
    };
    mix((uint64_t)(box.x * 13.0 + 100000.0));
    mix((uint64_t)(box.y * 7.0 + 100000.0));
    mix((uint64_t)(box.w * 3.0));
    mix((uint64_t)(box.h * 5.0));
    mix((uint64_t)(lerp * 1000.0));
    h ^= h >> 33;
    h *= 0xff51afd7ed558ccdULL;
    h ^= h >> 33;
    return (float)(h % 100000) / 100000.0f;
}

static void kawaseDown(const SP<Render::IFramebuffer>& src, const SP<Render::IFramebuffer>& dst, float radius) {
    const int dw = (int)dst->m_size.x, dh = (int)dst->m_size.y;
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(dst));
    g_pHyprRenderer->setViewport(0, 0, dw, dh);
    glActiveTexture(GL_TEXTURE0);
    src->getTexture()->bind();
    src->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    src->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    auto shader = g_pHyprOpenGL->useShader(s_kawDown);
    glUniformMatrix3fv(s_kd.proj, 1, GL_FALSE, FULLSCREEN_PROJECTION.data());
    glUniform1i(s_kd.tex, 0);
    glUniform1f(s_kd.radius, radius);
    glUniform2f(s_kd.halfpixel, 0.5f / (int)src->m_size.x, 0.5f / (int)src->m_size.y);
    glBindVertexArray(s_vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
}

static void kawaseUp(const SP<Render::IFramebuffer>& src, const SP<Render::IFramebuffer>& dst, float radius) {
    const int dw = (int)dst->m_size.x, dh = (int)dst->m_size.y;
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(dst));
    g_pHyprRenderer->setViewport(0, 0, dw, dh);
    glActiveTexture(GL_TEXTURE0);
    src->getTexture()->bind();
    src->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    src->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    auto shader = g_pHyprOpenGL->useShader(s_kawUp);
    glUniformMatrix3fv(s_ku.proj, 1, GL_FALSE, FULLSCREEN_PROJECTION.data());
    glUniform1i(s_ku.tex, 0);
    glUniform1f(s_ku.radius, radius);
    glUniform2f(s_ku.halfpixel, 0.5f / (int)src->m_size.x, 0.5f / (int)src->m_size.y);
    glBindVertexArray(s_vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
}

static void bokehPass(const SP<Render::IFramebuffer>& src, const SP<Render::IFramebuffer>& dst, float radius,
                      float strength) {
    const int dw = (int)dst->m_size.x, dh = (int)dst->m_size.y;
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(dst));
    g_pHyprRenderer->setViewport(0, 0, dw, dh);
    glActiveTexture(GL_TEXTURE0);
    src->getTexture()->bind();
    src->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    src->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    auto shader = g_pHyprOpenGL->useShader(s_bokeh);
    glUniformMatrix3fv(s_bo.proj, 1, GL_FALSE, FULLSCREEN_PROJECTION.data());
    glUniform1i(s_bo.tex, 0);
    glUniform1f(s_bo.radius, radius);
    glUniform2f(s_bo.halfpixel, 0.5f / (int)src->m_size.x, 0.5f / (int)src->m_size.y);
    glUniform1f(s_bo.bokeh, strength);
    glBindVertexArray(s_vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
}

// Draw the glass ring for one border. Box math replicates upstream
// CHyprOpenGLImpl::renderBorder exactly (renderModif, scaled border, round)
// so the ring lands pixel-identical over the band the flat border would
// have painted. Returns false when there is nothing (damage-)visible to do;
// the caller still cancels the original (it would draw nothing either).
bool drawRing(CHyprOpenGLImpl* gl, Render::CRenderContext& ctx, const CBox& box, const Config::CGradientValueData& g1,
              const Config::CGradientValueData& g2, float lerp, int borderSize, int round, int outerRound, float a,
              int winRoundFb) {
    PHLMONITOR monitor = ctx.m_data.pMonitor.lock();
    if (!monitor)
        return false;

    // Glass bodies are off. The master switch normally gates the border ring
    // too, but the Apple rim is an independent edge treatment: let it stand
    // alone and strip every other border-glass cost below (no blur chain, no
    // bokeh, no shadow pass, quarter-res backdrop capture).
    const bool rimOnly = lg::getInt("plugin:liquidglass:enabled", 1) == 0;

    // A glassed window already carries the Apple rim inside its glass pane
    // (glass.frag glass_rim). Don't draw a second rim in the outside border
    // band. Callers still cancel the flat native border, so the pane's own
    // edge is the only edge treatment here.
    if (lg::glassWindowBorderAt(box, monitor))
        return false;

    CBox newBox = box;
    ctx.m_data.renderModif.applyToBox(newBox);
    int scaledBorder = (int)std::round(borderSize * monitor->m_scale);
    scaledBorder = (int)std::round(scaledBorder * ctx.m_data.renderModif.combinedScale());
    if (scaledBorder < 1)
        return false;

    // Native border thickness (the window's true outer edge is at
    // box + scaledBorder). The rim band may be wider than the hairline.
    const int nativeBorder = scaledBorder;
    int bandThick = scaledBorder;
    int innerInset = 0;

    // Apple rim light: draw a slightly wider band than the native hairline so
    // the lit line and its inner falloff have room. rim_width 0 keeps the old
    // band.
    const bool rimLight = lg::getInt("plugin:liquidglass:rim_light", 1) == 1;
    if (rimLight) {
        const float rimLogical = std::max(0.0f, lg::getFloat("plugin:liquidglass:rim_width", 1.75f));
        const float rimPx = rimLogical * (float)monitor->m_scale * ctx.m_data.renderModif.combinedScale();
        // The band gives the highlight room to fall off. Rim-only draws ONLY
        // the lit line (uRimOverlay), so a wide band is glow, not a border.
        if (rimPx > (float)scaledBorder)
            bandThick = (int)std::ceil(rimPx);
        innerInset = rimOnly ? 1 : 0;
        scaledBorder = bandThick;
    } else {
        scaledBorder = nativeBorder;
    }

    newBox.x -= scaledBorder;
    newBox.y -= scaledBorder;
    newBox.w += 2 * scaledBorder;
    newBox.h += 2 * scaledBorder;
    // Cursor-following rim angle (opaque windows; glassed panes skip this
    // border ring and use glass.frag's own follow state). Coordinates are
    // monitor-local fb px, including across multiple outputs.
    float rimAngle = lg::getFloat("plugin:liquidglass:rim_angle", 135.0f);
    if (rimLight) {
        const auto key = std::make_tuple(monitor->m_id, (int)std::lround(box.x), (int)std::lround(box.y),
                                         (int)std::lround(box.w), (int)std::lround(box.h));
        if (s_rimFollow.size() > 512)
            s_rimFollow.clear();
        auto& st = s_rimFollow[key];
        const float prev = st.angle;
        rimAngle = lg::rimAngleFor(box, lg::cursorLocal(monitor), rimAngle, st);
        if (st.init && std::isfinite(prev) && std::abs(rimAngle - prev) > 0.01f) {
            // The rim is confined to the border band; damage four strips of
            // the band, not the whole window. (The old full-box damage made
            // every window repaint its full area at monitor Hz for ~0.3 s
            // after each pointer move, for a 1-2 px highlight change.)
            const double inv = 1.0 / (double)std::max(monitor->m_scale, 0.01f);
            const double padFb = std::max((double)bandThick + 2.0, (double)bandThick * 3.0);
            const double x = (double)monitor->m_position.x + newBox.x * inv;
            const double y = (double)monitor->m_position.y + newBox.y * inv;
            const double w = newBox.w * inv;
            const double h = newBox.h * inv;
            const double p = std::clamp(padFb * inv, 1.0, std::min(w, h) * 0.5);
            g_pHyprRenderer->damageBox(CBox{x, y, w, p});
            g_pHyprRenderer->damageBox(CBox{x, y + h - p, w, p});
            g_pHyprRenderer->damageBox(CBox{x, y, p, h});
            g_pHyprRenderer->damageBox(CBox{x + w - p, y, p, h});
        }
    }
    const float roundF = (float)round + (round == 0 ? 0 : (float)scaledBorder);
    const float outerF = outerRound == -1 ? roundF : (float)outerRound;

    // Shadow tunables first: the gate + capture must cover the halo, same
    // material as the pills (matugen hue via shadow_color, softer alpha).
    const float shBlurF = lg::getFloat("plugin:liquidglass:shadow_blur", 57.0f) * 0.25f;
    const float shOxF = lg::getFloat("plugin:liquidglass:shadow_offset_x", 0.0f);
    const float shOyF = lg::getFloat("plugin:liquidglass:shadow_offset_y", 20.0f) * 0.5f;
    const int shColF = lg::getInt("plugin:liquidglass:shadow_color", 0x1a1a1a11);
    // Rim-only has no shadow: don't grow the capture/gate for a halo that is
    // never drawn (uShadowA is forced to 0 below too).
    const float shPadF = rimOnly ? 0.0f
                                 : shBlurF * 2.2f + std::max(std::fabs(shOxF), std::fabs(shOyF)) + 8.0f;

    // Damage gate, mirroring upstream: band ∩ damage ∩ clipBox. Empty means
    // the original would emit no fragments either. Grown past the frame
    // silhouette (±3px) to the full shadow halo.
    CBox gateBox = newBox;
    gateBox.expand(std::max(4.0f, shPadF));
    CRegion ringRegion = ctx.m_data.damage.copy().intersect(gateBox);
    if (rimLight)
        ringRegion.subtract(box.copy().expand(-(double)innerInset));
    else
        ringRegion.subtract(box.copy().expand(-scaledBorder - (int)std::ceil(roundF)));
    if (ctx.m_data.clipBox.w != 0 && ctx.m_data.clipBox.h != 0)
        ringRegion.intersect(ctx.m_data.clipBox);
    if (ringRegion.empty())
        return false;

    ensure();
    if (!s_ok)
        return false;

    const auto source = ctx.m_data.currentFB;
    if (!source)
        return false;
    const int srcW = (int)source->m_size.x;
    const int srcH = (int)source->m_size.y;

    // Capture = outer box + bleed, clamped to the source. Bleed covers the
    // lens throw AND the shadow halo (shadow pixels are flat color, but the
    // draw quad == capture region so the quad must span both). Rim-only has
    // no shadow and only needs the small lens throw.
    const int ringPad = rimOnly ? 16 : std::max(RING_PAD_PX, (int)std::ceil(shPadF) + 8);
    const int qx0 = std::max(0, (int)std::floor(newBox.x - ringPad));
    const int qy0 = std::max(0, (int)std::floor(newBox.y - ringPad));
    const int qx1 = std::min(srcW, (int)std::ceil(newBox.x + newBox.w + ringPad));
    const int qy1 = std::min(srcH, (int)std::ceil(newBox.y + newBox.h + ringPad));
    const int rw = qx1 - qx0, rh = qy1 - qy0;
    if (rw < 8 || rh < 8)
        return false;
    // Rim-only samples the backdrop at the border band for the highlight
    // tint. It must resolve the band (rim_width + ringPad), so use
    // quarter-res rather than a postage-stamp capture: a 32x32 downsample
    // averages the dark window interior into every edge texel and the rim
    // reads as a flat gray hairline instead of the backdrop-lit Apple rim.
    const int hw = rimOnly ? std::max(1, rw / 4) : std::max(1, rw / 2);
    const int hh = rimOnly ? std::max(1, rh / 4) : std::max(1, rh / 2);
    const int qw = std::max(1, hw / 2), qh = std::max(1, hh / 2);
    const int ew = std::max(1, qw / 2), eh = std::max(1, qh / 2);

    if (!s_halfA)
        s_halfA = g_pHyprRenderer->createFB("liquidglass-border-a");
    if (!s_halfA)
        return false;
    if (s_halfA->m_size.x != hw || s_halfA->m_size.y != hh)
        s_halfA->alloc(hw, hh, source->m_drmFormat);
    if (!rimOnly) {
        if (!s_halfB)
            s_halfB = g_pHyprRenderer->createFB("liquidglass-border-b");
        if (!s_halfC)
            s_halfC = g_pHyprRenderer->createFB("liquidglass-border-c");
        if (!s_halfB || !s_halfC)
            return false;
        if (s_halfB->m_size.x != qw || s_halfB->m_size.y != qh)
            s_halfB->alloc(qw, qh, source->m_drmFormat);
        if (s_halfC->m_size.x != ew || s_halfC->m_size.y != eh)
            s_halfC->alloc(ew, eh, source->m_drmFormat);
        if (!s_halfB->getTexture() || !s_halfC->getTexture())
            return false;
    }
    if (!s_halfA->getTexture())
        return false;

    // Blur radius is the user setting regardless of window size, same as the
    // glass body. Radius is still resolution-proportional (x monitor scale):
    // a scale-blind framebuffer-px spread reads ~half as strong on a 2.4x 4K
    // panel as on the 1.6x primary for same-size windows.
    const float userRadius = lg::getFloat("plugin:liquidglass:blur_radius", 2.0f);
    const int userPasses = std::max(1, std::min(3, (int)std::round(lg::getFloat("plugin:liquidglass:blur_iters", 2.0f))));
    const float radius = userRadius * lg::getFloat("plugin:liquidglass:border_blur_scale", 0.0f);
    const int passes = rimOnly ? 0 : (radius < 0.05f ? 0 : userPasses);
    const float effR = radius * std::sqrt((float)userPasses) * 0.5f * (float)monitor->m_scale;
    const float bokeh = lg::getFloat("plugin:liquidglass:bokeh", 0.0f);
    const bool bokehOn = !rimOnly && bokeh > 0.01f;

    // PERF: no glGet* save/restore (pipeline stalls). Hyprland re-sets blend.
    glEnable(GL_BLEND);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    g_pHyprOpenGL->setCapStatus(GL_SCISSOR_TEST, false);

    // PERF: no glClear (blit overwrites).
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(s_halfA));
    g_pHyprRenderer->setViewport(0, 0, hw, hh);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbId(source));
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbId(s_halfA));
    glBlitFramebuffer(qx0, qy0, qx1, qy1, 0, 0, hw, hh, GL_COLOR_BUFFER_BIT, GL_LINEAR);

    {
        // Dual-Kawase chain (see Glass.cpp): iters>=3 runs the depth-2
        // cycle twice. Skipped entirely when passes==0 (sharp capture).
        if (passes > 0) {
            const int rounds = userPasses >= 3 ? 2 : 1;
            for (int k = 0; k < rounds; k++) {
                kawaseDown(s_halfA, s_halfB, effR);
                if (userPasses >= 2) {
                    kawaseDown(s_halfB, s_halfC, effR);
                    kawaseUp(s_halfC, s_halfB, effR);
                }
                kawaseUp(s_halfB, s_halfA, effR);
            }
        }
        // Bokeh scatter into the L0-size temp (independent of the chain).
        // Lazy alloc: only when bokeh on (default off).
        if (bokehOn) {
            if (!s_halfT)
                s_halfT = g_pHyprRenderer->createFB("liquidglass-border-t");
            // Bokeh is a low-frequency disc scatter: evaluating it at half the
            // capture resolution is visually lossless (the ring samples it
            // bilinearly with the same normalized UVs) and quarters its
            // 17-tap fill cost.
            const int btw = std::max(1, hw / 2), bth = std::max(1, hh / 2);
            if (s_halfT && (s_halfT->m_size.x != btw || s_halfT->m_size.y != bth))
                s_halfT->alloc(btw, bth, source->m_drmFormat);
            if (s_halfT && s_halfT->getTexture())
                bokehPass(s_halfA, s_halfT, effR, bokeh);
        }
    }

    // Ring draw: one projectBoxToTarget quad over the capture region, then
    // one scissored draw per damage rect — exactly upstream's subdivision.
    const auto transform = Math::wlTransformToHyprutils(Math::invertTransform(monitor->m_transform));
    CBox quadBox{(double)qx0, (double)qy0, (double)rw, (double)rh};
    Mat3x3 proj = g_pHyprRenderer->projectBoxToTarget(ctx, quadBox, transform);

    const float ix = (float)(box.x - qx0), iy = (float)(box.y - qy0);
    auto col0 = g1.m_colors.empty() ? CHyprColor{1, 1, 1, 1} : g1.m_colors[0];
    auto col1 = g2.m_colors.empty() ? col0 : g2.m_colors[0];

    const auto caller = source;
    const auto callerSize = source->m_size;
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    g_pHyprRenderer->setViewport(0, 0, (int)callerSize.x, (int)callerSize.y);
    glActiveTexture(GL_TEXTURE0);
    // Bokeh output shares L0's size and UV contract: sample it directly.
    // Falls back to L0 when bokeh alloc failed (no crash, just no bokeh).
    const bool useBokeh = bokehOn && s_halfT && s_halfT->getTexture();
    const auto& uBlurFb = useBokeh ? s_halfT : s_halfA;
    uBlurFb->getTexture()->bind();
    uBlurFb->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    uBlurFb->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);

    auto shader = g_pHyprOpenGL->useShader(s_ring);
    glUniformMatrix3fv(s_ru.proj, 1, GL_TRUE, proj.getMatrix().data());
    glUniform1i(s_ru.blur, 0);
    // Rim band: uInner is the band's inner edge, one px inside the content.
    // The rim line is moved onto the content edge by uRimAtInner/uRimShift so
    // there is no hairline gap between the light and the window.
    const float inInset = rimLight ? (float)innerInset : 0.0f;
    glUniform4f(s_ru.inner, ix + inInset, iy + inInset, (float)box.w - 2.0f * inInset,
                (float)box.h - 2.0f * inInset);
    glUniform2f(s_ru.quad, (float)rw, (float)rh);
    glUniform1f(s_ru.thick, rimLight ? (float)(bandThick + innerInset) : (float)scaledBorder);
    glUniform1f(s_ru.round, outerF);
    glUniform3f(s_ru.tint, (float)col0.r, (float)col0.g, (float)col0.b);
    glUniform3f(s_ru.tint2, (float)col1.r, (float)col1.g, (float)col1.b);
    glUniform1f(s_ru.lerp, lerp);
    glUniform1f(s_ru.tintMix, lg::getFloat("plugin:liquidglass:opacity", 0.23f));
    glUniform1f(s_ru.a, a);
    glUniform2f(s_ru.winSize, (float)box.w, (float)box.h);
    glUniform1f(s_ru.winR, (float)winRoundFb);
    // Window path: use the same corner smoothing as the window glass body
    // (window_squircle_f, else the shared squircle_f). Those are what
    // glass.frag uses for the pane and what hyprland.lua mirrors into
    // decoration:rounding_power, so the ring hugs the content/glass edge
    // instead of the old always-circular assumption. f = 0 keeps the exact
    // circular box.
    {
        float wsf = lg::getFloat("plugin:liquidglass:window_squircle_f", -1.0f);
        if (wsf < 0.0f)
            wsf = lg::getFloat("plugin:liquidglass:squircle_f", 0.5f);
        glUniform1f(s_ru.squircleF, std::clamp(wsf, 0.0f, 1.0f));
    }
    // Original lens curve: the pill keys (one material), except D which is
    // border-owned (border_d) — rims want a steeper profile than bodies.
    glUniform2f(s_ru.shape, lg::getFloat("plugin:liquidglass:shape_width", 3.5f),
                lg::getFloat("plugin:liquidglass:shape_height", 3.5f));
    glUniform1f(s_ru.lA, lg::getFloat("plugin:liquidglass:a", 0.7f));
    glUniform1f(s_ru.lB, lg::getFloat("plugin:liquidglass:b", 2.3f));
    const float lensC = lg::getFloat("plugin:liquidglass:c", 5.2f);
    glUniform1f(s_ru.lC, lensC);
    glUniform1f(s_ru.lD, lg::getFloat("plugin:liquidglass:border_d", 30.0f));
    glUniform1f(s_ru.lFPower, lg::getFloat("plugin:liquidglass:fpower", 1.0f));
    glUniform1f(s_ru.logCME, lensC > 0.001f ? std::log(lensC * 2.718281828459045f) : 0.0f);
    glUniform1f(s_ru.glowW, lg::getFloat("plugin:liquidglass:glow_weight", 0.25f));
    glUniform1f(s_ru.glowE0, lg::getFloat("plugin:liquidglass:glow_edge0", 0.5f));
    glUniform1f(s_ru.glowE1, lg::getFloat("plugin:liquidglass:glow_edge1", -0.5f));
    glUniform1f(s_ru.glowT, lg::getFloat("plugin:liquidglass:glow_threshold", 0.5f));
    glUniform1f(s_ru.glowBias, lg::getFloat("plugin:liquidglass:border_glow_bias", 0.5f));
    glUniform1f(s_ru.throwMax, std::min(24.0f, (float)(rimOnly ? bandThick : scaledBorder) * 1.5f));
    // Windows path: single radius, no vec4. Fade applies to ALL borders.
    glUniform1f(s_ru.useRadii, 0.0f);
    glUniform4f(s_ru.radii, outerF, outerF, outerF, outerF);
    glUniform4f(s_ru.winRadii, (float)winRoundFb, (float)winRoundFb, (float)winRoundFb, (float)winRoundFb);
    glUniform1f(s_ru.fadeTop, lg::getFloat("plugin:liquidglass:border_fade_top", 1.0f));
    glUniform1f(s_ru.fadeMid, lg::getFloat("plugin:liquidglass:border_fade_mid", 0.2f));
    glUniform1f(s_ru.fadeBottom, lg::getFloat("plugin:liquidglass:border_fade_bottom", 1.0f));
    glUniform1f(s_ru.fadeAng, lg::getFloat("plugin:liquidglass:border_fade_angle", 33.0f));
    // Picture-frame relief: geometry-hash seed gives per-window variation.
    glUniform1f(s_ru.frameEnable, rimLight ? 0.0f : (float)lg::getInt("plugin:liquidglass:frame_enable", 1));
    glUniform1f(s_ru.frameScale, lg::getFloat("plugin:liquidglass:frame_scale", 1.0f));
    const int seedMode = lg::getInt("plugin:liquidglass:frame_seed_mode", 1);
    glUniform1f(s_ru.seed, seedMode == 1 ? frameSeed(box, lerp) : 0.37f);
    glUniform1f(s_ru.frieze, lg::getFloat("plugin:liquidglass:frame_frieze", -1.0f));
    glUniform1f(s_ru.gilt, lg::getFloat("plugin:liquidglass:frame_gilt", 1.0f));
    glUniform1f(s_ru.relief, lg::getFloat("plugin:liquidglass:frame_relief", 1.0f));
    // Apple rim light (window path). rim_width is the logical band width;
    // the line itself takes ~55% of it, floored at one physical pixel.
    glUniform1f(s_ru.rimLight, rimLight ? 1.0f : 0.0f);
    glUniform1f(s_ru.rimStrength, std::max(0.0f, lg::getFloat("plugin:liquidglass:rim_strength", 1.0f)));
    glUniform1f(s_ru.rimWidth,
                std::max(0.75f, lg::getFloat("plugin:liquidglass:glass_rim_width", 1.1f) * (float)monitor->m_scale));
    glUniform1f(s_ru.rimAngle, rimAngle);
    glUniform1f(s_ru.rimSplay, std::clamp(lg::getFloat("plugin:liquidglass:rim_splay", 0.22f), 0.0f, 1.0f));
    glUniform1f(s_ru.rimShade, std::clamp(lg::getFloat("plugin:liquidglass:rim_shade", 0.009f), 0.0f, 1.0f));
    glUniform1f(s_ru.rimAtInner, rimLight ? 1.0f : 0.0f);
    glUniform1f(s_ru.rimShift, rimLight ? (float)innerInset : 0.0f);
    glUniform1f(s_ru.rimSampleShift, rimLight ? (float)(rimOnly ? nativeBorder : bandThick) : 0.0f);
    glUniform1f(s_ru.rimOverlay, rimOnly ? 1.0f : 0.0f);
    // Window drop shadow: same matugen material as the pills, softer alpha.
    glUniform3f(s_ru.shCol, ((shColF >> 24) & 0xFF) / 255.f, ((shColF >> 16) & 0xFF) / 255.f,
                ((shColF >> 8) & 0xFF) / 255.f);
    glUniform1f(s_ru.shA, rimOnly ? 0.0f : ((shColF & 0xFF) / 255.f));
    glUniform2f(s_ru.shOff, shOxF, shOyF);
    glUniform1f(s_ru.shBlur, shBlurF);
    // Windows never carry notch flares (plain rounded rects). Push 0.5: the
    // band sits on the window's own edge pixels (see ring.frag).
    glUniform2f(s_ru.flare, 0.0f, 0.0f);
    // Rim-only puts the band exactly on the native border edge (push 0). The
    // glass-mode 0.5 push centres the legacy ring on its own AA edge, which
    // reads as a half-pixel outward offset once the rim is the only edge
    // treatment left.
    glUniform1f(s_ru.push, rimLight ? 0.0f : 0.5f);
    glBindVertexArray(s_vao);
    ringRegion.forEachRect([&](const pixman_box32_t& RECT) {
        gl->scissor(ctx, &RECT, ctx.m_data.transformDamage);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    });
    glBindVertexArray(0);

    // Blend state left as set (Hyprland re-sets its own per draw).
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    g_pHyprRenderer->setViewport(0, 0, (int)callerSize.x, (int)callerSize.y);
    return true;
}

bool wanted(Render::CRenderContext& ctx) {
    if (lg::getInt("plugin:liquidglass:window_borders", 1) != 1 || ctx.m_renderingSnapshot)
        return false;
    // The Apple rim is an independent edge treatment, not part of the glass
    // bodies: when liquid glass is master-disabled, keep the rim drawing and
    // let drawRing() drop to its cheap rim-only path.
    const bool rimOn = lg::getInt("plugin:liquidglass:rim_light", 1) == 1
        && lg::getFloat("plugin:liquidglass:rim_strength", 1.0f) > 0.0f;
    return lg::getInt("plugin:liquidglass:enabled", 1) == 1 || rimOn;
}

} // namespace

bool borderGlassReady() {
    ensure();
    return s_ok;
}

void hkRenderBorder1(CHyprOpenGLImpl* self, Render::CRenderContext& ctx, const CBox& box,
                     const Config::CGradientValueData& grad, CHyprOpenGLImpl::SBorderRenderData data) {
    if (!wanted(ctx) || data.borderSize < 1 || !borderGlassReady()) {
        g_origRenderBorder1(self, ctx, box, grad, data);
        return;
    }
    // Single-gradient borders fire once: draw glass, cancel the flat border.
    // (No pairing state: a repeated identical box here can only be a new
    // frame, and drawRing is idempotent across frames.)
    drawRing(self, ctx, box, grad, grad, 0.0f, data.borderSize, data.round, data.outerRound, data.a, data.round);
    s_lastBox = box;
    s_haveLast = true;
}

void hkRenderBorder2(CHyprOpenGLImpl* self, Render::CRenderContext& ctx, const CBox& box,
                     const Config::CGradientValueData& grad1, const Config::CGradientValueData& grad2, float lerp,
                     CHyprOpenGLImpl::SBorderRenderData data) {
    if (!wanted(ctx) || data.borderSize < 1 || !borderGlassReady()) {
        g_origRenderBorder2(self, ctx, box, grad1, grad2, lerp, data);
        return;
    }
    // Animated borders fire twice per border, same box back to back. First
    // call draws (both gradients + lerp in one pass); second only cancels.
    if (s_haveLast && sameBox(box, s_lastBox)) {
        s_haveLast = false;
        return;
    }
    drawRing(self, ctx, box, grad1, grad2, lerp, data.borderSize, data.round, data.outerRound, data.a, data.round);
    s_lastBox = box;
    s_haveLast = true;
}

// True when mon bit-matches a monitor the compositor still tracks. Compares
// the 16 shared_ptr bytes WITHOUT copying or dereferencing: during output
// reconfiguration the passed bytes can be garbage (freed control block —
// SEGV at +0x57 bumping it), and even the "safe" null-check form faulted
// (+0x28) because codegen dereferenced shared_ptr internals. memcmp can only
// read our stack + the core vector, so it cannot fault; a match implies the
// exact live {ptr, control} pair, safe to copy and forward.
bool monitorLive(const PHLMONITOR& mon) {
    try {
        auto& st = State::monitorState();
        if (!st)
            return false;
        for (const auto& m : st->monitors()) {
            if (__builtin_memcmp(&mon, &m, sizeof(PHLMONITOR)) == 0)
                return true;
        }
    } catch (...) {}
    return false;
}

void hkDropShadowDraw(CHyprDropShadowDecoration* self, Render::CRenderContext& ctx, PHLMONITOR monitor, const float& a,
                      const Render::SWindowRenderPresentation& presentation) {
    // A shadow draw can arrive with a monitor that is mid-teardown (output
    // reconfiguration during rapid VT switches): the PHLMONITOR bytes are
    // garbage and copying it for the forward call bumps a bogus refcount —
    // SEGV at +0x57, observed 2026-09-06 (hyprlandCrashReport100528, three
    // VT flips in 10s). Only forward for monitors the compositor still
    // tracks. .get() never dereferences and the comparison can't fault; a
    // dead monitor has nothing valid to draw on, so drop the draw.
    if (!monitorLive(monitor))
        return;
    if (lg::getInt("plugin:liquidglass:enabled", 1) == 1
        && lg::getInt("plugin:liquidglass:hide_window_shadows", 1) == 1)
        return; // cancel: no shadow pass element is submitted
    g_origDropShadowDraw(self, ctx, monitor, a, presentation);
}

} // namespace lg

#include "GooPass.hpp"
#include "GooConfig.hpp"
#include "Config.hpp" // lg::pluginHandle for notifications

#include <GLES3/gl32.h>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/gl/GLFramebuffer.hpp>

#include <array>
#include <cmath>

using namespace Render;
using namespace Render::GL;

namespace goo {

namespace {

// Unit-quad vertex shader (positions + texcoords span 0..1; proj maps the
// quad onto the target — fullscreen here). Mirrors liquid-glass's glass.vert.
constexpr const char* GOO_VERT = R"GLSL(
#version 300 es
layout(location = 0) in vec2 pos;
layout(location = 1) in vec2 texcoord;
uniform mat3 proj;
out vec2 v_texcoord;
void main() {
    v_texcoord = texcoord;
    gl_Position = vec4(proj * vec3(pos, 1.0), 1.0);
}
)GLSL";

// Directional 9-tap smear along the motion axis + perpendicular sine wobble.
// mix() with the sharp image by the envelope so strength 0 == passthrough.
constexpr const char* GOO_FRAG = R"GLSL(
#version 300 es
precision highp float;
in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;
uniform sampler2D uTex;
uniform vec2 uTexel;   // 1 / framebuffer dims
uniform vec2 uDir;     // motion axis, signed unit
uniform float uSmear;  // liquid margin in framebuffer px
uniform float uMix;    // 0 = sharp passthrough
uniform float uWobble; // unused (kept for config compatibility)
uniform float uPhase;  // unused
uniform vec2 uFbSize;
uniform int uRectCount;
uniform vec4 uRects[8]; // x,y,w,h framebuffer px, union of live windows
float sdBox2(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}
void main() {
    vec4 sharp = texture(uTex, v_texcoord);
    float margin = uSmear * uMix;
    if (uRectCount <= 0 || margin < 0.5) {
        fragColor = sharp;
        return;
    }
    vec2 p = v_texcoord * uFbSize;

    float best = 1e9;
    vec2 src = v_texcoord;
    for (int i = 0; i < 8; i++) {
        if (i >= uRectCount)
            break;
        vec4 r = uRects[i];
        vec2 c = r.xy + r.zw * 0.5;
        vec2 halfSize = r.zw * 0.5;
        vec2 h = halfSize + vec2(margin);
        // Directional tail: the trailing side grows more, so the window
        // silhouette stretches behind the motion instead of just inflating.
        if (uDir.x > 0.5)
            h.x = halfSize.x + margin * 1.35;
        else if (uDir.x < -0.5)
            h.x = halfSize.x + margin * 1.35;
        else if (uDir.y > 0.5 || uDir.y < -0.5)
            h.y = halfSize.y + margin * 1.35;
        float rad = min(h.x, h.y) * 0.55;
        float d = sdBox2(p - c, h, rad);
        if (d < best) {
            best = d;
            // Map the entire destination silhouette back onto the original
            // window content: the content inflates into the liquid shape.
            vec2 q = (p - c) / h;
            src = (c + q * halfSize) / uFbSize;
        }
    }
    if (best < 0.0)
        fragColor = texture(uTex, clamp(src, vec2(0.001), vec2(0.999)));
    else
        fragColor = sharp;
}
)GLSL";

// Droplet-tip fragment shader. Drawn fullscreen (v_texcoord = screen uv);
// the window interior and everything outside the funnel is discarded, so
// only funnel pixels blend. All geometry in raw framebuffer px (uFbSize).
//
// The funnel spans the window's leading edge (half-width uHW0 around uC0)
// converging to the single point uPC on the screen edge: f = d/uTipLen runs
// 0 at the edge to 1 at the point, center(f) = mix(uC0, uPC, f),
// halfWidth(f) = uHW0*(1-f). Profile pow(sin(pi*v), uCurve) is 0 at the
// flanks and 1 at the middle: concave sides meeting in one point (uCurve>1).
// Color is stretched edge-strip pixels; alpha fades across and toward the tip.
constexpr const char* TIP_FRAG = R"GLSL(
#version 300 es
precision highp float;
in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;
uniform sampler2D uTex;
uniform vec2 uFbSize; // framebuffer dims, px
uniform float uAxis;  // 0 = horizontal motion, 1 = vertical
uniform float uSEdge; // leading-edge plane, px along axis
uniform float uSign;  // +1 funnel extends toward +axis, -1 toward -axis
uniform float uTipLen;
uniform float uC0;    // leading-edge center across axis, px
uniform float uHW0;   // leading-edge half width, px
uniform float uPC;    // target point across axis (screen edge center), px
uniform float uCurve; // silhouette power
uniform float uStrip; // edge-strip pullback, px
uniform float uFade;  // envelope 0..1
void main() {
    vec2 px = v_texcoord * uFbSize;
    float s = uAxis < 0.5 ? px.x : px.y;
    float c = uAxis < 0.5 ? px.y : px.x;
    float d = (s - uSEdge) * uSign; // 0 at edge, tipLen at point
    if (d < 0.0 || d > uTipLen)
        discard;
    float f = d / uTipLen;
    float cc = mix(uC0, uPC, f);
    float hw = max(uHW0 * (1.0 - f), 0.5);
    float v = (c - (cc - hw)) / (2.0 * hw);
    if (v < 0.0 || v > 1.0)
        discard;
    float prof = pow(max(sin(3.14159265 * v), 0.0), uCurve);
    // Sample a thin strip just inside the edge, pinched toward the funnel
    // middle so the tip reads as pulled, not smeared.
    float srcS = uSEdge - uSign * uStrip * (0.25 + 0.75 * prof);
    float srcC = cc + (c - cc) * 0.8;
    vec2 srcPx = uAxis < 0.5 ? vec2(srcS, srcC) : vec2(srcC, srcS);
    vec3 rgb = texture(uTex, srcPx / uFbSize).rgb;
    float alpha = prof * (1.0 - f) * uFade;
    if (alpha <= 0.003)
        discard;
    fragColor = vec4(rgb, alpha);
}
)GLSL";

// Fullscreen projection: quad [0,1] -> clip [-1,1].
constexpr std::array<float, 9> FULLSCREEN_PROJECTION = {
    2.0f, 0.0f, 0.0f,
    0.0f, 2.0f, 0.0f,
    -1.0f, -1.0f, 1.0f,
};

GLuint fbId(const SP<IFramebuffer>& fb) {
    return dynamic_cast<CGLFramebuffer*>(fb.get())->getFBID();
}

GLint loc(GLuint program, const char* name) {
    return glGetUniformLocation(program, name);
}

struct SGooGL {
    SP<CShader>       shader;
    SP<IFramebuffer>  scratch;
    GLuint            vao = 0, vbo = 0;
    GLint             uProj = -1, uTex = -1, uTexel = -1, uDir = -1;
    GLint             uSmear = -1, uMix = -1, uWobble = -1, uPhase = -1;
    GLint             uRectCount = -1, uRects = -1, uFbSize = -1;
    bool              ok = false, failed = false;
};

// Intentionally leaked on unload (see main.cpp): deleting GL objects without
// a current context SEGVs. One instance serves all monitors sequentially.
SGooGL& gooGL() {
    static auto* s = new SGooGL();
    return *s;
}

void notifyOnce(const std::string& text) {
    static bool done = false;
    if (done)
        return;
    done = true;
    void* handle = lg::pluginHandle();
    if (handle)
        HyprlandAPI::addNotification(handle, text, CHyprColor{1, 0.2, 0.2, 1}, 5000);
}

bool ensureGooGL() {
    auto& g = gooGL();
    if (g.ok)
        return true;
    if (g.failed)
        return false;
    g.shader = makeShared<CShader>();
    if (!g.shader->createProgram(GOO_VERT, GOO_FRAG, true)) {
        notifyOnce("[gooworkspaces] goo.frag failed to compile — screen-space goo disabled");
        g.failed = true;
        return false;
    }
    const GLuint p = g.shader->program();
    g.uProj = loc(p, "proj");
    g.uTex = loc(p, "uTex");
    g.uTexel = loc(p, "uTexel");
    g.uDir = loc(p, "uDir");
    g.uSmear = loc(p, "uSmear");
    g.uMix = loc(p, "uMix");
    g.uWobble = loc(p, "uWobble");
    g.uPhase = loc(p, "uPhase");
    g.uRectCount = loc(p, "uRectCount");
    g.uRects = loc(p, "uRects");
    g.uFbSize = loc(p, "uFbSize");
    if (g.vao == 0) {
        static constexpr float QUAD[16] = {
            0.0f, 0.0f, 0.0f, 0.0f,
            1.0f, 0.0f, 1.0f, 0.0f,
            0.0f, 1.0f, 0.0f, 1.0f,
            1.0f, 1.0f, 1.0f, 1.0f,
        };
        glGenVertexArrays(1, &g.vao);
        glGenBuffers(1, &g.vbo);
        glBindVertexArray(g.vao);
        glBindBuffer(GL_ARRAY_BUFFER, g.vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(QUAD), QUAD, GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)0);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));
        glBindVertexArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
    }
    g.ok = true;
    return true;
}

} // namespace

CGooPassElement::CGooPassElement(TransitionManager* mgr, MONITORID mon, int side, bool vertical, std::vector<SMorphTip> tips)
    : m_mgr(mgr), m_mon(mon), m_side(side), m_vertical(vertical), m_tips(std::move(tips)) {
}

std::optional<CBox> CGooPassElement::boundingBox() {
    const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
    if (!mon || mon->m_id != m_mon)
        return std::nullopt;
    // Monitor-local logical px, fullscreen. opaqueRegion stays empty (we only
    // mix), so nothing after us is ever occlusion-culled.
    return CBox{0.0, 0.0, (double)mon->m_size.x, (double)mon->m_size.y};
}

std::vector<UP<IPassElement>> CGooPassElement::draw() {
    if (!m_mgr || g_pHyprRenderer->m_bRenderingSnapshot)
        return {};
    const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
    if (!mon || mon->m_id != m_mon || mon->isMirror())
        return {};

    const double dur = (double)getFloat(Key::DURATION_MS, 600.0f);
    auto tOpt        = m_mgr->progress(m_mon, dur);
    if (!tOpt)
        return {};
    const double t = *tOpt;
    if (t <= 0.0)
        return {};
    if (t >= 1.0) {
        // Endpoint frame: envelope is zero, so there is nothing to draw.
        // sustainTick releases the transition after this frame has landed;
        // finishing here restores the warp before the endpoint is painted.
        return {};
    }

    const float strength = getFloat(Key::GOO_STRENGTH, 0.0f);
    if (!(strength > 0.0f))
        return {};
    // Peak envelope at mid-transition; ~zero cost outside it.
    const double env = std::pow(std::sin(3.14159265358979323846 * t), 1.5);
    const float mix  = (float)(strength * env);
    if (!(mix > 0.01f))
        return {};

    if (!ensureGooGL())
        return {};

    const auto caller = g_pHyprRenderer->m_renderData.currentFB;
    if (!caller)
        return {};
    const int W = (int)caller->m_size.x, H = (int)caller->m_size.y;
    if (W <= 0 || H <= 0)
        return {};

    auto& g = gooGL();
    if (!g.scratch)
        g.scratch = g_pHyprRenderer->createFB("gooworkspaces-scratch");
    if (!g.scratch)
        return {};
    if ((int)g.scratch->m_size.x != W || (int)g.scratch->m_size.y != H) {
        const DRMFormat fmt = caller->m_drmFormat != DRM_FORMAT_INVALID ? caller->m_drmFormat : DRM_FORMAT_ABGR8888;
        g.scratch->alloc(W, H, fmt);
        if ((int)g.scratch->m_size.x != W || (int)g.scratch->m_size.y != H)
            return {};
    }

    // Save GL state we touch; everything is restored before returning so the
    // top layers, cursor and subsequent monitors render undisturbed.
    const GLboolean blendWas   = glIsEnabled(GL_BLEND);
    const GLboolean scissorWas = glIsEnabled(GL_SCISSOR_TEST);
    GLint srcRgb = GL_ONE, dstRgb = GL_ZERO, srcA = GL_ONE, dstA = GL_ZERO;
    glGetIntegerv(GL_BLEND_SRC_RGB, &srcRgb);
    glGetIntegerv(GL_BLEND_DST_RGB, &dstRgb);
    glGetIntegerv(GL_BLEND_SRC_ALPHA, &srcA);
    glGetIntegerv(GL_BLEND_DST_ALPHA, &dstA);
    GLint vp[4] = {0, 0, W, H};
    glGetIntegerv(GL_VIEWPORT, vp);
    GLint prevProg = 0;
    glGetIntegerv(GL_CURRENT_PROGRAM, &prevProg);

    // Capture the composited-so-far frame, then rewrite it smeared.
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbId(caller));
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbId(g.scratch));
    glBlitFramebuffer(0, 0, W, H, 0, 0, W, H, GL_COLOR_BUFFER_BIT, GL_NEAREST);

    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    g_pHyprOpenGL->setViewport(0, 0, W, H);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_BLEND);

    const float scale = mon->m_scale > 0.0f ? mon->m_scale : 1.0f;
    // Spreads are configured in logical px; convert to texels (fb px / dim).
    const float spreadFb = getFloat(Key::GOO_SMEAR, 20.0f) * scale;
    const float wobbleFb = getFloat(Key::GOO_WOBBLE, 6.0f) * scale;
    const float axisLen  = (float)(m_vertical ? H : W);
    const float perpLen  = (float)(m_vertical ? W : H);
    glActiveTexture(GL_TEXTURE0);
    g.scratch->getTexture()->bind();
    g.scratch->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    g.scratch->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    auto shader = g_pHyprOpenGL->useShader(g.shader);
    glUniformMatrix3fv(g.uProj, 1, GL_FALSE, FULLSCREEN_PROJECTION.data());
    glUniform1i(g.uTex, 0);
    glUniform2f(g.uTexel, 1.0f / (float)W, 1.0f / (float)H);
    const float s = m_side >= 0 ? 1.0f : -1.0f;
    if (m_vertical)
        glUniform2f(g.uDir, 0.0f, s);
    else
        glUniform2f(g.uDir, s, 0.0f);
    glUniform1f(g.uSmear, spreadFb); // liquid margin in fb px
    glUniform1f(g.uMix, mix);
    glUniform1f(g.uWobble, wobbleFb);
    glUniform1f(g.uPhase, (float)t);
    glUniform2f(g.uFbSize, (float)W, (float)H);
    int rectCount = 0;
    float rects[32] = {0};
    for (const auto& tip : m_tips) {
        if (rectCount >= 8)
            break;
        if (tip.role != Role::INCOMING)
            continue;
        const float rx = (float)((tip.box.x - mon->m_position.x) * scale);
        const float ry = (float)((tip.box.y - mon->m_position.y) * scale);
        const float rw = (float)(tip.box.w * scale);
        const float rh = (float)(tip.box.h * scale);
        if (rw < 2.0f || rh < 2.0f)
            continue;
        rects[rectCount * 4 + 0] = rx;
        rects[rectCount * 4 + 1] = ry;
        rects[rectCount * 4 + 2] = rw;
        rects[rectCount * 4 + 3] = rh;
        rectCount++;
    }
    glUniform1i(g.uRectCount, rectCount);
    if (rectCount > 0)
        glUniform4fv(g.uRects, rectCount, rects);
    glBindVertexArray(g.vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);

    // Restore.
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    glViewport(vp[0], vp[1], vp[2], vp[3]);
    if (scissorWas)
        glEnable(GL_SCISSOR_TEST);
    if (blendWas)
        glEnable(GL_BLEND);
    glBlendFuncSeparate(srcRgb, dstRgb, srcA, dstA);
    glUseProgram((GLuint)prevProg);
    return {};
}

// --- droplet tip ------------------------------------------------------------

struct STipGL {
    SP<CShader>      shader;
    SP<IFramebuffer> scratch;
    GLuint           vao = 0, vbo = 0;
    GLint            uProj = -1, uTex = -1, uFbSize = -1, uAxis = -1, uSEdge = -1, uSign = -1;
    GLint            uTipLen = -1, uC0 = -1, uHW0 = -1, uPC = -1, uCurve = -1, uStrip = -1, uFade = -1;
    bool             ok = false, failed = false;
};

STipGL& tipGL() {
    static auto* s = new STipGL();
    return *s;
}

void notifyTipOnce(const std::string& text) {
    static bool done = false;
    if (done)
        return;
    done = true;
    void* handle = lg::pluginHandle();
    if (handle)
        HyprlandAPI::addNotification(handle, text, CHyprColor{1, 0.2, 0.2, 1}, 5000);
}

bool ensureTipGL() {
    auto& g = tipGL();
    if (g.ok)
        return true;
    if (g.failed)
        return false;
    g.shader = makeShared<CShader>();
    if (!g.shader->createProgram(GOO_VERT, TIP_FRAG, true)) {
        notifyTipOnce("[gooworkspaces] tip shader failed to compile — droplet tips disabled");
        g.failed = true;
        return false;
    }
    const GLuint p = g.shader->program();
    g.uProj   = loc(p, "proj");
    g.uTex    = loc(p, "uTex");
    g.uFbSize = loc(p, "uFbSize");
    g.uAxis   = loc(p, "uAxis");
    g.uSEdge  = loc(p, "uSEdge");
    g.uSign   = loc(p, "uSign");
    g.uTipLen = loc(p, "uTipLen");
    g.uC0 = loc(p, "uC0");
    g.uHW0 = loc(p, "uHW0");
    g.uPC = loc(p, "uPC");
    g.uCurve  = loc(p, "uCurve");
    g.uStrip  = loc(p, "uStrip");
    g.uFade   = loc(p, "uFade");
    if (g.vao == 0) {
        static constexpr float QUAD[16] = {
            0.0f, 0.0f, 0.0f, 0.0f,
            1.0f, 0.0f, 1.0f, 0.0f,
            0.0f, 1.0f, 0.0f, 1.0f,
            1.0f, 1.0f, 1.0f, 1.0f,
        };
        glGenVertexArrays(1, &g.vao);
        glGenBuffers(1, &g.vbo);
        glBindVertexArray(g.vao);
        glBindBuffer(GL_ARRAY_BUFFER, g.vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(QUAD), QUAD, GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)0);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));
        glBindVertexArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
    }
    g.ok = true;
    return true;
}

CGooTipElement::CGooTipElement(TransitionManager* mgr, MONITORID mon, int side, bool vertical, std::vector<SMorphTip> tips)
    : m_mgr(mgr), m_mon(mon), m_side(side), m_vertical(vertical), m_tips(std::move(tips)) {
}

std::optional<CBox> CGooTipElement::boundingBox() {
    const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
    if (!mon || mon->m_id != m_mon || m_tips.empty())
        return std::nullopt;
    // Union of window rects, their funnels to the edge-center point P, and
    // the trailing points behind (monitor-local logical px). Overestimates —
    // harmless, damage is fullscreen anyway while a transition runs (the
    // morph damages the monitor every frame).
    const Vector2D P  = edgeCenterPoint(mon->m_position, mon->m_size, m_side, m_vertical);
    const double px   = P.x - mon->m_position.x, py = P.y - mon->m_position.y;
    const double trail = (double)getFloat(Key::TIP_MAX, 4000.0f) * 0.5;
    bool first        = true;
    double ux0 = 0, uy0 = 0, ux1 = 0, uy1 = 0;
    for (const auto& tip : m_tips) {
        const double lx = tip.box.x - mon->m_position.x, ly = tip.box.y - mon->m_position.y;
        const double lw = tip.box.w, lh = tip.box.h;
        if (lw <= 0 || lh <= 0)
            continue;
        double x0 = std::min(lx, px), x1 = std::max(lx + lw, px);
        double y0 = std::min(ly, py), y1 = std::max(ly + lh, py);
        // Trailing point reaches behind the window (outgoing only, but
        // overestimating for incoming is harmless).
        if (m_vertical) {
            if (m_side >= 0)
                y0 = std::min(y0, ly - trail);
            else
                y1 = std::max(y1, ly + lh + trail);
        } else {
            if (m_side >= 0)
                x0 = std::min(x0, lx - trail);
            else
                x1 = std::max(x1, lx + lw + trail);
        }
        if (first) {
            ux0 = x0;
            uy0 = y0;
            ux1 = x1;
            uy1 = y1;
            first = false;
        } else {
            ux0 = std::min(ux0, x0);
            uy0 = std::min(uy0, y0);
            ux1 = std::max(ux1, x1);
            uy1 = std::max(uy1, y1);
        }
    }
    if (first || ux1 <= ux0 || uy1 <= uy0)
        return std::nullopt;
    return CBox{ux0, uy0, ux1 - ux0, uy1 - uy0};
}

std::vector<UP<IPassElement>> CGooTipElement::draw() {
    if (!m_mgr || g_pHyprRenderer->m_bRenderingSnapshot)
        return {};
    const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
    if (!mon || mon->m_id != m_mon || mon->isMirror() || m_tips.empty())
        return {};

    const double dur = (double)getFloat(Key::DURATION_MS, 600.0f);
    auto tOpt        = m_mgr->progress(m_mon, dur);
    if (!tOpt)
        return {};
    const double t = *tOpt;
    if (t <= 0.0)
        return {};
    if (t >= 1.0) {
        m_mgr->finish(m_mon);
        return {};
    }
    if (getInt(Key::TIP_ENABLE, 1) == 0)
        return {};

    if (!ensureTipGL())
        return {};

    const auto caller = g_pHyprRenderer->m_renderData.currentFB;
    if (!caller)
        return {};
    const int W = (int)caller->m_size.x, H = (int)caller->m_size.y;
    if (W <= 0 || H <= 0)
        return {};

    auto& tg = tipGL();
    if (!tg.scratch)
        tg.scratch = g_pHyprRenderer->createFB("gooworkspaces-tip");
    if (!tg.scratch)
        return {};
    if ((int)tg.scratch->m_size.x != W || (int)tg.scratch->m_size.y != H) {
        const DRMFormat fmt = caller->m_drmFormat != DRM_FORMAT_INVALID ? caller->m_drmFormat : DRM_FORMAT_ABGR8888;
        tg.scratch->alloc(W, H, fmt);
        if ((int)tg.scratch->m_size.x != W || (int)tg.scratch->m_size.y != H)
            return {};
    }

    const GLboolean blendWas   = glIsEnabled(GL_BLEND);
    const GLboolean scissorWas = glIsEnabled(GL_SCISSOR_TEST);
    GLint srcRgb = GL_ONE, dstRgb = GL_ZERO, srcA = GL_ONE, dstA = GL_ZERO;
    glGetIntegerv(GL_BLEND_SRC_RGB, &srcRgb);
    glGetIntegerv(GL_BLEND_DST_RGB, &dstRgb);
    glGetIntegerv(GL_BLEND_SRC_ALPHA, &srcA);
    glGetIntegerv(GL_BLEND_DST_ALPHA, &dstA);
    GLint vp[4] = {0, 0, W, H};
    glGetIntegerv(GL_VIEWPORT, vp);
    GLint prevProg = 0;
    glGetIntegerv(GL_CURRENT_PROGRAM, &prevProg);

    // Freeze the composited-so-far frame; tips sample edge strips from it.
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbId(caller));
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbId(tg.scratch));
    glBlitFramebuffer(0, 0, W, H, 0, 0, W, H, GL_COLOR_BUFFER_BIT, GL_NEAREST);

    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    g_pHyprOpenGL->setViewport(0, 0, W, H);
    // Straight-alpha tip compositing; restored below.
    glEnable(GL_BLEND);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    // This frame's damage in monitor-local fb px: quads draw scissored to it
    // (same convention as the glass pass). Outside damage nothing presents.
    const CBox dmgExt = g_pHyprRenderer->m_renderData.damage.getExtents();

    const float scale  = mon->m_scale > 0.0f ? mon->m_scale : 1.0f;
    const float sgn    = m_side >= 0 ? 1.0f : -1.0f;
    const float curve  = getFloat(Key::TIP_CURVE, 1.5f);
    const float tipMax = getFloat(Key::TIP_MAX, 4000.0f) * scale;
    const float axisLen = (float)(m_vertical ? H : W);

    glActiveTexture(GL_TEXTURE0);
    tg.scratch->getTexture()->bind();
    tg.scratch->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    tg.scratch->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    auto shader = g_pHyprOpenGL->useShader(tg.shader);
    glUniformMatrix3fv(tg.uProj, 1, GL_FALSE, FULLSCREEN_PROJECTION.data());
    glUniform1i(tg.uTex, 0);
    glUniform2f(tg.uFbSize, (float)W, (float)H);
    glUniform1f(tg.uAxis, m_vertical ? 1.0f : 0.0f);
    glUniform1f(tg.uSign, sgn);
    glUniform1f(tg.uCurve, curve > 0.0f ? curve : 1.5f);

    // The edge-center point P (fb px, cross axis): every funnel converges here.
    const Vector2D Pl  = edgeCenterPoint(mon->m_position, mon->m_size, m_side, m_vertical);
    const float pCross = (float)((m_vertical ? Pl.x - mon->m_position.x : Pl.y - mon->m_position.y) * scale);

    auto smooth01 = [](double x) {
        if (x <= 0.0)
            return 0.0;
        if (x >= 1.0)
            return 1.0;
        return x * x * (3.0 - 2.0 * x);
    };
    const double fadeIn = t < 0.05 ? t / 0.05 : 1.0;

    auto drawFunnel = [&](float edge, float c0, float hw0, float pc, float fsign, float maxLen, double lenEnv, double fade) {
        if (!(hw0 > 2.0f) || !(maxLen > 2.0f) || !(fade > 0.0))
            return;
        const float len = maxLen * (float)lenEnv;
        if (!(len > 2.0f))
            return;
        const float strip = std::min(std::max(len * 0.15f, 4.0f * scale), 28.0f * scale);
        glUniform1f(tg.uSEdge, edge);
        glUniform1f(tg.uTipLen, len);
        glUniform1f(tg.uC0, c0);
        glUniform1f(tg.uHW0, hw0);
        glUniform1f(tg.uPC, pc);
        glUniform1f(tg.uStrip, strip);
        glUniform1f(tg.uFade, (float)fade);
        glBindVertexArray(tg.vao);
        if (dmgExt.w > 0 && dmgExt.h > 0) {
            const int cx0 = (int)std::floor(dmgExt.x), cy0 = (int)std::floor(dmgExt.y);
            const int cx1 = (int)std::ceil(dmgExt.x + dmgExt.w), cy1 = (int)std::ceil(dmgExt.y + dmgExt.h);
            if (cx1 > cx0 && cy1 > cy0) {
                const pixman_box32_t clip{(int32_t)cx0, (int32_t)cy0, (int32_t)cx1, (int32_t)cy1};
                g_pHyprOpenGL->scissor(&clip, g_pHyprRenderer->m_renderData.transformDamage);
                glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
                g_pHyprOpenGL->setCapStatus(GL_SCISSOR_TEST, false);
            }
        } else {
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        }
        glBindVertexArray(0);
    };

    for (const auto& tip : m_tips) {
        // Global logical -> framebuffer px.
        const float rx = (float)((tip.box.x - mon->m_position.x) * scale);
        const float ry = (float)((tip.box.y - mon->m_position.y) * scale);
        const float rw = (float)(tip.box.w * scale);
        const float rh = (float)(tip.box.h * scale);
        if (!(rw > 4.0f) || !(rh > 4.0f))
            continue;
        float leadEdge, trailEdge, cc, half;
        if (m_vertical) {
            leadEdge  = sgn >= 0 ? ry + rh : ry;
            trailEdge = sgn >= 0 ? ry : ry + rh;
            cc        = rx + rw * 0.5f;
            half      = rw * 0.5f;
        } else {
            leadEdge  = sgn >= 0 ? rx + rw : rx;
            trailEdge = sgn >= 0 ? rx : rx + rw;
            cc        = ry + rh * 0.5f;
            half      = rh * 0.5f;
        }
        if (!(half > 2.0f))
            continue;
        const float screenEdge = sgn >= 0 ? axisLen : 0.0f;
        if (tip.role == Role::INCOMING) {
            // Emergence: the arriving window comes out of the edge point —
            // strongest at first contact, gone once it lands.
            const float dist = (screenEdge - leadEdge) * sgn;
            if (dist > 4.0f) {
                const double fade = fadeIn * std::max(0.0, 1.0 - t / 0.55);
                drawFunnel(leadEdge, cc, half, pCross, sgn, std::min(dist, tipMax), 1.0, fade);
            }
        } else {
            // Leading funnel first: the closest edge reaches the point early.
            const float dist = (screenEdge - leadEdge) * sgn;
            if (dist > 4.0f) {
                const double fade = fadeIn * (t > 0.7 ? std::max(0.0, (1.0 - t) / 0.3) : 1.0);
                drawFunnel(leadEdge, cc, half, pCross, sgn, std::min(dist, tipMax), smooth01(t / 0.35), fade);
            }
            // Trailing point, delayed and shorter: both edges end pointed so
            // the window flows like a lens being sucked through the edge.
            const double fadeB = fadeIn * (t > 0.75 ? std::max(0.0, (1.0 - t) / 0.25) : 1.0);
            drawFunnel(trailEdge, cc, half, cc, -sgn, tipMax * 0.5f, smooth01((t - 0.15) / 0.4), fadeB);
        }
    }

    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    glViewport(vp[0], vp[1], vp[2], vp[3]);
    if (scissorWas)
        glEnable(GL_SCISSOR_TEST);
    if (!blendWas)
        glDisable(GL_BLEND);
    glBlendFuncSeparate(srcRgb, dstRgb, srcA, dstA);
    glUseProgram((GLuint)prevProg);
    return {};
}

} // namespace goo

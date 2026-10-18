#include "GooPass.hpp"
#include "Config.hpp"

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
uniform float uSmear;  // tap spread in texels
uniform float uMix;    // 0 = sharp passthrough
uniform float uWobble; // perpendicular wobble amplitude in texels
uniform float uPhase;  // transition progress 0..1 (wobble phase)
void main() {
    vec2 perp = vec2(-uDir.y, uDir.x);
    float wob = sin((v_texcoord.x + v_texcoord.y) * 40.0 + uPhase * 6.28318) * uWobble * uMix;
    vec2 base = v_texcoord + perp * wob;
    vec2 off = uDir * uSmear;
    vec3 acc = texture(uTex, base).rgb * 0.2270270270;
    acc += texture(uTex, base + off * 0.3846153846).rgb * 0.1945945946;
    acc += texture(uTex, base - off * 0.3846153846).rgb * 0.1945945946;
    acc += texture(uTex, base + off * 0.7692307692).rgb * 0.1216216216;
    acc += texture(uTex, base - off * 0.7692307692).rgb * 0.1216216216;
    acc += texture(uTex, base + off).rgb * 0.0540540541;
    acc += texture(uTex, base - off).rgb * 0.0540540541;
    acc += texture(uTex, base + off * 1.5).rgb * 0.0162162162;
    acc += texture(uTex, base - off * 1.5).rgb * 0.0162162162;
    float alpha = texture(uTex, base).a;
    vec3 sharp = texture(uTex, v_texcoord).rgb;
    fragColor = vec4(mix(sharp, acc, uMix), alpha);
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
    void* handle = pluginHandle();
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

CGooPassElement::CGooPassElement(TransitionManager* mgr, MONITORID mon, int side, bool vertical)
    : m_mgr(mgr), m_mon(mon), m_side(side), m_vertical(vertical) {
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

    const double dur = (double)getFloat(Key::DURATION_MS, 550.0f);
    auto tOpt        = m_mgr->progress(m_mon, dur);
    if (!tOpt)
        return {};
    const double t = *tOpt;
    if (t <= 0.0 || t >= 1.0)
        return {};

    const float strength = getFloat(Key::GOO_STRENGTH, 0.4f);
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
    glUniform1f(g.uSmear, axisLen > 0.0f ? spreadFb / axisLen : 0.0f);
    glUniform1f(g.uMix, mix);
    glUniform1f(g.uWobble, perpLen > 0.0f ? wobbleFb / perpLen : 0.0f);
    glUniform1f(g.uPhase, (float)t);
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

} // namespace goo

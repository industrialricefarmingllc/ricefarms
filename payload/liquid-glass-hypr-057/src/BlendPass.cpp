#include "BlendPass.hpp"
#include "Config.hpp"
#include "Shaders.hpp"

#include <GLES3/gl32.h>
#include <pixman.h>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprutils/math/Misc.hpp>

#include <array>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <string>
#include <unordered_map>
#include <unistd.h>

using namespace Render;
using namespace Render::GL;

namespace {

// Fullscreen unit quad: positions [0,1] -> clip [-1,1] with proj.
static constexpr std::array<float, 9> FULLSCREEN_PROJECTION = {
    2.0f, 0.0f, 0.0f,
    0.0f, 2.0f, 0.0f,
    -1.0f, -1.0f, 1.0f,
};

struct SBlendState {
    SP<CShader> shader;
    GLint       proj = -1, backdrop = -1, source = -1, alpha = -1;
    GLint       srcScale = -1, srcOffset = -1;
    GLuint      vao = 0, vbo = 0;
    bool        ok = false;
    // One full-monitor capture per output; reused every frame.
    std::unordered_map<MONITORID, SP<IFramebuffer>> backdrops;

    // Deliberately leaked: GL objects must not be destroyed outside a render
    // context (see the note in main.cpp).
    ~SBlendState() = default;
};

SBlendState* state() {
    static SBlendState* s = new SBlendState();
    return s;
}

GLuint fbId(const SP<IFramebuffer>& fb) {
    return dynamic_cast<CGLFramebuffer*>(fb.get())->getFBID();
}

void ensure() {
    auto* s = state();
    if (s->ok)
        return;
    if (!s->shader)
        s->shader = makeShared<CShader>();
    if (!s->shader->createProgram(SHADERS.at("glass.vert"), SHADERS.at("blend.frag"), true)) {
        lg::notify("liquidglass: blend.frag failed to compile — wallpaper wash stays source-over");
        return;
    }

    const GLuint p = s->shader->program();
    s->proj     = glGetUniformLocation(p, "proj");
    s->backdrop = glGetUniformLocation(p, "uBackdrop");
    s->source   = glGetUniformLocation(p, "uSource");
    s->alpha    = glGetUniformLocation(p, "uAlpha");
    s->srcScale = glGetUniformLocation(p, "uSourceScale");
    s->srcOffset = glGetUniformLocation(p, "uSourceOffset");

    static constexpr float QUAD[16] = {
        0.0f, 0.0f, 0.0f, 0.0f,
        1.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 1.0f,
        1.0f, 1.0f, 1.0f, 1.0f,
    };
    glGenVertexArrays(1, &s->vao);
    glGenBuffers(1, &s->vbo);
    glBindVertexArray(s->vao);
    glBindBuffer(GL_ARRAY_BUFFER, s->vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(QUAD), QUAD, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));
    glBindVertexArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);

    s->ok = true;
}

} // namespace

bool lg::blendReady() {
    // Escape hatch for a bad login: create
    // ~/.config/liquid-glass-hypr/blend-overlay.disabled and restart.
    static const std::string disabled =
        std::string(getenv("HOME") ? getenv("HOME") : "") + "/.config/liquid-glass-hypr/blend-overlay.disabled";
    if (access(disabled.c_str(), F_OK) == 0) {
        static bool logged = false;
        if (!logged) {
            logged = true;
            std::ofstream("/tmp/liquidglass-blend.log", std::ios::app) << "blendReady: disabled file present\n";
        }
        return false;
    }

    ensure();
    static bool logged = false;
    if (!logged) {
        logged = true;
        std::ofstream("/tmp/liquidglass-blend.log", std::ios::app) << "blendReady: ok=" << state()->ok << "\n";
    }
    return state()->ok;
}

void lg::renderBlend(const SP<ITexture>& source, float alpha) {
    ensure();
    auto* s = state();
    if (!s->ok || !source)
        return;

    auto* r = g_pHyprRenderer.get();
    const auto monitor = r->m_renderData.pMonitor.lock();
    const auto caller  = r->m_renderData.currentFB;
    if (!monitor || !caller)
        return;

    const CBox damage = r->m_renderData.damage.getExtents();
    if (damage.w <= 0 || damage.h <= 0)
        return;

    const int w = (int)caller->m_size.x;
    const int h = (int)caller->m_size.y;
    if (w <= 0 || h <= 0)
        return;

    {
        static int n = 0;
        if (n++ < 5) {
            std::ofstream("/tmp/liquidglass-blend.log", std::ios::app)
                << "render " << w << "x" << h << " dmg " << damage.x << "," << damage.y << " " << damage.w << "x"
                << damage.h << " src " << source->m_size.x << "x" << source->m_size.y
                << " opaque=" << source->m_opaque << " alpha=" << alpha
                << " tx=" << (int)source->m_transform << "\n";
        }
    }

    auto& backdrop = s->backdrops[monitor->m_id];
    if (!backdrop)
        backdrop = r->createFB("liquidglass-blend-backdrop");
    if (!backdrop)
        return;
    if (backdrop->m_size.x != w || backdrop->m_size.y != h)
        backdrop->alloc(w, h, caller->m_drmFormat);
    if (!backdrop->getTexture())
        return;

    // Capture the pixels already behind the layer (windows + earlier layers)
    // before we overwrite them with the blended result.
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbId(caller));
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbId(backdrop));
    glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);

    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    g_pHyprOpenGL->setViewport(0, 0, w, h);

    // The source surface and the backdrop are both full-screen: v_texcoord
    // 0..1 maps straight across. projectBoxToTarget handles output rotation.
    const auto transform = Math::wlTransformToHyprutils(Math::invertTransform(monitor->m_transform));
    Mat3x3     proj      = r->projectBoxToTarget(CBox{0, 0, (double)w, (double)h}, transform);

    auto shader = g_pHyprOpenGL->useShader(s->shader);
    glUniformMatrix3fv(s->proj, 1, GL_TRUE, proj.getMatrix().data());

    glActiveTexture(GL_TEXTURE0);
    backdrop->getTexture()->bind();
    backdrop->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    backdrop->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glUniform1i(s->backdrop, 0);

    glActiveTexture(GL_TEXTURE1);
    source->bind();
    source->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    source->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glUniform1i(s->source, 1);

    glUniform1f(s->alpha, std::clamp(alpha, 0.F, 1.F));

    // Wayland buffer transform: Hyprland's normal path applies this to the
    // texture; sample the surface with the same orientation.
    float sx = 1.F, sy = 1.F, ox = 0.F, oy = 0.F;
    switch (source->m_transform) {
        case HYPRUTILS_TRANSFORM_FLIPPED: sx = -1.F; ox = 1.F; break;
        case HYPRUTILS_TRANSFORM_180: sx = -1.F; sy = -1.F; ox = 1.F; oy = 1.F; break;
        case HYPRUTILS_TRANSFORM_FLIPPED_180: sy = -1.F; oy = 1.F; break;
        default: break; // normal; rotated buffers are not expected for a layer surface
    }
    glUniform2f(s->srcScale, sx, sy);
    glUniform2f(s->srcOffset, ox, oy);

    // The shader writes the final composite, so no source-over blending.
    glDisable(GL_BLEND);
    glBindVertexArray(s->vao);

    // Only write the damaged region. The old full-screen draw re-blended the
    // previous overlay on every cursor/clock tick, which is what made the
    // wash visibly pump.
    const int cx0 = std::clamp((int)std::floor(damage.x), 0, w);
    const int cy0 = std::clamp((int)std::floor(damage.y), 0, h);
    const int cx1 = std::clamp((int)std::ceil(damage.x + damage.w), 0, w);
    const int cy1 = std::clamp((int)std::ceil(damage.y + damage.h), 0, h);
    if (cx1 > cx0 && cy1 > cy0) {
        const pixman_box32_t clip{cx0, cy0, cx1, cy1};
        g_pHyprOpenGL->scissor(&clip, g_pHyprRenderer->m_renderData.transformDamage);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        g_pHyprOpenGL->setCapStatus(GL_SCISSOR_TEST, false);
    }
    glBindVertexArray(0);

    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    g_pHyprOpenGL->setViewport(0, 0, w, h);

    // Hyprland's default surface blend state (premultiplied). Leave the
    // texture unit back on 0 as well; the next pass may not set either.
    glActiveTexture(GL_TEXTURE0);
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
}

CBlendPassElement::CBlendPassElement(const SData& data) : m_data(data) {}

std::vector<UP<IPassElement>> CBlendPassElement::draw() {
    lg::renderBlend(m_data.source, m_data.alpha);
    return {};
}

std::optional<CBox> CBlendPassElement::boundingBox() {
    const auto monitor = g_pHyprRenderer->m_renderData.pMonitor.lock();
    if (!monitor)
        return std::nullopt;
    const float scale = monitor->m_scale > 0.0f ? monitor->m_scale : 1.0f;
    return CBox{0.0, 0.0, monitor->m_transformedSize.x / scale, monitor->m_transformedSize.y / scale};
}

#include "WindowEink.hpp"
#include "Shaders.hpp"

#include <GLES3/gl32.h>
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/workspace/HLWorkspace.hpp>
#include <hyprland/src/desktop/view/window/WindowPresentation.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprutils/math/Misc.hpp>
#include <hyprutils/math/Mat3x3.hpp>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <cmath>
#include <functional>
#include <memory>
#include <fstream>

namespace {

SP<CShader>*              g_shader = nullptr;
SP<Render::IFramebuffer>* g_fbo = nullptr;
GLuint             g_vao = 0, g_vbo = 0;
GLint              g_uProj = -1, g_uTex = -1, g_uSize = -1, g_uRadius = -1;
bool               g_ok = false;

GLuint fbId(const SP<Render::IFramebuffer>& fb) {
    return dynamic_cast<Render::GL::CGLFramebuffer*>(fb.get())->getFBID();
}

bool ensureResources() {
    if (g_ok)
        return true;

    if (!g_shader)
        g_shader = new SP<CShader>(makeShared<CShader>());
    if (!(*g_shader)->createProgram(SHADERS.at("glass.vert"), SHADERS.at("eink.frag"), true))
        return false;

    const GLuint p = (*g_shader)->program();
    g_uProj = glGetUniformLocation(p, "proj");
    g_uTex = glGetUniformLocation(p, "tex");
    g_uSize = glGetUniformLocation(p, "uSize");
    g_uRadius = glGetUniformLocation(p, "uRadius");

    if (g_vao == 0) {
        static constexpr float QUAD[16] = {
            0.0f, 0.0f, 0.0f, 0.0f,
            1.0f, 0.0f, 1.0f, 0.0f,
            0.0f, 1.0f, 0.0f, 1.0f,
            1.0f, 1.0f, 1.0f, 1.0f,
        };
        glGenVertexArrays(1, &g_vao);
        glGenBuffers(1, &g_vbo);
        glBindVertexArray(g_vao);
        glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(QUAD), QUAD, GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)0);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));
        glBindVertexArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
    }

    g_ok = true;
    return true;
}

void drawPerDamageRect(Render::CRenderContext& ctx, const CBox& quad, const std::function<void()>& draw) {
    if (ctx.m_data.damage.empty()) {
        draw();
        return;
    }

    const int qx0 = (int)std::floor(quad.x);
    const int qy0 = (int)std::floor(quad.y);
    const int qx1 = (int)std::ceil(quad.x + quad.w);
    const int qy1 = (int)std::ceil(quad.y + quad.h);

    ctx.m_data.damage.forEachRect([&](const pixman_box32_t& RECT) {
        const int cx0 = std::max(qx0, (int)RECT.x1);
        const int cy0 = std::max(qy0, (int)RECT.y1);
        const int cx1 = std::min(qx1, (int)RECT.x2);
        const int cy1 = std::min(qy1, (int)RECT.y2);
        if (cx1 <= cx0 || cy1 <= cy0)
            return;
        const pixman_box32_t clip{(int32_t)cx0, (int32_t)cy0, (int32_t)cx1, (int32_t)cy1};
        Render::GL::g_pHyprOpenGL->scissor(ctx, &clip, ctx.m_data.transformDamage);
        draw();
    });
}

void drawEink(Render::CRenderContext& ctx, const SEinkDraw& d) {
    if (!ensureResources())
        return;

    const auto monitor = ctx.m_data.pMonitor.lock();
    const auto caller = ctx.m_data.currentFB;
    if (!monitor || !caller)
        return;

    const int sw = (int)caller->m_size.x;
    const int sh = (int)caller->m_size.y;
    int px0 = (int)std::floor(d.box.x);
    int py0 = (int)std::floor(d.box.y);
    int px1 = (int)std::ceil(d.box.x + d.box.w);
    int py1 = (int)std::ceil(d.box.y + d.box.h);
    px0 = std::clamp(px0, 0, std::max(0, sw - 1));
    py0 = std::clamp(py0, 0, std::max(0, sh - 1));
    px1 = std::clamp(px1, px0 + 1, sw);
    py1 = std::clamp(py1, py0 + 1, sh);
    const int w = px1 - px0, h = py1 - py0;
    if (w < 2 || h < 2)
        return;

    if (!g_fbo)
        g_fbo = new SP<Render::IFramebuffer>(g_pHyprRenderer->createFB("lucid-eink-window"));
    if (!g_fbo || !*g_fbo)
        return;
    if ((int)(*g_fbo)->m_size.x != w || (int)(*g_fbo)->m_size.y != h)
        (*g_fbo)->alloc(w, h, caller->m_drmFormat);
    if (!(*g_fbo)->getTexture())
        return;

    // Full window content for this frame. We only re-draw inside damage, so
    // pixels outside it keep their previous (already inked) state.
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbId(caller));
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbId(*g_fbo));
    glBlitFramebuffer(px0, py0, px1, py1, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);

    const CBox quad{(double)px0, (double)py0, (double)w, (double)h};
    const auto transform = Math::wlTransformToHyprutils(Math::invertTransform(monitor->m_transform));
    Mat3x3 proj = g_pHyprRenderer->projectBoxToTarget(ctx, quad, transform);

    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    g_pHyprRenderer->setViewport(0, 0, sw, sh);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    Render::GL::g_pHyprOpenGL->useShader(*g_shader);
    glUniformMatrix3fv(g_uProj, 1, GL_TRUE, proj.getMatrix().data());
    glUniform1i(g_uTex, 0);
    glUniform2f(g_uSize, (float)w, (float)h);
    glUniform1f(g_uRadius, std::max(0.0f, d.radius));

    glActiveTexture(GL_TEXTURE0);
    (*g_fbo)->getTexture()->bind();
    (*g_fbo)->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    (*g_fbo)->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);

    glBindVertexArray(g_vao);
    drawPerDamageRect(ctx, quad, [] { glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); });
    glBindVertexArray(0);

    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    g_pHyprRenderer->setViewport(0, 0, sw, sh);
}

} // namespace

std::vector<UP<IPassElement>> CEinkPassElement::draw(Render::CRenderContext& ctx) {
    drawEink(ctx, m_data);
    return {};
}

std::optional<CBox> CEinkPassElement::boundingBox(Render::CRenderContext& ctx) {
    const auto monitor = ctx.m_data.pMonitor.lock();
    if (!monitor)
        return std::nullopt;
    const float scale = monitor->m_scale > 0.0f ? monitor->m_scale : 1.0f;
    return CBox{m_data.box.x / scale, m_data.box.y / scale, m_data.box.w / scale, m_data.box.h / scale};
}


namespace eink {

static std::string targetValue() {
    struct Cache {
        std::string value;
        std::chrono::steady_clock::time_point at{};
        bool valid = false;
    };
    static Cache cache;
    const auto now = std::chrono::steady_clock::now();
    if (cache.valid && now - cache.at < std::chrono::milliseconds(100))
        return cache.value;

    std::string path;
    if (const char* xdg = std::getenv("XDG_CACHE_HOME"); xdg && *xdg)
        path = std::string(xdg) + "/lucid/eink-window-target";
    else if (const char* home = std::getenv("HOME"); home && *home)
        path = std::string(home) + "/.cache/lucid/eink-window-target";

    std::string out;
    if (!path.empty()) {
        std::ifstream f(path);
        if (f)
            std::getline(f, out);
    }
    while (!out.empty() && std::isspace((unsigned char)out.front()))
        out.erase(out.begin());
    while (!out.empty() && std::isspace((unsigned char)out.back()))
        out.pop_back();
    cache = Cache{out, now, true};
    return out;
}

static uintptr_t parseAddress(std::string s) {
    while (!s.empty() && std::isspace((unsigned char)s.front()))
        s.erase(s.begin());
    while (!s.empty() && std::isspace((unsigned char)s.back()))
        s.pop_back();
    if (s.empty() || s == "clear" || s == "0")
        return 0;
    if (s.size() > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
        s = s.substr(2);
    try {
        return (uintptr_t)std::stoull(s, nullptr, 16);
    } catch (...) {
        return 0;
    }
}

static bool workspaceRenders(PHLWORKSPACE ws, PHLWORKSPACE active, PHLWORKSPACE special) {
    if (!ws)
        return false;
    if (ws == active || ws == special || ws->m_forceRendering)
        return true;
    const auto off = ws->m_renderOffset->value();
    return ws->m_renderOffset->isBeingAnimated() || ws->m_alpha->isBeingAnimated() ||
        std::abs(off.x) > 0.5 || std::abs(off.y) > 0.5 || ws->m_alpha->value() < 0.999f;
}

void addWindowPass(Render::CRenderContext& ctx, PHLWINDOW window, PHLMONITOR monitor,
    const Render::SWindowRenderPresentation& presentation) {
    if (!window || !monitor)
        return;
    const uintptr_t target = parseAddress(targetValue());
    if (target == 0 || reinterpret_cast<uintptr_t>(window.get()) != target)
        return;
    if (!window->mapped() || window->isHidden())
        return;
    if (!(window->m_state & Desktop::View::WINDOW_STATE_PINNED) &&
        !workspaceRenders(window->m_workspace, monitor->m_activeWorkspace, monitor->m_activeSpecialWorkspace))
        return;

    Vector2D realPos = window->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT) + presentation.workspaceOffset + presentation.floatingOffset;
    const Vector2D realSize = window->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    CBox winBox{realPos.x, realPos.y, realSize.x, realSize.y};
    if (!std::isfinite(winBox.x) || !std::isfinite(winBox.y) || winBox.w <= 0 || winBox.h <= 0)
        return;

    winBox.translate(-monitor->m_position);
    winBox.scale(monitor->m_scale).round().noNegativeSize();
    ctx.m_data.renderModif.applyToBox(winBox);
    const float modifScale = ctx.m_data.renderModif.combinedScale();
    if (winBox.w <= 0 || winBox.h <= 0)
        return;

    float rad = window->presentation().rounding() * monitor->m_scale * modifScale;
    rad = std::clamp(rad, 0.0f, (float)std::min(winBox.w, winBox.h) * 0.5f);
    ctx.m_pass.add(makeUnique<CEinkPassElement>(SEinkDraw{winBox, rad}));
}

} // namespace eink

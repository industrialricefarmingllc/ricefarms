#include "RenderCtx.hpp"
#include "WinCompat.hpp"
#include "WindowWash.hpp"
#include "Config.hpp"
#include "Shaders.hpp"

#include <GLES3/gl32.h>
#include <pixman.h>
#include <hyprland/src/workspace/HLWorkspace.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprutils/math/Misc.hpp>

#include <png.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <unordered_map>
#include <vector>

using namespace Render;
using namespace Render::GL;

namespace {

constexpr float WASH_ALPHA_FALLBACK = 0.8F;

struct SWashState {
    SP<CShader> shader;
    GLuint      vao = 0, vbo = 0;
    GLint       proj = -1, base = -1, wash = -1;
    GLint       screen = -1, box = -1, radius = -1, power = -1, alpha = -1;
    bool        ok = false;

    SP<ITexture>              tex;
    std::string               texPath;
    std::filesystem::file_time_type texStamp = std::filesystem::file_time_type::min();
    std::chrono::steady_clock::time_point lastCheck = std::chrono::steady_clock::time_point::min();

    std::unordered_map<MONITORID, SP<IFramebuffer>> captures;

    // Leaked on purpose: GL objects must not be destroyed off-context.
    ~SWashState() = default;
};

SWashState* state() {
    static SWashState* s = new SWashState();
    return s;
}

GLuint fbId(const SP<IFramebuffer>& fb) {
    return dynamic_cast<CGLFramebuffer*>(fb.get())->getFBID();
}

std::string readPathFile() {
    const char* home = getenv("HOME");
    if (!home || !*home)
        return {};
    std::ifstream in(std::string(home) + "/.cache/quickshell/wallpaper-softlight.path");
    std::string line;
    std::getline(in, line);
    while (!line.empty() && (line.back() == '\r' || line.back() == '\n' || line.back() == ' '))
        line.pop_back();
    return line;
}

SP<ITexture> loadTexture(const std::string& path) {
    png_image image{};
    image.version = PNG_IMAGE_VERSION;
    if (!png_image_begin_read_from_file(&image, path.c_str()))
        return nullptr;

    image.format = PNG_FORMAT_RGBA;
    std::vector<png_byte> pixels(PNG_IMAGE_SIZE(image));
    if (!png_image_finish_read(&image, nullptr, pixels.data(), 0, nullptr)) {
        png_image_free(&image);
        return nullptr;
    }

    auto tex = g_pHyprRenderer->createTexture((int)image.width, (int)image.height, pixels.data());
    png_image_free(&image);
    return tex;
}

void ensureShaders() {
    auto* s = state();
    if (s->ok)
        return;
    if (!s->shader)
        s->shader = makeShared<CShader>();
    if (!s->shader->createProgram(SHADERS.at("glass.vert"), SHADERS.at("wash.frag"), true)) {
        lg::notify("liquidglass: wash.frag failed to compile — window wash disabled");
        return;
    }

    const GLuint p = s->shader->program();
    s->proj    = glGetUniformLocation(p, "proj");
    s->base    = glGetUniformLocation(p, "uBase");
    s->wash    = glGetUniformLocation(p, "uWash");
    s->screen  = glGetUniformLocation(p, "uScreen");
    s->box     = glGetUniformLocation(p, "uBox");
    s->radius  = glGetUniformLocation(p, "uRadius");
    s->power   = glGetUniformLocation(p, "uPower");
    s->alpha   = glGetUniformLocation(p, "uAlpha");

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

SP<ITexture> lg::washTexture() {
    auto* s = state();
    const auto now = std::chrono::steady_clock::now();
    if (now - s->lastCheck < std::chrono::milliseconds(500))
        return s->tex;
    s->lastCheck = now;

    const auto path = readPathFile();
    if (path.empty())
        return s->tex;

    std::error_code ec;
    const auto stamp = std::filesystem::last_write_time(path, ec);
    if (ec)
        return s->tex;

    if (path != s->texPath || stamp != s->texStamp || !s->tex) {
        if (auto tex = loadTexture(path)) {
            s->tex = tex;
            s->texPath = path;
            s->texStamp = stamp;
        }
    }
    return s->tex;
}

std::optional<SWindowWashDraw> lg::windowWashSnapshot(PHLWINDOW window, PHLMONITOR monitor) {
    if (!window || !monitor || !window->mapped() || window->isHidden())
        return std::nullopt;

    // Translucent windows composite over whatever was already in the
    // framebuffer. Re-blending them after each content draw would feed the
    // previous wash back into the next one. They keep the glass effect; the
    // wash is for opaque windows.
    if (!window->presentation().opaque())
        return std::nullopt;

    Vector2D realPos = window->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    float    fade    = 1.F;
    if (PHLWORKSPACE ws = window->m_workspace; ws && !lg::winPinned(window)) {
        realPos = realPos + ws->m_renderOffset->value();
        fade *= std::clamp(ws->m_alpha->value(), 0.F, 1.F);
    }
    realPos = realPos + window->presentation().floatingOffset();

    const Vector2D realSize = window->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    const CBox     logBox{realPos.x, realPos.y, realSize.x, realSize.y};
    if (!std::isfinite(logBox.x) || !std::isfinite(logBox.y) || logBox.w <= 0 || logBox.h <= 0)
        return std::nullopt;

    // Fullscreen windows: the overlay historically excluded them, and there
    // is no regular desktop behind them to tint.
    if (logBox.w >= monitor->m_size.x * 0.99 && logBox.h >= monitor->m_size.y * 0.99)
        return std::nullopt;

    CBox box = logBox;
    box.translate(-monitor->m_position);
    box.scale(monitor->m_scale).round().noNegativeSize();
    if (box.w < 2 || box.h < 2)
        return std::nullopt;

    LG_RENDER_DATA.renderModif.applyToBox(box);
    if (box.w < 2 || box.h < 2)
        return std::nullopt;

    if (const auto& a = window->presentation().alpha(Desktop::View::WINDOW_ALPHA_FADE); a)
        fade *= std::clamp(a->value(), 0.F, 1.F);

    if (fade <= 0.01F)
        return std::nullopt;

    const float scale = monitor->m_scale * LG_RENDER_DATA.renderModif.combinedScale();
    const float rad   = std::max(0.F, window->presentation().rounding() * scale);
    const float power = std::clamp(window->presentation().roundingPower(), 2.F, 10.F);

    return SWindowWashDraw{box, rad, power, fade};
}

void lg::windowWashDraw(const SWindowWashDraw& draw, const SP<ITexture>& wash) {
    ensureShaders();
    auto* s = state();
    if (!s->ok || !wash)
        return;

    auto* r = g_pHyprRenderer.get();
    const auto monitor = LG_RENDER_DATA.pMonitor.lock();
    const auto caller  = LG_RENDER_DATA.currentFB;
    if (!monitor || !caller)
        return;

    const CBox damage = LG_RENDER_DATA.damage.getExtents();
    if (damage.w <= 0 || damage.h <= 0)
        return;

    const int w = (int)caller->m_size.x;
    const int h = (int)caller->m_size.y;
    if (w <= 0 || h <= 0)
        return;

    auto& capture = s->captures[monitor->m_id];
    if (!capture)
        capture = r->createFB("liquidglass-wash-capture");
    if (!capture)
        return;
    if (capture->m_size.x != w || capture->m_size.y != h)
        capture->alloc(w, h, caller->m_drmFormat);
    if (!capture->getTexture())
        return;

    // Capture the freshly drawn window pixels at the same monitor coordinates.
    const int sx0 = std::clamp((int)std::floor(draw.box.x), 0, w);
    const int sy0 = std::clamp((int)std::floor(draw.box.y), 0, h);
    const int sx1 = std::clamp((int)std::ceil(draw.box.x + draw.box.w), 0, w);
    const int sy1 = std::clamp((int)std::ceil(draw.box.y + draw.box.h), 0, h);
    if (sx1 <= sx0 || sy1 <= sy0)
        return;

    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbId(caller));
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbId(capture));
    glBlitFramebuffer(sx0, sy0, sx1, sy1, sx0, sy0, sx1, sy1, GL_COLOR_BUFFER_BIT, GL_NEAREST);

    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    g_pHyprOpenGL->setViewport(0, 0, w, h);

    const auto transform = Math::wlTransformToHyprutils(Math::invertTransform(monitor->m_transform));
    const Mat3x3 proj    = r->projectBoxToTarget(lg::rctx(), draw.box, transform);

    auto shader = g_pHyprOpenGL->useShader(s->shader);
    glUniformMatrix3fv(s->proj, 1, GL_TRUE, proj.getMatrix().data());

    glActiveTexture(GL_TEXTURE0);
    capture->getTexture()->bind();
    capture->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    capture->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glUniform1i(s->base, 0);

    glActiveTexture(GL_TEXTURE1);
    wash->bind();
    wash->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    wash->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glUniform1i(s->wash, 1);

    glUniform2f(s->screen, (float)w, (float)h);
    glUniform2f(s->box, (float)draw.box.w, (float)draw.box.h);
    glUniform1f(s->radius, draw.radius);
    glUniform1f(s->power, draw.power);
    glUniform1f(s->alpha, std::clamp(draw.alpha, 0.F, 1.F));

    const int cx0 = std::clamp((int)std::floor(damage.x), 0, w);
    const int cy0 = std::clamp((int)std::floor(damage.y), 0, h);
    const int cx1 = std::clamp((int)std::ceil(damage.x + damage.w), 0, w);
    const int cy1 = std::clamp((int)std::ceil(damage.y + damage.h), 0, h);

    glDisable(GL_BLEND);
    glBindVertexArray(s->vao);
    if (cx1 > cx0 && cy1 > cy0) {
        const pixman_box32_t clip{cx0, cy0, cx1, cy1};
        g_pHyprOpenGL->scissor(lg::rctx(), &clip, LG_RENDER_DATA.transformDamage);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        g_pHyprOpenGL->setCapStatus(GL_SCISSOR_TEST, false);
    }
    glBindVertexArray(0);

    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    g_pHyprOpenGL->setViewport(0, 0, w, h);
    glActiveTexture(GL_TEXTURE0);
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
}

CWindowWashPassElement::CWindowWashPassElement(const SData& data) : m_data(data) {}

std::vector<UP<IPassElement>> CWindowWashPassElement::draw(Render::CRenderContext& ctx) {
    lg::SRenderCtxScope scope(ctx);
    lg::windowWashDraw(m_data.draw, m_data.wash);
    return {};
}

std::optional<CBox> CWindowWashPassElement::boundingBox(Render::CRenderContext& ctx) {
    lg::SRenderCtxScope scope(ctx);
    const auto monitor = LG_RENDER_DATA.pMonitor.lock();
    if (!monitor || monitor->m_scale <= 0)
        return std::nullopt;
    const float s = monitor->m_scale;
    return CBox{m_data.draw.box.x / s, m_data.draw.box.y / s, m_data.draw.box.w / s, m_data.draw.box.h / s};
}

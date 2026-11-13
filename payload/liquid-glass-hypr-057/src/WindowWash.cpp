#include "WindowWash.hpp"
#include "Config.hpp"
#include "Shaders.hpp"

#include <GLES3/gl32.h>
#include <pixman.h>
#include <hyprland/src/render/Context.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/managers/screenshare/ScreenshareManager.hpp>
#include <hyprland/src/render/gl/GLFramebuffer.hpp>
#include <hyprutils/math/Misc.hpp>

#include <png.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <unordered_map>
#include <vector>
#include <fstream>

using namespace Render;
using namespace Render::GL;

namespace {

struct SWashState {
    SP<CShader> shader;
    GLuint      vao = 0, vbo = 0;
    GLint       proj = -1, wash = -1;
    GLint       screen = -1, box = -1, radii = -1, flare = -1, power = -1, soft = -1, darkOpacity = -1, fade = -1;
    bool        ok = false;

    SP<ITexture>                    tex;
    std::string                     texPath;
    std::filesystem::file_time_type texStamp = std::filesystem::file_time_type::min();
    std::chrono::steady_clock::time_point lastCheck = std::chrono::steady_clock::time_point::min();

    ~SWashState() = default; // leaked on purpose
};

SWashState* state() {
    static SWashState* s = new SWashState();
    return s;
}

std::string readPathFile(bool light) {
    const char* home = getenv("HOME");
    if (!home || !*home)
        return {};
    // Both modes use the raw blurred wallpaper. Light mode lets the GPU
    // multiply it against the framebuffer; dark mode screens it at 5%.
    (void)light;
    std::ifstream in(std::string(home) + "/.cache/quickshell/wallpaper-softlight-screen.path");
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

    image.format = PNG_FORMAT_BGRA;
    std::vector<png_byte> pixels(PNG_IMAGE_SIZE(image));
    if (!png_image_finish_read(&image, nullptr, pixels.data(), 0, nullptr)) {
        png_image_free(&image);
        return nullptr;
    }

    auto tex = g_pHyprRenderer->createTexture((int)image.width, (int)image.height, pixels.data());
    png_image_free(&image);
    return tex;
}

bool lightTheme() {
    static bool value = false;
    static std::chrono::steady_clock::time_point at = std::chrono::steady_clock::time_point::min();
    const auto now = std::chrono::steady_clock::now();
    if (at != std::chrono::steady_clock::time_point::min() && now - at < std::chrono::milliseconds(500))
        return value;
    at = now;
    const char* home = getenv("HOME");
    if (!home || !*home)
        return value;
    std::ifstream in(std::string(home) + "/.cache/quickshell/theme_mode");
    std::string line;
    std::getline(in, line);
    value = line == "light";
    return value;
}

void ensureShaders() {
    auto* s = state();
    if (s->ok)
        return;
    if (!s->shader)
        s->shader = makeShared<CShader>();
    if (!s->shader->createProgram(SHADERS.at("glass.vert"), SHADERS.at("wash.frag"), true)) {
        std::ofstream("/tmp/lucid-wash.log", std::ios::app) << "wash: shader compile failed\n";
        return;
    }

    const GLuint p = s->shader->program();
    s->proj   = glGetUniformLocation(p, "proj");
    s->wash   = glGetUniformLocation(p, "uWash");
    s->screen = glGetUniformLocation(p, "uScreen");
    s->box    = glGetUniformLocation(p, "uBox");
    s->radii  = glGetUniformLocation(p, "uRadii");
    s->flare  = glGetUniformLocation(p, "uFlare");
    s->power  = glGetUniformLocation(p, "uPower");
    s->soft   = glGetUniformLocation(p, "uSoft");
    s->darkOpacity = glGetUniformLocation(p, "uDarkOpacity");
    s->fade   = glGetUniformLocation(p, "uFade");

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
    if (s->lastCheck != std::chrono::steady_clock::time_point::min() && now - s->lastCheck < std::chrono::milliseconds(500))
        return s->tex;
    s->lastCheck = now;

    const auto path = readPathFile(lightTheme());
    if (path.empty()) {
        static bool once = false;
        if (!once) { once = true; std::ofstream("/tmp/lucid-wash.log", std::ios::app) << "wash: empty path\n"; }
        return s->tex;
    }

    std::error_code ec;
    const auto stamp = std::filesystem::last_write_time(path, ec);
    if (ec)
        return s->tex;

    if (path != s->texPath || stamp != s->texStamp || !s->tex) {
        if (auto tex = loadTexture(path)) {
            s->tex = tex;
            s->texPath = path;
            s->texStamp = stamp;
            std::ofstream("/tmp/lucid-wash.log", std::ios::app) << "wash: loaded " << path << "\n";
        } else {
            std::ofstream("/tmp/lucid-wash.log", std::ios::app) << "wash: decode failed " << path << "\n";
        }
    }
    return s->tex;
}

std::optional<SWindowWashDraw>
lg::windowWashSnapshot(PHLWINDOW window, PHLMONITOR monitor, const SWindowRenderPresentation& presentation) {
    if (!window || !monitor || !window->mapped() || window->isHidden())
        return std::nullopt;

    // Shell surfaces are not desktop windows; the old overlay excluded them.
    const auto app   = window->metadata().appID();
    const auto title = window->metadata().title();
    // Lucid's launcher parks a real (pixel-less) placeholder toleven and draws
    // the visible tile in a floating ghost toplevel. Both are org.quickshell,
    // so whitelist only those two titles (plus the pre-stable Launching title).
    const bool launchTile = app == "org.quickshell" &&
        (title == "lucid-launch-placeholder" || title == "lucid-launch-ghost" || title.starts_with("Launching "));
    if (app.empty() || (app == "org.quickshell" && !launchTile))
        return std::nullopt;

    {
        static int n = 0;
        if (n++ < 8)
            std::ofstream("/tmp/lucid-wash.log", std::ios::app)
                << "snap app=" << app << " opaque=" << window->presentation().opaque() << "\n";
    }


    Vector2D realPos = window->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT) + presentation.workspaceOffset +
        presentation.floatingOffset;
    const Vector2D realSize = window->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    const CBox     logBox{realPos.x, realPos.y, realSize.x, realSize.y};
    if (!std::isfinite(logBox.x) || !std::isfinite(logBox.y) || logBox.w <= 0 || logBox.h <= 0)
        return std::nullopt;

    if (logBox.w >= monitor->m_size.x * 0.99 && logBox.h >= monitor->m_size.y * 0.99)
        return std::nullopt;

    CBox box = logBox;
    box.translate(-monitor->m_position);
    box.scale(monitor->m_scale).round().noNegativeSize();
    if (box.w < 2 || box.h < 2)
        return std::nullopt;

    const float fade = std::clamp(presentation.alpha * presentation.fadeAlpha * presentation.workspaceAlpha, 0.F, 1.F);
    if (fade <= 0.01F)
        return std::nullopt;

    float rad   = std::max(0.F, window->presentation().rounding() * monitor->m_scale);
    float power = std::clamp(window->presentation().roundingPower(), 2.F, 10.F);
    if (launchTile) {
        // The launch ghost/placeholder rules set compositor rounding to 0;
        // the QML tile itself uses the decoration radius and squircle. Match
        // that so the wash does not paint a square over the rounded tile.
        rad   = 8.F * monitor->m_scale;
        power = 6.F;
    }

    return SWindowWashDraw{box, {rad, rad, rad, rad}, {0.F, 0.F}, power, fade};
}

namespace {
const std::string& geoDir() {
    static const std::string dir = [] {
        if (const char* xdg = getenv("XDG_CACHE_HOME"); xdg && *xdg)
            return std::string(xdg) + "/liquid-glass-hypr";
        if (const char* home = getenv("HOME"); home && *home)
            return std::string(home) + "/.cache/liquid-glass-hypr";
        return std::string();
    }();
    return dir;
}

// Shared scan + parse cache for the wash geometry files. layerWashSnapshots
// runs for every mapped layer after every render, and it used to re-open and
// re-parse every publisher JSON each time. The bridge writes at most every
// 16ms, so an 8ms shared scan is fresh enough; parsed JSON is kept until the
// file's mtime changes. This turns N_layers * N_files parses per frame into
// one scan per monitor per 8ms and one parse per actual file change.
struct SWashScanEntry {
    std::string path;
    std::filesystem::file_time_type stamp{};
};
struct SWashScanCache {
    std::chrono::steady_clock::time_point at{};
    std::vector<SWashScanEntry> entries;
    bool valid = false;
};
struct SWashJsonCache {
    std::filesystem::file_time_type stamp{};
    nlohmann::json json;
    bool ok = false;
};

static const SWashScanCache& washScan(const std::string& dir, const std::string& mon) {
    static std::map<std::string, std::map<std::string, SWashScanCache>> cache;
    auto& c = cache[dir][mon];
    const auto now = std::chrono::steady_clock::now();
    if (c.valid && now - c.at < std::chrono::milliseconds(8))
        return c;
    c.entries.clear();
    const std::string glassPrefix = "liquidglass-";
    const std::string washPrefix  = "liquidwash-";
    const std::string suffix      = "-" + mon + ".json";
    std::error_code ec;
    for (const auto& ent : std::filesystem::directory_iterator(dir, ec)) {
        if (ec)
            break;
        if (!ent.is_regular_file(ec))
            continue;
        const std::string name = ent.path().filename().string();
        const bool glassBridge = name.size() > glassPrefix.size() + suffix.size() && name.compare(0, glassPrefix.size(), glassPrefix) == 0;
        const bool washBridge  = name.size() > washPrefix.size() + suffix.size() && name.compare(0, washPrefix.size(), washPrefix) == 0;
        if (!glassBridge && !washBridge)
            continue;
        if (name.compare(name.size() - suffix.size(), suffix.size(), suffix) != 0)
            continue;
        std::error_code sec;
        const auto stamp = std::filesystem::last_write_time(ent.path(), sec);
        if (!sec)
            c.entries.push_back({ent.path().string(), stamp});
    }
    std::sort(c.entries.begin(), c.entries.end(), [](const SWashScanEntry& a, const SWashScanEntry& b) {
        return a.path < b.path;
    });
    c.at = now;
    c.valid = true;
    return c;
}

static const nlohmann::json* washJson(const std::string& path, std::filesystem::file_time_type stamp) {
    static std::map<std::string, SWashJsonCache> cache;
    auto& c = cache[path];
    if (c.ok && c.stamp == stamp)
        return &c.json;
    c.stamp = stamp;
    c.ok = false;
    std::ifstream f(path);
    if (!f)
        return nullptr;
    try {
        f >> c.json;
    } catch (const nlohmann::json::exception&) {
        return nullptr;
    }
    c.ok = true;
    return &c.json;
}
} // namespace

std::vector<SWindowWashDraw> lg::layerWashSnapshots(PHLLS surface, PHLMONITOR monitor) {
    std::vector<SWindowWashDraw> out;
    if (!surface || !monitor || !surface->mapped())
        return out;
    // The wash bridge only publishes for the glass namespaces (quickshell,
    // lucid-launcher, lucid-widgets). Wallpaper/spatial/desktop/corner layers
    // have no geometry files; skip the scan/iteration entirely.
    if (!lg::namespaceAllowed(surface->m_namespace))
        return out;

    const auto& dir = geoDir();
    if (dir.empty())
        return out;

    CBox surfBox{surface->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT),
                 surface->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT)};
    surfBox.translate(-monitor->m_position);
    surfBox.scale(monitor->m_scale).round().noNegativeSize();
    if (surfBox.w < 2 || surfBox.h < 2)
        return out;

    const float layerAlpha = surface->alpha()[Desktop::View::LS_ALPHA_FADE]->value();
    if (layerAlpha < 0.99F)
        return out;

    const auto& scan = washScan(dir, monitor->m_name);
    for (const auto& entry : scan.entries) {
        const std::string& path = entry.path;
        const auto* jp = washJson(path, entry.stamp);
        if (!jp || !jp->is_object())
            continue;
        const auto& j = *jp;

        const auto ns = j.value("ns", std::string{});
        if (!ns.empty() && ns != surface->m_namespace)
            continue;

        const auto& sp = j["surface"];
        if (!sp.is_object())
            continue;
        const double dw = sp.value("w", 0.0);
        const double dh = sp.value("h", 0.0);
        if (dw <= 0.0 || dh <= 0.0)
            continue;
        const bool full = j.value("full", false);
        const auto& pills = j["pills"];

        // Same identity rule as the glass path (Glass.cpp loadGeometry): the
        // bar, dock and OSD share the layer namespace "quickshell", so a file
        // must also match the surface's committed logical size or its pills
        // get washed onto every quickshell layer. `full` descriptors take the
        // live box on purpose and skip the size check.
        if (!full &&
            (std::fabs(surfBox.w / monitor->m_scale - dw) > 2.0 || std::fabs(surfBox.h / monitor->m_scale - dh) > 2.0))
            continue;

        auto addPill = [&](const nlohmann::json& p, const CBox& box, float scale) {
            std::array<float, 4> rad{0, 0, 0, 0};
            if (p.contains("r") && p["r"].is_array()) {
                const auto& r = p["r"];
                for (size_t i = 0; i < 4 && i < r.size(); ++i)
                    if (r[i].is_number())
                        rad[i] = std::max(0.F, r[i].get<float>() * scale);
            }
            std::array<float, 2> fl{0, 0};
            if (p.contains("fl") && p["fl"].is_array()) {
                const auto& f = p["fl"];
                for (size_t i = 0; i < 2 && i < f.size(); ++i)
                    if (f[i].is_number())
                        fl[i] = std::max(0.F, f[i].get<float>() * scale);
            }
            CBox expanded = box;
            if (fl[0] > 0.F || fl[1] > 0.F) {
                expanded.x -= fl[0];
                expanded.w += fl[0] + fl[1];
            }
            const float sq = std::clamp(p.value("sq", 0.5), 0.0, 1.0);
            out.push_back(SWindowWashDraw{expanded, rad, fl, 2.F + 8.F * (float)sq, layerAlpha});
        };

        if (full) {
            // Live committed surface box: the launcher can resize/track its
            // reveal without the bridge having to publish x/y/w/h. The file
            // may still describe the collapsed size (476x64) while the panel
            // is resized, so don't gate this on the declared size/ratio.
            float scale = (float)monitor->m_scale;
            if (pills.is_array() && !pills.empty() && pills[0].is_object())
                addPill(pills[0], surfBox, scale);
            else {
                const float r = 24.F * scale;
                out.push_back(SWindowWashDraw{surfBox, {r, r, r, r}, {0.F, 0.F}, 6.F, layerAlpha});
            }
            continue;
        }

        const double rx = surfBox.w / dw;
        const double ry = surfBox.h / dh;
        if (!std::isfinite(rx) || !std::isfinite(ry) || rx < 0.25 || rx > 4.0 || ry < 0.25 || ry > 4.0 ||
            std::fabs(rx - ry) > 0.02)
            continue;
        if (!pills.is_array() || pills.empty())
            continue;

        for (const auto& p : pills) {
            if (!p.is_object())
                continue;
            const double px = p.value("x", 0.0);
            const double py = p.value("y", 0.0);
            const double pw = p.value("w", 0.0);
            const double ph = p.value("h", 0.0);
            if (pw <= 0.0 || ph <= 0.0)
                continue;
            const CBox box{surfBox.x + px * rx, surfBox.y + py * ry, pw * rx, ph * ry};
            if (box.w < 2 || box.h < 2)
                continue;
            addPill(p, box, (float)rx);
        }
    }
    return out;
}

namespace {
struct SQueuedWash {
    SWindowWashDraw      draw;
    SP<ITexture>         wash;
};
std::unordered_map<MONITORID, std::vector<SQueuedWash>> g_queuedWash;
} // namespace

void lg::queueWindowWash(PHLWINDOW window, PHLMONITOR monitor, const SWindowRenderPresentation& presentation) {
    auto wash = washTexture();
    if (!wash)
        return;
    if (auto draw = windowWashSnapshot(window, monitor, presentation))
        g_queuedWash[monitor->m_id].push_back(SQueuedWash{*draw, wash});
}

void lg::queueLayerWash(PHLLS surface, PHLMONITOR monitor) {
    auto wash = washTexture();
    if (!wash)
        return;
    for (const auto& draw : layerWashSnapshots(surface, monitor))
        g_queuedWash[monitor->m_id].push_back(SQueuedWash{draw, wash});
}

void lg::drawQueuedWash(PHLMONITOR monitor, const SP<IFramebuffer>& target, const CRegion& damage, bool transformDamage) {
    if (!monitor || !target)
        return;
    auto it = g_queuedWash.find(monitor->m_id);
    if (it == g_queuedWash.end()) {
        static int n0 = 0;
        if (n0++ < 5)
            std::ofstream("/tmp/lucid-wash.log", std::ios::app) << "end: no queued wash\n";
        return;
    }
    {
        static int n1 = 0;
        if (n1++ < 5)
            std::ofstream("/tmp/lucid-wash.log", std::ios::app) << "end: queued=" << it->second.size() << "\n";
    }
    if (!it->second.empty()) {
        CRenderContext ctx;
        ctx.m_data.pMonitor       = monitor;
        ctx.m_data.currentFB      = target;
        ctx.m_data.projectionType = Render::RPT_MONITOR;
        ctx.m_data.fbSize         = target->m_size;
        ctx.m_data.damage         = damage;
        ctx.m_data.finalDamage    = damage;
        ctx.m_data.transformDamage = transformDamage;
        g_pHyprRenderer->bindFB(ctx, target);
        for (const auto& q : it->second)
            windowWashDraw(q.draw, q.wash, ctx);
    }
    g_queuedWash.erase(it);
}

void lg::clearQueuedWash(PHLMONITOR monitor) {
    if (monitor)
        g_queuedWash.erase(monitor->m_id);
}

// A monitor/region capture reads the mirror framebuffer, which Hyprland fills
// from the work buffer before the screen shader and before the wash. Refresh it
// from the finished output so a screenshot matches the screen. Workspace
// captures render the scene themselves and are left alone.
void lg::mirrorFromOutput(PHLMONITOR monitor, const SP<IFramebuffer>& output, const CRegion& damage, bool transformDamage) {
    if (!monitor || !output || damage.empty())
        return;
    if (!Screenshare::mgr()->isOutputBeingSSd(monitor))
        return;

    auto mirror = monitor->resources()->mirrorFB();
    if (!mirror || !mirror->isAllocated())
        return;
    auto tex = output->getTexture();
    if (!tex)
        return;

    CRenderContext ctx;
    ctx.m_data.pMonitor       = monitor;
    ctx.m_data.currentFB      = mirror;
    ctx.m_data.projectionType = RPT_MONITOR;
    ctx.m_data.fbSize         = mirror->m_size;
    ctx.m_data.damage         = damage;
    ctx.m_data.finalDamage    = damage;
    ctx.m_data.transformDamage = transformDamage;

    g_pHyprRenderer->bindFB(ctx, mirror);
    g_pHyprRenderer->setViewport(0, 0, (int)mirror->m_size.x, (int)mirror->m_size.y);
    g_pHyprOpenGL->blend(false);
    g_pHyprOpenGL->renderTexture(ctx, tex, CBox{{}, mirror->m_size},
                                 CHyprOpenGLImpl::STextureRenderData{
                                     .damage = &damage,
                                     .a      = 1.F,
                                 });
    g_pHyprOpenGL->blend(true);
}

void lg::windowWashDraw(const SWindowWashDraw& draw, const SP<ITexture>& wash, CRenderContext& ctx) {
    ensureShaders();
    auto* s = state();
    if (!s->ok || !wash)
        return;

    const auto monitor = ctx.m_data.pMonitor.lock();
    const auto caller  = ctx.m_data.currentFB;
    if (!monitor || !caller)
        return;

    if (draw.alpha <= 0.01F)
        return;

    const CBox damage = ctx.m_data.damage.getExtents();
    if (damage.w <= 0 || damage.h <= 0)
        return;

    // The quad only covers draw.box; if damage misses it entirely the draw
    // would rasterize nothing. Skip the uniform setup and the draw call.
    if (draw.box.x + draw.box.w <= damage.x || draw.box.y + draw.box.h <= damage.y ||
        draw.box.x >= damage.x + damage.w || draw.box.y >= damage.y + damage.h)
        return;

    {
        static int n = 0;
        if (n++ < 20)
            std::ofstream("/tmp/lucid-wash.log", std::ios::app)
                << "draw box=" << draw.box.x << "," << draw.box.y << " " << draw.box.w << "x" << draw.box.h
                << " dmg=" << damage.x << "," << damage.y << " " << damage.w << "x" << damage.h
                << " alpha=" << draw.alpha << "\n";
    }

    const int w = (int)caller->m_size.x;
    const int h = (int)caller->m_size.y;
    if (w <= 0 || h <= 0)
        return;

    const auto transform = Math::wlTransformToHyprutils(Math::invertTransform(monitor->m_transform));
    const Mat3x3 proj    = g_pHyprRenderer->projectBoxToTarget(ctx, draw.box, transform);

    auto shader = g_pHyprOpenGL->useShader(s->shader);
    glUniformMatrix3fv(s->proj, 1, GL_TRUE, proj.getMatrix().data());

    glActiveTexture(GL_TEXTURE0);
    wash->bind();
    wash->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    wash->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glUniform1i(s->wash, 0);

    glUniform2f(s->screen, (float)w, (float)h);
    glUniform2f(s->box, (float)draw.box.w, (float)draw.box.h);
    glUniform4f(s->radii, draw.radii[0], draw.radii[1], draw.radii[2], draw.radii[3]);
    glUniform2f(s->flare, draw.flare[0], draw.flare[1]);
    glUniform1f(s->power, draw.power);
    const bool light = lightTheme();
    glUniform1f(s->soft, light ? 1.F : 0.F);
    glUniform1f(s->darkOpacity, 0.10F);
    glUniform1f(s->fade, std::clamp(draw.alpha, 0.F, 1.F));

    const int cx0 = std::clamp((int)std::floor(damage.x), 0, w);
    const int cy0 = std::clamp((int)std::floor(damage.y), 0, h);
    const int cx1 = std::clamp((int)std::ceil(damage.x + damage.w), 0, w);
    const int cy1 = std::clamp((int)std::ceil(damage.y + damage.h), 0, h);

    glEnable(GL_BLEND);
    if (light) {
        // Source already contains 1 - a*(1-wash); multiply it by the dest.
        glBlendEquation(GL_FUNC_ADD);
        glBlendFuncSeparate(GL_DST_COLOR, GL_ZERO, GL_ONE, GL_ZERO);
    } else {
        // Dark mode: screen. src is the 15%-scaled raw blurred wallpaper.
        glBlendEquation(GL_FUNC_ADD);
        glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_COLOR, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    }
    glBindVertexArray(s->vao);
    if (cx1 > cx0 && cy1 > cy0) {
        const pixman_box32_t clip{cx0, cy0, cx1, cy1};
        g_pHyprOpenGL->scissor(ctx, &clip, ctx.m_data.transformDamage);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        g_pHyprOpenGL->setCapStatus(GL_SCISSOR_TEST, false);
    }
    glBindVertexArray(0);

    g_pHyprRenderer->setViewport(0, 0, w, h);
    glActiveTexture(GL_TEXTURE0);
    glBlendEquation(GL_FUNC_ADD);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
}

CWindowWashPassElement::CWindowWashPassElement(const SData& data) : m_data(data) {}

std::vector<UP<IPassElement>> CWindowWashPassElement::draw(CRenderContext& ctx) {
    lg::windowWashDraw(m_data.draw, m_data.wash, ctx);
    return {};
}

std::optional<CBox> CWindowWashPassElement::boundingBox(CRenderContext& ctx) {
    const auto monitor = ctx.m_data.pMonitor.lock();
    if (!monitor || monitor->m_scale <= 0)
        return std::nullopt;
    const float s = monitor->m_scale;
    return CBox{m_data.draw.box.x / s, m_data.draw.box.y / s, m_data.draw.box.w / s, m_data.draw.box.h / s};
}

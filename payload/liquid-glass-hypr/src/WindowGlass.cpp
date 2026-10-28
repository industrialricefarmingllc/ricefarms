#include "WindowGlass.hpp"
#include "Config.hpp"
#include "GooMorph.hpp"
#include "Shaders.hpp"

#include <GLES3/gl32.h>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprutils/math/Misc.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

// Focused-window tracking for the active glow boost. The window.active bus
// event publishes the raw address lock-free; snapshots compare against it.
// Raw-pointer compare only ever ADDS glow (self-corrects on the next focus
// change), so a stale address can never corrupt geometry or crash.
namespace {
std::atomic<uintptr_t> s_focusedAddr{0};
CHyprSignalListener s_focusListen;

void onWindowActive(PHLWINDOW win, Desktop::eFocusReason) {
    s_focusedAddr.store(win ? reinterpret_cast<uintptr_t>(win.get()) : 0u, std::memory_order_relaxed);
}
} // namespace

namespace lg {
void initWindowBackdrop();
void exitWindowBackdrop();

void initWindowFocus() {
    s_focusListen = Event::bus()->m_events.window.active.listen(onWindowActive);
    initWindowBackdrop();
}
void exitWindowFocus() {
    s_focusListen.reset();
    exitWindowBackdrop();
}
} // namespace lg

using namespace Render;
using namespace Render::GL;

// Fullscreen-triangle projection: VAO positions [0,1] -> clip [-1,1].
// (Same matrix every blur/glass user in Hyprland uses for fullscreen passes.)
static constexpr std::array<float, 9> FULLSCREEN_PROJECTION = {
    2.0f, 0.0f, 0.0f,
    0.0f, 2.0f, 0.0f,
    -1.0f, -1.0f, 1.0f,
};

static GLuint fbId(const SP<Render::IFramebuffer>& fb);

namespace {

// One pre-window backdrop per monitor. Captured once at RENDER_PRE_WINDOWS
// (after wallpaper + bottom layers, before any window) and shared by every
// window whose padded rect does not overlap an earlier window. This removes
// the per-window blit's read-after-write sync from the common tiled case.
struct SWindowBackdrop {
    SP<IFramebuffer> capture;
    int capDiv = 0;
    int capW = 0, capH = 0;
    bool valid = false;

    void begin(int div) {
        valid = false;
        capDiv = div;
    }

    void captureFrom(const SP<IFramebuffer>& src, int div) {
        if (!src || !src->getTexture())
            return;
        const int sw = (int)src->m_size.x, sh = (int)src->m_size.y;
        if (sw <= 0 || sh <= 0)
            return;
        const int dw = std::max(1, sw / std::max(2, div));
        const int dh = std::max(1, sh / std::max(2, div));
        if (!capture)
            capture = g_pHyprRenderer->createFB("liquidglass-win-backdrop");
        if (!capture)
            return;
        if (capture->m_size.x != dw || capture->m_size.y != dh || capture->m_drmFormat != src->m_drmFormat ||
            capDiv != div) {
            if (!capture->alloc(dw, dh, src->m_drmFormat))
                return;
        }
        capDiv = div;
        capW = dw;
        capH = dh;
        g_pHyprOpenGL->setCapStatus(GL_SCISSOR_TEST, false);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbId(src));
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbId(capture));
        glBlitFramebuffer(0, 0, sw, sh, 0, 0, dw, dh, GL_COLOR_BUFFER_BIT, GL_LINEAR);
        glBindFramebuffer(GL_FRAMEBUFFER, fbId(src));
        g_pHyprOpenGL->setViewport(0, 0, sw, sh);
        valid = true;
    }
};

auto* WINDOW_BACKDROPS = new std::unordered_map<MONITORID, std::shared_ptr<SWindowBackdrop>>();
// This frame's already-recorded main-pass window boxes, in draw order.
auto* WINDOW_BOXES = new std::unordered_map<MONITORID, std::vector<CBox>>();

std::shared_ptr<SWindowBackdrop> backdropFor(MONITORID mon) {
    auto& slot = (*WINDOW_BACKDROPS)[mon];
    if (!slot)
        slot = std::make_shared<SWindowBackdrop>();
    return slot;
}

CBox monitorLogicalBox(PHLMONITOR mon) {
    if (!mon)
        return {};
    const float scale = mon->m_scale > 0.0f ? mon->m_scale : 1.0f;
    return CBox{0.0, 0.0, (double)((int)(mon->m_transformedSize.x / scale)),
                (double)((int)(mon->m_transformedSize.y / scale))};
}

class CWindowBackdropPassElement : public IPassElement {
  public:
    explicit CWindowBackdropPassElement(std::shared_ptr<SWindowBackdrop> backdrop) : m_backdrop(std::move(backdrop)) {}

    std::vector<UP<IPassElement>> draw() override {
        if (!m_backdrop)
            return {};
        if (g_pHyprRenderer->m_bRenderingSnapshot)
            return {};
        const auto caller = g_pHyprRenderer->m_renderData.currentFB;
        if (!caller)
            return {};
        m_backdrop->captureFrom(caller, m_backdrop->capDiv);
        return {};
    }

    [[nodiscard]] bool needsLiveBlur() override { return false; }
    [[nodiscard]] bool needsPrecomputeBlur() override { return false; }
    [[nodiscard]] std::optional<CBox> boundingBox() override {
        return monitorLogicalBox(g_pHyprRenderer->m_renderData.pMonitor.lock());
    }
    [[nodiscard]] bool disableSimplification() override { return false; }
    [[nodiscard]] bool undiscardable() override { return false; }
    [[nodiscard]] const char* passName() override { return "CWindowBackdropPassElement"; }
    [[nodiscard]] ePassElementType type() override { return EK_CUSTOM; }

  private:
    std::shared_ptr<SWindowBackdrop> m_backdrop;
};

CHyprSignalListener g_stageListen;

bool workspaceAnimating(PHLMONITOR mon) {
    if (!mon)
        return false;
    const auto ws = mon->m_activeWorkspace;
    if (!ws)
        return false;
    const auto off = ws->m_renderOffset->value();
    if (ws->m_renderOffset->isBeingAnimated() || ws->m_alpha->isBeingAnimated())
        return true;
    if (std::abs(off.x) > 0.5 || std::abs(off.y) > 0.5 || ws->m_alpha->value() < 0.999f)
        return true;
    return false;
}

void onWindowStage(eRenderStage stage) {
    if (stage == RENDER_POST) {
        for (auto& [id, bd] : *WINDOW_BACKDROPS) {
            if (bd)
                bd->valid = false;
        }
        WINDOW_BOXES->clear();
        return;
    }
    if (stage != RENDER_PRE_WINDOWS)
        return;
    if (g_pHyprRenderer->m_bRenderingSnapshot)
        return;
    const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
    if (!mon || mon->isMirror())
        return;
    (*WINDOW_BOXES)[mon->m_id].clear();
    if (lg::getInt("plugin:liquidglass:enabled", 1) == 0)
        return;
    const CBox dmg = g_pHyprRenderer->m_renderData.damage.getExtents();
    if (dmg.w <= 0 || dmg.h <= 0)
        return;
    // A slide/morph moves windows, not the wallpaper/bottom layers: the
    // pre-window capture is still the static backdrop. Keep it and let the
    // per-window overlap check below decide when a live read is required.
    // One full-monitor capture amortizes across every non-overlapping glass
    // pane instead of paying N read-after-write blits per frame.
    // One consumer does not amortize a full-monitor capture; use the
    // per-window path (and its content cache) instead.
    if (lg::windowGlassCount(mon) < 2)
        return;
    // If the damage only touches something else (cursor, another window),
    // every glass pass element will be culled; don't capture a backdrop.
    if (!lg::windowGlassNeedsFrame(mon, dmg))
        return;
    const int capDiv = std::clamp((int)std::round(lg::getFloat("plugin:liquidglass:capture_scale", 4.0f)), 2, 4);
    auto bd = backdropFor(mon->m_id);
    bd->begin(capDiv);
    g_pHyprRenderer->m_renderPass.add(makeUnique<CWindowBackdropPassElement>(bd));
}

} // namespace

namespace lg {
void initWindowBackdrop() {
    g_stageListen = Event::bus()->m_events.render.stage.listen(onWindowStage);
}
void exitWindowBackdrop() {
    g_stageListen.reset();
}
} // namespace lg

CWindowGlass::CWindowGlass(PHLWINDOW window) : m_window(window) {}

// --- terminal tint ----------------------------------------------------------
// window_tint_file (default ~/.config/kitty/matugen-colors.conf), parsed for the LAST
// `background #rrggbb` line. Kitty is last-wins, so overrides after the
// matugen include apply — exactly the effective terminal background, in both
// dark and light theme modes. mtime-gated: parsed only on change, two stats
// otherwise. Unreadable/unparseable -> caller falls back to the theme tint.

static std::string expandHome(const std::string& p) {
    if (p.size() >= 2 && p[0] == '~' && p[1] == '/') {
        if (const char* home = std::getenv("HOME"); home && *home)
            return std::string(home) + p.substr(1);
        return {};
    }
    if (p.size() >= 5 && p.compare(0, 5, "$HOME") == 0) {
        if (const char* home = std::getenv("HOME"); home && *home)
            return std::string(home) + p.substr(5);
        return {};
    }
    return p;
}

struct STintCache {
    std::filesystem::file_time_type stamp = std::filesystem::file_time_type::min();
    bool ok = false;   // parsed at least once (even if no background found)
    bool found = false;
    int rgb = 0; // 0xRRGGBB
};

static bool windowTintRgb(int& rgb, std::filesystem::file_time_type& stampOut) {
    static STintCache cache;
    static std::string cachedPath;
    // PERF: stat TTL (200ms) — called per window per frame in snapshot()
    // (render hook); was 1 stat + 1 getString per call (~700/sec at 60fps).
    // kitty.conf edits land within 200ms.
    static auto lastStat = std::chrono::steady_clock::now() - std::chrono::hours(1);
    static std::filesystem::file_time_type lastStamp = std::filesystem::file_time_type::min();
    static std::string lastPath;
    static bool lastHave = false;
    const std::string path = expandHome(lg::getString("plugin:liquidglass:window_tint_file", "~/.config/kitty/matugen-colors.conf"));
    if (path.empty())
        return false;
    const auto now = std::chrono::steady_clock::now();
    std::filesystem::file_time_type stamp;
    if (lastHave && lastPath == path && (now - lastStat) < std::chrono::milliseconds(200)) {
        stamp = lastStamp;
    } else {
        std::error_code ec;
        stamp = std::filesystem::last_write_time(path, ec);
        if (ec)
            return false;
        lastStat = now;
        lastStamp = stamp;
        lastPath = path;
        lastHave = true;
    }
    stampOut = stamp;
    if (cache.ok && cachedPath == path && cache.stamp == stamp) {
        if (!cache.found)
            return false;
        rgb = cache.rgb;
        return true;
    }
    STintCache fresh;
    fresh.stamp = stamp;
    fresh.ok = true;
    std::ifstream f(path);
    if (f) {
        std::string line;
        while (std::getline(f, line)) {
            size_t i = 0;
            while (i < line.size() && (line[i] == ' ' || line[i] == '\t'))
                ++i;
            static constexpr const char* KEY = "background";
            if (line.compare(i, 10, KEY) != 0)
                continue;
            const size_t after = i + 10;
            // Exact key only: background_opacity / background_image / ... must
            // not match.
            if (after < line.size() && line[after] != ' ' && line[after] != '\t')
                continue;
            const size_t hash = line.find('#', after);
            if (hash == std::string::npos)
                continue;
            unsigned v = 0;
            int n = 0;
            for (size_t q = hash + 1; q < line.size() && n < 6; ++q) {
                const char c = line[q];
                unsigned d = 99;
                if (c >= '0' && c <= '9')
                    d = (unsigned)(c - '0');
                else if (c >= 'a' && c <= 'f')
                    d = (unsigned)(c - 'a' + 10);
                else if (c >= 'A' && c <= 'F')
                    d = (unsigned)(c - 'A' + 10);
                else
                    break;
                v = (v << 4) | d;
                ++n;
            }
            if (n == 6) {
                fresh.rgb = (int)v;
                fresh.found = true;
            } else if (n == 3) {
                const int r = (v >> 8) & 0xF, g = (v >> 4) & 0xF, b = v & 0xF;
                fresh.rgb = (r * 17 << 16) | (g * 17 << 8) | (b * 17);
                fresh.found = true;
            }
            // Last match wins: keep scanning.
        }
    }
    cache = fresh;
    cachedPath = path;
    if (!cache.found)
        return false;
    rgb = cache.rgb;
    return true;
}

// --- shaders -----------------------------------------------------------------

static GLint loc(GLuint program, const char* name) {
    return glGetUniformLocation(program, name);
}

// Window shader variant: the layer shader keeps squircle/flare/over-rim
// support; windows are always under-glass circular rounded boxes. Defining
// LG_WINDOW after #version lets the compiler strip the dead paths.
static std::string windowGlassFrag() {
    std::string src = SHADERS.at("glass.frag");
    // The embedded strings start with a newline, so inserting after the first
    // newline would put the define before #version and fail to compile. Anchor
    // on the version directive itself.
    const auto version = src.find("#version");
    const auto nl = version == std::string::npos ? src.find('\n') : src.find('\n', version);
    if (nl != std::string::npos)
        src.insert(nl + 1, "#define LG_WINDOW 1\n");
    return src;
}

void CWindowGlass::ensureShaders() {
    if (m_shadersOk)
        return;
    if (!m_glass)
        m_glass = makeShared<CShader>();
    if (!m_kawDown)
        m_kawDown = makeShared<CShader>();
    if (!m_kawUp)
        m_kawUp = makeShared<CShader>();
    if (!m_bokeh)
        m_bokeh = makeShared<CShader>();

    if (!m_glass->createProgram(SHADERS.at("glass.vert"), windowGlassFrag(), true)) {
        lg::notify("liquidglass: window glass shader failed to compile — window glass disabled");
        return;
    }
    if (!m_kawDown->createProgram(SHADERS.at("glass.vert"), SHADERS.at("kawase_down.frag"), true)) {
        lg::notify("liquidglass: kawase_down.frag failed to compile — window glass disabled");
        return;
    }
    if (!m_kawUp->createProgram(SHADERS.at("glass.vert"), SHADERS.at("kawase_up.frag"), true)) {
        lg::notify("liquidglass: kawase_up.frag failed to compile — window glass disabled");
        return;
    }
    if (!m_bokeh->createProgram(SHADERS.at("glass.vert"), SHADERS.at("bokeh.frag"), true)) {
        lg::notify("liquidglass: bokeh.frag failed to compile — window glass disabled");
        return;
    }

    const GLuint gp = m_glass->program();
    m_gu.proj = loc(gp, "proj");
    m_gu.pad = loc(gp, "uPad");
    m_gu.blur = loc(gp, "uBlur");
    m_gu.sharp = loc(gp, "uSharp");
    m_gu.rimBlur = loc(gp, "uRimBlur");
    m_gu.capOrigin = loc(gp, "uCapOrigin");
    m_gu.capScale = loc(gp, "uCapScale");
    m_gu.baseColor = loc(gp, "uBaseColor");
    m_gu.power = loc(gp, "uPower");
    m_gu.shape = loc(gp, "uShape");
    m_gu.a = loc(gp, "uA");
    m_gu.b = loc(gp, "uB");
    m_gu.c = loc(gp, "uC");
    m_gu.d = loc(gp, "uD");
    m_gu.fpower = loc(gp, "uFPower");
    m_gu.noise = loc(gp, "uNoise");
    m_gu.glowW = loc(gp, "uGlowW");
    m_gu.glowB = loc(gp, "uGlowB");
    m_gu.glowE0 = loc(gp, "uGlowE0");
    m_gu.glowE1 = loc(gp, "uGlowE1");
    m_gu.glowT = loc(gp, "uGlowT");
    m_gu.usePill = loc(gp, "uUsePill");
    m_gu.radii = loc(gp, "uRadii");
    m_gu.squircleF = loc(gp, "uSquircleF");
    m_gu.box = loc(gp, "uBox");
    m_gu.opacity = loc(gp, "uOpacity");
    m_gu.shadowColor = loc(gp, "uShadowColor");
    m_gu.shadowA = loc(gp, "uShadowA");
    m_gu.shadowOff = loc(gp, "uShadowOff");
    m_gu.shadowBlur = loc(gp, "uShadowBlur");
    m_gu.ca = loc(gp, "uCA");
    m_gu.detail = loc(gp, "uDetail");
    m_gu.lensBand = loc(gp, "uLensBand");
    m_gu.overRim = loc(gp, "uOverRim");
    m_gu.bevW = loc(gp, "uBevW");
    m_gu.edgePx = loc(gp, "uEdgePx");
    m_gu.logCME = loc(gp, "uLogCME");

    const GLuint kd = m_kawDown->program();
    m_kd.proj = loc(kd, "proj");
    m_kd.tex = loc(kd, "uTex");
    m_kd.radius = loc(kd, "uRadius");
    m_kd.halfpixel = loc(kd, "uHalfpixel");
    const GLuint ku = m_kawUp->program();
    m_ku.proj = loc(ku, "proj");
    m_ku.tex = loc(ku, "uTex");
    m_ku.radius = loc(ku, "uRadius");
    m_ku.halfpixel = loc(ku, "uHalfpixel");
    const GLuint bop = m_bokeh->program();
    m_bo.proj = loc(bop, "proj");
    m_bo.tex = loc(bop, "uTex");
    m_bo.radius = loc(bop, "uRadius");
    m_bo.halfpixel = loc(bop, "uHalfpixel");
    m_bo.bokeh = loc(bop, "uBokeh");

    if (m_vao == 0) {
        static constexpr float QUAD[16] = {
            0.0f, 0.0f, 0.0f, 0.0f,
            1.0f, 0.0f, 1.0f, 0.0f,
            0.0f, 1.0f, 0.0f, 1.0f,
            1.0f, 1.0f, 1.0f, 1.0f,
        };
        glGenVertexArrays(1, &m_vao);
        glGenBuffers(1, &m_vbo);
        glBindVertexArray(m_vao);
        glBindBuffer(GL_ARRAY_BUFFER, m_vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(QUAD), QUAD, GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)0);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));
        glBindVertexArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
    }

    m_shadersOk = true;
}

static GLuint fbId(const SP<Render::IFramebuffer>& fb) {
    return dynamic_cast<Render::GL::CGLFramebuffer*>(fb.get())->getFBID();
}

void CWindowGlass::ensureKawase(int hw, int hh, unsigned int format) {
    // PERF: halfT (bokeh output, L0 size) only when bokeh may run — was
    // always alloc'd even with bokeh=0 (default). Callers must check m_halfT
    // null when bokeh off. A (capture) always; B/C (chain) via ensureChain
    // below (over-rim runs a fixed chain even when passes==0). Per-instance
    // (not shared) to avoid realloc thrash alternating window sizes.
    bool changed = false;
    if (!m_halfA) {
        m_halfA = g_pHyprRenderer->createFB("liquidglass-win-a");
        changed = true;
    }
    if (!m_halfA)
        return;
    if (m_halfA->m_size.x != hw || m_halfA->m_size.y != hh) {
        m_halfA->alloc(hw, hh, format);
        changed = true;
    }
    if (changed)
        m_captureValid = false;
}

void CWindowGlass::ensureChain(int hw, int hh, unsigned int format) {
    // B/C scratch for the dual-Kawase chain. Lazy: small dialogs with
    // passes==0 and no over-rim never run the chain (sharp capture).
    const int qw = std::max(1, hw / 2), qh = std::max(1, hh / 2);
    const int ew = std::max(1, qw / 2), eh = std::max(1, qh / 2);
    bool changed = false;
    if (!m_halfB) {
        m_halfB = g_pHyprRenderer->createFB("liquidglass-win-b");
        changed = true;
    }
    if (!m_halfC) {
        m_halfC = g_pHyprRenderer->createFB("liquidglass-win-c");
        changed = true;
    }
    if (!m_halfB || !m_halfC)
        return;
    if (m_halfB->m_size.x != qw || m_halfB->m_size.y != qh) {
        m_halfB->alloc(qw, qh, format);
        changed = true;
    }
    if (m_halfC->m_size.x != ew || m_halfC->m_size.y != eh) {
        m_halfC->alloc(ew, eh, format);
        changed = true;
    }
    if (changed)
        m_captureValid = false;
}

void CWindowGlass::ensureBokeh(int hw, int hh, unsigned int format) {
    bool changed = false;
    if (!m_halfT) {
        m_halfT = g_pHyprRenderer->createFB("liquidglass-win-t");
        changed = true;
    }
    if (!m_halfT)
        return;
    if (m_halfT->m_size.x != hw || m_halfT->m_size.y != hh) {
        m_halfT->alloc(hw, hh, format);
        changed = true;
    }
    if (changed)
        m_captureValid = false;
}

void CWindowGlass::kawaseDown(const SP<Render::IFramebuffer>& src, const SP<Render::IFramebuffer>& dst, float radius) {
    const int dw = (int)dst->m_size.x, dh = (int)dst->m_size.y;
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(dst));
    g_pHyprOpenGL->setViewport(0, 0, dw, dh);
    glActiveTexture(GL_TEXTURE0);
    src->getTexture()->bind();
    src->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    src->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    auto shader = g_pHyprOpenGL->useShader(m_kawDown);
    glUniformMatrix3fv(m_kd.proj, 1, GL_FALSE, FULLSCREEN_PROJECTION.data());
    glUniform1i(m_kd.tex, 0);
    glUniform1f(m_kd.radius, radius);
    glUniform2f(m_kd.halfpixel, 0.5f / (int)src->m_size.x, 0.5f / (int)src->m_size.y);
    glBindVertexArray(m_vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
}

void CWindowGlass::kawaseUp(const SP<Render::IFramebuffer>& src, const SP<Render::IFramebuffer>& dst, float radius) {
    const int dw = (int)dst->m_size.x, dh = (int)dst->m_size.y;
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(dst));
    g_pHyprOpenGL->setViewport(0, 0, dw, dh);
    glActiveTexture(GL_TEXTURE0);
    src->getTexture()->bind();
    src->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    src->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    auto shader = g_pHyprOpenGL->useShader(m_kawUp);
    glUniformMatrix3fv(m_ku.proj, 1, GL_FALSE, FULLSCREEN_PROJECTION.data());
    glUniform1i(m_ku.tex, 0);
    glUniform1f(m_ku.radius, radius);
    glUniform2f(m_ku.halfpixel, 0.5f / (int)src->m_size.x, 0.5f / (int)src->m_size.y);
    glBindVertexArray(m_vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
}

void CWindowGlass::bokehPass(float radius, float strength) {
    const int dw = (int)m_halfT->m_size.x, dh = (int)m_halfT->m_size.y;
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(m_halfT));
    g_pHyprOpenGL->setViewport(0, 0, dw, dh);
    glActiveTexture(GL_TEXTURE0);
    m_halfA->getTexture()->bind();
    m_halfA->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    m_halfA->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    auto shader = g_pHyprOpenGL->useShader(m_bokeh);
    glUniformMatrix3fv(m_bo.proj, 1, GL_FALSE, FULLSCREEN_PROJECTION.data());
    glUniform1i(m_bo.tex, 0);
    glUniform1f(m_bo.radius, radius);
    glUniform2f(m_bo.halfpixel, 0.5f / (int)m_halfA->m_size.x, 0.5f / (int)m_halfA->m_size.y);
    glUniform1f(m_bo.bokeh, strength);
    glBindVertexArray(m_vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
}

// --- frame -------------------------------------------------------------------

// --- diagnostics ------------------------------------------------------------
// Silent skips are undebuggable headlessly, so every skip path reports here.
// Throttled: a line only when the reason changes, plus periodic heartbeats
// on draws. Abnormal states (null framebuffer/scratch) additionally toast
// once via lg::notify. Normal states (hidden/fullscreen) stay in the file.

static std::string diagPath() {
    if (const char* xdg = std::getenv("XDG_CACHE_HOME"); xdg && *xdg)
        return std::string(xdg) + "/liquid-glass-hypr/winglass.log";
    if (const char* home = std::getenv("HOME"); home && *home)
        return std::string(home) + "/.cache/liquid-glass-hypr/winglass.log";
    return {};
}

static bool diagVerbose() {
    // File appends from the render thread cost dearly during animations
    // (every window, every frame). Off unless explicitly debugging.
    static const bool v = [] {
        const char* e = std::getenv("LIQUIDGLASS_DIAG");
        return e && *e && *e != '0';
    }();
    return v;
}

static void diagLog(const std::string& line) {
    if (!diagVerbose())
        return;
    const std::string path = diagPath();
    if (path.empty())
        return;
    std::ofstream f(path, std::ios::app);
    f << line << std::endl;
}

static void diagSkip(const std::string& reason, const std::string& cls) {
    static std::string last;
    const std::string key = reason + "|" + cls;
    if (key == last)
        return;
    last = key;
    diagLog("winglass skip [" + reason + "] class=" + cls);
}

static void diagDraw(const std::string& cls, int w, int h) {
    // Heartbeat silenced by default (see diagVerbose): file appends from the
    // render thread on every 600th draw add up at 240 draws/s.
    static long n = 0;
    ++n;
    if (!diagVerbose())
        return;
    if (n <= 3 || n % 600 == 0)
        diagLog("winglass DRAW n=" + std::to_string(n) + " class=" + cls + " " + std::to_string(w) + "x"
                + std::to_string(h));
}

static void diagToastOnce(const std::string& key, const std::string& text) {
    static std::map<std::string, bool> done;
    if (done[key])
        return;
    done[key] = true;
    lg::notify(text);
}

static bool boxEqual(const CBox& a, const CBox& b) {
    return std::fabs(a.x - b.x) < 1e-3 && std::fabs(a.y - b.y) < 1e-3 && std::fabs(a.w - b.w) < 1e-3 &&
        std::fabs(a.h - b.h) < 1e-3;
}

void lg::noteWindowBox(PHLWINDOW win, PHLMONITOR mon) {
    if (!win || !mon || !win->m_isMapped || win->isHidden())
        return;
    Vector2D realPos = win->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    if (PHLWORKSPACE ws = win->m_workspace; ws && !win->m_pinned)
        realPos = realPos + ws->m_renderOffset->value();
    realPos = realPos + win->m_floatingOffset;
    const Vector2D realSize = win->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    CBox box{realPos.x - mon->m_position.x, realPos.y - mon->m_position.y, realSize.x, realSize.y};
    if (!std::isfinite(box.x) || !std::isfinite(box.y) || box.w <= 0 || box.h <= 0)
        return;
    box.scale(mon->m_scale).round().noNegativeSize();
    if (box.w <= 0 || box.h <= 0)
        return;
    g_pHyprRenderer->m_renderData.renderModif.applyToBox(box);
    if (box.w <= 0 || box.h <= 0)
        return;
    (*WINDOW_BOXES)[mon->m_id].push_back(box);
}

void CWindowGlass::damageLast() {
    m_captureValid = false;
    if (!m_boundsOk || m_boundsLog.w <= 0 || m_boundsLog.h <= 0)
        return;
    m_boundsOk = false;
    g_pHyprRenderer->damageBox(CBox{m_lastMonPos.x + m_boundsLog.x, m_lastMonPos.y + m_boundsLog.y, m_boundsLog.w,
                                   m_boundsLog.h});
}

std::optional<SWinDraw> CWindowGlass::snapshot(PHLMONITOR monitor) {
    const auto win = m_window.lock();
    if (!win || !monitor)
        return std::nullopt;
    const std::string cls = win->m_class;
    m_lastCls = cls;
    // Skip-with-cleanup: unmapped/hidden/fullscreen/degenerate geometry
    // must repaint the last-known region instead of leaving a static ghost
    // (workspace switches, fullscreening, closes).
    auto bail = [&] { damageLast(); };

    const bool live = win->m_isMapped && win->isHidden() == false;
    if (!live) {
        diagSkip(win->m_isMapped ? "hidden" : "unmapped", cls);
        bail();
        return std::nullopt;
    }

    // A fully opaque window covers the entire glass pane. Drawing it would
    // only produce pixels the content immediately overwrites, so skip the
    // whole capture/shader path. opaque() also returns false during alpha
    // fades, which is exactly where we still want the glass to follow.
    if (win->opaque()) {
        diagSkip("opaque", cls);
        bail();
        return std::nullopt;
    }

    // Window open/close fades still skip: at <1 alpha the content is already
    // fading and drawing a fresh backdrop would flash. Workspace slides are
    // deliberately NOT skipped any more: glass rides the same crop/offset and
    // alpha as the window content.
    const auto& fade = win->alpha(Desktop::View::WINDOW_ALPHA_FADE);
    if (fade && (fade->isBeingAnimated() || fade->value() < 0.999f)) {
        diagSkip("window-fade", cls);
        bail();
        return std::nullopt;
    }

    // A transition means the backdrop under every glass pane is changing.
    // Keep drawing, but disable the shared backdrop and the content-only
    // cache: both assume a static lower scene.
    bool wsTransition = workspaceAnimating(monitor);
    if (PHLWORKSPACE ws = win->m_workspace; ws && !win->m_pinned) {
        const Vector2D off = ws->m_renderOffset->value();
        wsTransition = wsTransition || ws->m_renderOffset->isBeingAnimated() || ws->m_alpha->isBeingAnimated() ||
            std::abs(off.x) > 0.5 || std::abs(off.y) > 0.5 || ws->m_alpha->value() < 0.999f;
    }
    const bool transitioning = wsTransition || goo::transitioning(monitor->m_id);

    // Window box, global logical px — EXACT upstream REALPOS replication
    // (IHyprRenderer::renderWindow): geometric position + workspace slide
    // offset + floating offset. renderModif is deliberately NOT used here:
    // upstream only sets it around decoration/border draws, never for window
    // content — the slide lives in m_renderOffset, which is also what the
    // (correctly riding) borders derive from via renderdata.pos.
    Vector2D realPos = win->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    float wsAlpha = 1.f;
    if (PHLWORKSPACE ws = win->m_workspace; ws && !win->m_pinned) {
        realPos = realPos + ws->m_renderOffset->value();
        wsAlpha = std::clamp(ws->m_alpha->value(), 0.f, 1.f);
    }
    // Goo fades outgoing windows on WINDOW_ALPHA_MOVE_FROM_WORKSPACE; the
    // content uses that channel, so the glass must multiply it too or the
    // pane stays solid under a fading terminal.
    if (const auto& moveFrom = win->alpha(Desktop::View::WINDOW_ALPHA_MOVE_FROM_WORKSPACE); moveFrom)
        wsAlpha *= std::clamp(moveFrom->value(), 0.f, 1.f);
    realPos = realPos + win->m_floatingOffset;
    const Vector2D realSize = win->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    const CBox logBox{realPos.x, realPos.y, realSize.x, realSize.y};
    if (!std::isfinite(logBox.x) || !std::isfinite(logBox.y) || logBox.w <= 0 || logBox.h <= 0) {
        diagSkip("badbox", cls);
        bail();
        return std::nullopt;
    }

    // Fullscreen coverage: nothing alive behind the window, glass would only
    // burn GPU to repaint the tint. (Geometry check on purpose — no
    // fullscreen-state API needed, and it also covers maximized-to-monitor.)
    if (logBox.w >= monitor->m_size.x * 0.99 && logBox.h >= monitor->m_size.y * 0.99) {
        diagSkip("fullscreen", cls);
        bail();
        return std::nullopt;
    }

    // Monitor-local framebuffer px — exactly what projectBoxToTarget wants.
    CBox winBox{logBox};
    winBox.translate(-monitor->m_position);
    winBox.scale(monitor->m_scale).round().noNegativeSize();
    if (winBox.w <= 0 || winBox.h <= 0) {
        bail();
        return std::nullopt;
    }

    // renderModif applied as harmless insurance (identity in practice for
    // window content; cf. BorderGlass): real motion tracking comes from the
    // renderOffset replication above.
    g_pHyprRenderer->m_renderData.renderModif.applyToBox(winBox);
    const float modifScale = g_pHyprRenderer->m_renderData.renderModif.combinedScale();
    if (winBox.w <= 0 || winBox.h <= 0) {
        bail();
        return std::nullopt;
    }

    // Liquid window motion: a short spring-driven bulge along the axis the
    // window is moving/growing on. Drag, resize and workspace-move all feed
    // the same velocity; content and input are untouched, only the glass
    // silhouette stretches and settles. Directional and capped, so it never
    // becomes a smear.
    if (lg::getInt("plugin:liquidglass:window_motion", 1) != 0) {
        const CBox target = winBox;
        const auto now = std::chrono::steady_clock::now();
        if (!m_motionInit) {
            m_motionInit = true;
            m_motionT = now;
            m_motionLast = target;
            m_motionStretch = 0;
        } else {
            float dt = std::chrono::duration<float>(now - m_motionT).count();
            m_motionT = now;
            dt = std::clamp(dt, 0.001f, 0.05f);
            const float cx = (float)(target.x + target.w * 0.5);
            const float cy = (float)(target.y + target.h * 0.5);
            const float lx = (float)(m_motionLast.x + m_motionLast.w * 0.5);
            const float ly = (float)(m_motionLast.y + m_motionLast.h * 0.5);
            const float vx = (cx - lx) / dt;
            const float vy = (cy - ly) / dt;
            const float sxs = (float)(target.w - m_motionLast.w) / dt;
            const float sys = (float)(target.h - m_motionLast.h) / dt;
            const float gain = lg::getFloat("plugin:liquidglass:window_motion_gain", 0.00002f);
            const float maxStretch = std::clamp(lg::getFloat("plugin:liquidglass:window_motion_max", 0.05f), 0.0f, 0.12f);
            const float speed = std::max(std::sqrt(vx * vx + vy * vy), std::sqrt(sxs * sxs + sys * sys));
            const float targetStretch = std::clamp(speed * gain, 0.0f, maxStretch);
            const float blend = 1.0f - std::exp(-dt * 20.0f);
            m_motionStretch += (targetStretch - m_motionStretch) * blend;
            if (m_motionStretch > 0.001f) {
                const float ex = (float)winBox.w * m_motionStretch * 0.5f;
                const float ey = (float)winBox.h * m_motionStretch * 0.5f;
                if (std::fabs(vx) + std::fabs(sxs) >= std::fabs(vy) + std::fabs(sys)) {
                    winBox.x -= ex;
                    winBox.w += 2.0 * ex;
                } else {
                    winBox.y -= ey;
                    winBox.h += 2.0 * ey;
                }
            }
            m_motionLast = target;
        }
    }

    // Shared backdrop eligibility. WINDOW_BOXES holds every main-pass window
    // drawn earlier this frame, including non-glass ones. If any of them
    // intersects this window's padded capture area, the shared pre-window
    // capture no longer represents the backdrop; fall back to the per-window
    // read of the live framebuffer.
    // The pre-window capture is the static backdrop even while windows slide
    // or morph. It remains valid unless an earlier window (possibly also
    // moving) overlaps this pane's padded capture region; only that case
    // needs the live read-after-write fallback.
    bool useShared = true;
    if (auto it = WINDOW_BOXES->find(monitor->m_id); it != WINDOW_BOXES->end()) {
        const CBox padded{winBox.x - PAD_PX, winBox.y - PAD_PX, winBox.w + 2 * PAD_PX, winBox.h + 2 * PAD_PX};
        for (const auto& prev : it->second) {
            if (!prev.intersection(padded).empty()) {
                useShared = false;
                break;
            }
        }
    }
    if (transitioning)
        m_captureValid = false;

    // Content-only damage: if every damaged pixel is inside this window and
    // no earlier window overlaps it, the backdrop behind the glass has not
    // changed. Reuse the previous blurred capture instead of blitting the
    // whole pane again. This is the typing/video case; moves, workspace
    // slides and anything outside the pane still recapture.
    const CBox dmg = g_pHyprRenderer->m_renderData.damage.getExtents();
    const bool contentOnly = dmg.w > 0 && dmg.h > 0 && dmg.x >= winBox.x - 1 && dmg.y >= winBox.y - 1 &&
        dmg.x + dmg.w <= winBox.x + winBox.w + 1 && dmg.y + dmg.h <= winBox.y + winBox.h + 1;
    const bool reuse = useShared && contentOnly && m_captureValid && m_cacheMon == monitor->m_id &&
        std::fabs(m_cacheMonScale - monitor->m_scale) < 1e-4 && m_cacheMonSize.x == monitor->m_transformedSize.x &&
        m_cacheMonSize.y == monitor->m_transformedSize.y && boxEqual(m_cacheBox, winBox);

    // Window's own rounding (windowrule + decoration), framebuffer px,
    // clamped to the box. Uniform corners: the window shape is one roundBox.
    float rad = win->rounding() * monitor->m_scale * modifScale;
    rad = std::clamp(rad, 0.0f, (float)std::min(winBox.w, winBox.h) * 0.5f);

    // Damage on change only — same contract as the layer pills (see
    // CGlassLayer::render): morphs change the union below, slider edits bump
    // the tune generation, kitty.conf edits change the tint stamp.
    const uint64_t tuneGen = lg::tuneGeneration();
    int tintRgb = 0;
    std::filesystem::file_time_type tintStamp = std::filesystem::file_time_type::min();
    // Terminal tint file only applies to kitty: Zen (and future window
    // classes) uses the theme tint (matugen surface, auto dark/light).
    const bool haveTint = cls.find("kitty") != std::string::npos && windowTintRgb(tintRgb, tintStamp);
    // Same quarter-blur / half-offset shadow as the layer pills (see Glass.cpp).
    const float shBlurPad = lg::getFloat("plugin:liquidglass:shadow_blur", 57.0f) * 0.25f;
    const float shOffX = lg::getFloat("plugin:liquidglass:shadow_offset_x", 0.0f);
    const float shOffY = lg::getFloat("plugin:liquidglass:shadow_offset_y", 20.0f) * 0.5f;
    {
        const double inv = 1.0 / (double)monitor->m_scale;
        const double PAD = (double)(shBlurPad * 2.2f + std::max(std::fabs(shOffX), std::fabs(shOffY)) + 8.0f) * inv;
        const CBox fresh{(winBox.x * inv) - PAD, (winBox.y * inv) - PAD, (winBox.w * inv) + 2 * PAD,
                         (winBox.h * inv) + 2 * PAD};
        auto sameBox = [](const CBox& a, const CBox& b) {
            return std::fabs(a.x - b.x) < 1e-3 && std::fabs(a.y - b.y) < 1e-3 && std::fabs(a.w - b.w) < 1e-3
                && std::fabs(a.h - b.h) < 1e-3;
        };
        const bool tintChanged = haveTint && (!m_haveTintStamp || m_tintStamp != tintStamp);
        if (!m_boundsOk) {
            m_boundsLog = fresh;
            m_lastMonPos = monitor->m_position;
            m_boundsOk = true;
            m_tuneGen = tuneGen;
            m_tintStamp = tintStamp;
            m_haveTintStamp = haveTint;
            g_pHyprRenderer->damageBox(CBox{monitor->m_position.x + m_boundsLog.x, monitor->m_position.y + m_boundsLog.y,
                                           m_boundsLog.w, m_boundsLog.h});
        } else if (!sameBox(m_boundsLog, fresh) || m_tuneGen != tuneGen || tintChanged) {
            const double ux0 = std::min(m_boundsLog.x, fresh.x);
            const double uy0 = std::min(m_boundsLog.y, fresh.y);
            const double ux1 = std::max(m_boundsLog.x + m_boundsLog.w, fresh.x + fresh.w);
            const double uy1 = std::max(m_boundsLog.y + m_boundsLog.h, fresh.y + fresh.h);
            m_boundsLog = fresh;
            m_lastMonPos = monitor->m_position;
            m_tuneGen = tuneGen;
            m_tintStamp = tintStamp;
            m_haveTintStamp = haveTint;
            g_pHyprRenderer->damageBox(
                CBox{monitor->m_position.x + ux0, monitor->m_position.y + uy0, ux1 - ux0, uy1 - uy0});
        }
    }

    // Active-window glow boost (+window_active_glow, 0.2): the active window
    // is signalled by glass glow now that the active border is gone (see
    // hyprland.lua). Ramped ~180ms: each snapshot steps toward the target
    // and damages while moving so the transition animates instead of
    // jumping. Bounded by construction (lands exactly via clamp).
    {
        const bool focused = (uintptr_t)win.get() == s_focusedAddr.load(std::memory_order_relaxed);
        const float target = focused ? lg::getFloat("plugin:liquidglass:window_active_glow", 0.2f) : 0.0f;
        const auto now = std::chrono::steady_clock::now();
        if (!m_glowInit) {
            m_glowAdd = target;
            m_glowInit = true;
            m_glowT = now;
        } else if (m_glowAdd != target) {
            const float dt = std::chrono::duration<float>(now - m_glowT).count();
            m_glowT = now;
            const float step = dt * 1.2f;
            if (m_glowAdd < target)
                m_glowAdd = std::min(target, m_glowAdd + step);
            else
                m_glowAdd = std::max(target, m_glowAdd - step);
            g_pHyprRenderer->damageBox(CBox{monitor->m_position.x + m_boundsLog.x, monitor->m_position.y + m_boundsLog.y,
                                           m_boundsLog.w, m_boundsLog.h});
        } else {
            m_glowT = now;
        }
    }

    // Tint: kitty uses the terminal's own background color; Zen uses the
    // theme tint. Alpha stays with the registered theme-tint low byte
    // (same convention as the matugen tint path).
    const int themeTint = lg::getInt("plugin:liquidglass:tint", 0xeef5f2ff);
    const int winTint = haveTint ? (((tintRgb << 8) & 0xFFFFFF00) | (themeTint & 0xFF)) : themeTint;
    SWinDraw out{winBox, rad, winTint, wsAlpha, m_glowAdd};
    out.useShared = useShared;
    out.reuseCapture = reuse;
    return out;
}

void CWindowGlass::draw(PHLMONITOR monitor, const SWinDraw& d, bool overRim) {
    if (!monitor)
        return;
    const std::string& cls = m_lastCls;

    ensureShaders();
    if (!m_shadersOk) {
        diagSkip("shaders", cls);
        return;
    }

    const auto caller = g_pHyprRenderer->m_renderData.currentFB;
    if (!caller) {
        diagSkip("null-caller", cls);
        diagToastOnce("null-caller", "liquidglass: window glass has no framebuffer");
        return;
    }
    const auto callerSize = caller->m_size;
    const int srcW = (int)caller->m_size.x;
    const int srcH = (int)caller->m_size.y;

    // Hoisted damage gate ("skip entirely, keep visible"): the draw quad
    // (window + shadow margin) needs only the shadow extent, so 3 tune reads
    // decide before the ~20-strong Tune block + blend setup below. Gated
    // windows return with the framebuffer untouched — last glass pixels stay
    // on screen. Empty damage likewise returns (nothing stale: snapshot()
    // in the hook already damaged on bounds/tune/tint/glow change).
    {
        const float shB0 = lg::getFloat("plugin:liquidglass:shadow_blur", 57.0f) * 0.25f;
        const float shX0 = lg::getFloat("plugin:liquidglass:shadow_offset_x", 0.0f);
        const float shY0 = lg::getFloat("plugin:liquidglass:shadow_offset_y", 20.0f) * 0.5f;
        const float Eg0 = shB0 * 2.2f + std::max(std::fabs(shX0), std::fabs(shY0)) + 8.0f;
        const CBox dmg0 = g_pHyprRenderer->m_renderData.damage.getExtents();
        if (dmg0.w <= 0 || dmg0.h <= 0) {
            diagSkip("gated", cls);
            return;
        }
        const double gx0 = d.box.x - Eg0, gy0 = d.box.y - Eg0;
        const double gx1 = d.box.x + d.box.w + Eg0, gy1 = d.box.y + d.box.h + Eg0;
        if (gx1 <= dmg0.x || gy1 <= dmg0.y || gx0 >= dmg0.x + dmg0.w || gy0 >= dmg0.y + dmg0.h) {
            diagSkip("gated", cls);
            return;
        }
    }

    struct Tune {
        float userRadius;
        int userPasses;
        int capDiv; // working-res divisor (2 half / 4 quarter)
        int shCol;
        float power, shapeW, shapeH, a, b, c, d, fpower, noise;
        float glowW, glowB, glowE0, glowE1, glowT, opacity, ca, detail;
        float shOx, shOy, shBlur;
    };
    const float shBlurPad = lg::getFloat("plugin:liquidglass:shadow_blur", 57.0f) * 0.25f;
    const Tune T{
        lg::getFloat("plugin:liquidglass:blur_radius", 2.0f),
        std::max(1, std::min(3, (int)std::round(lg::getFloat("plugin:liquidglass:blur_iters", 2.0f)))),
        std::max(2, std::min(4, (int)std::round(lg::getFloat("plugin:liquidglass:capture_scale", 4.0f)))),
        lg::getInt("plugin:liquidglass:shadow_color", 0x1a1a1a11),
        lg::getFloat("plugin:liquidglass:power", 3.0f),
        lg::getFloat("plugin:liquidglass:shape_width", 3.5f),
        lg::getFloat("plugin:liquidglass:shape_height", 3.5f),
        lg::getFloat("plugin:liquidglass:a", 0.7f),
        lg::getFloat("plugin:liquidglass:b", 2.3f),
        lg::getFloat("plugin:liquidglass:c", 5.2f),
        lg::getFloat("plugin:liquidglass:d", 6.9f),
        lg::getFloat("plugin:liquidglass:fpower", 1.0f),
        lg::getFloat("plugin:liquidglass:noise", 0.06f),
        lg::getFloat("plugin:liquidglass:glow_weight", 0.25f),
        lg::getFloat("plugin:liquidglass:glow_bias", 0.0f),
        lg::getFloat("plugin:liquidglass:glow_edge0", 0.5f),
        lg::getFloat("plugin:liquidglass:glow_edge1", -0.5f),
        lg::getFloat("plugin:liquidglass:glow_threshold", 0.5f),
        lg::getFloat("plugin:liquidglass:opacity", 0.82f),
        lg::getFloat("plugin:liquidglass:ca", 0.5f),
        lg::getFloat("plugin:liquidglass:detail_preserve", 1.0f),
        lg::getFloat("plugin:liquidglass:shadow_offset_x", 0.0f),
        lg::getFloat("plugin:liquidglass:shadow_offset_y", 20.0f) * 0.5f,
        shBlurPad,
    };
    const double screenMinLog = std::min(monitor->m_size.x, monitor->m_size.y);

    const CBox dmgExt = g_pHyprRenderer->m_renderData.damage.getExtents();

    // PERF: no glGet* save/restore (pipeline stalls; was 5 gets per window
    // per frame). Hyprland re-sets blend per draw anyway.
    glEnable(GL_BLEND);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    const auto transform = Math::wlTransformToHyprutils(Math::invertTransform(monitor->m_transform));

    // The window is one pill: full rect, uniform window rounding.
    const int px0 = (int)std::floor(d.box.x);
    const int py0 = (int)std::floor(d.box.y);
    const int px1 = (int)std::ceil(d.box.x + d.box.w);
    const int py1 = (int)std::ceil(d.box.y + d.box.h);
    if (px1 > px0 && py1 > py0) {
        // Size-proportional blur, same rule as pills and rings: windows are
        // large so they converge to the full user setting.
        // Radius is resolution-proportional (x monitor scale): a scale-blind
        // framebuffer-px spread reads ~half as strong on a 2.4x 4K panel as
        // on the 1.6x primary for same-size windows.
        const double winMinLog = (double)std::min(d.box.w, d.box.h) / (double)monitor->m_scale;
        const float sizeK = (float)std::clamp(winMinLog / screenMinLog, 0.0, 1.0);
        const float radius = T.userRadius * sizeK * (overRim ? 2.0f : 1.0f);
        // Resolution-corrected like layers (see Glass.cpp): identical look
        // at any capture_scale (2 = old).
        const float effR = radius * std::sqrt((float)T.userPasses) * 0.5f * (float)monitor->m_scale
            * (2.0f / (float)T.capDiv);
        // (Skip threshold in screen-space units like layers, so behavior is
        // identical at any capture_scale.)
        const int passes = effR < 0.1f * (2.0f / (float)T.capDiv) ? 0 : T.userPasses;
        const float bokeh = lg::getFloat("plugin:liquidglass:bokeh", 0.0f);
        const bool bokehOn = bokeh > 0.01f;

        // (Damage gate hoisted to draw() head: outside-damage and empty-damage
        // windows return there, before Tune+blend. Reaching here means our
        // quad intersects damage.)
        {
            diagDraw(cls, px1 - px0, py1 - py0);
            int rx0 = std::max(0, px0 - PAD_PX), ry0 = std::max(0, py0 - PAD_PX);
            int rx1 = std::min(srcW, px1 + PAD_PX), ry1 = std::min(srcH, py1 + PAD_PX);
            const int rw = rx1 - rx0, rh = ry1 - ry0;
            if (rw >= 8 && rh >= 8) {
                // Working res: capture_scale divisor (see Glass.cpp).
                const int hw = std::max(1, rw / T.capDiv), hh = std::max(1, rh / T.capDiv);
                ensureKawase(hw, hh, caller->m_drmFormat);
                // Chain scratch lazy: only when the chain below runs
                // (over-rim fixed chain, or passes>0). Small sharp-capture
                // dialogs skip B/C entirely.
                if (overRim || passes > 0)
                    ensureChain(hw, hh, caller->m_drmFormat);
                // Bokeh output lazy (see ensureKawase): only with bokeh on.
                if (bokehOn)
                    ensureBokeh(hw, hh, caller->m_drmFormat);
                // Sharp capture for the over-rim progressive mix (same size
                // and UV contract as L0). Lazy: only the rim pass needs it.
                if (overRim) {
                    if (!m_sharp)
                        m_sharp = g_pHyprRenderer->createFB("liquidglass-win-sharp");
                    if (m_sharp && (m_sharp->m_size.x != hw || m_sharp->m_size.y != hh))
                        m_sharp->alloc(hw, hh, caller->m_drmFormat);
                }
                const bool needChain = overRim || passes > 0;
                if (!m_halfA || !m_halfA->getTexture()
                    || (needChain && (!m_halfB || !m_halfC || !m_halfB->getTexture() || !m_halfC->getTexture()))
                    || (bokehOn && (!m_halfT || !m_halfT->getTexture()))
                    || (overRim && (!m_sharp || !m_sharp->getTexture()))) {
                    diagSkip("null-scratch", cls);
                    diagToastOnce("null-scratch", "liquidglass: window glass scratch alloc failed");
                } else {
                    g_pHyprOpenGL->setCapStatus(GL_SCISSOR_TEST, false);
                    // Over-rim captures the composed framebuffer, not the
                    // backdrop; it must never leave a reusable under-glass
                    // cache behind.
                    if (overRim)
                        m_captureValid = false;

                    // Content-only damage hit: the blurred backdrop in
                    // m_halfA (and m_halfT when bokeh is on) is still exact.
                    // Skip the blit/sync and the Kawase chain entirely; the
                    // glass shader below still redraws its damaged region.
                    const bool cacheOk = !overRim && d.reuseCapture && d.useShared && m_captureValid &&
                        m_cacheMon == monitor->m_id && std::fabs(m_cacheMonScale - monitor->m_scale) < 1e-4 &&
                        m_cacheMonSize.x == monitor->m_transformedSize.x &&
                        m_cacheMonSize.y == monitor->m_transformedSize.y && boxEqual(m_cacheBox, d.box) &&
                        m_cacheCapDiv == T.capDiv && m_cachePasses == passes && m_cacheHw == hw && m_cacheHh == hh &&
                        m_cacheBokehOn == bokehOn && (!bokehOn || std::fabs(m_cacheBokeh - bokeh) < 1e-4) &&
                        m_cacheTuneGen == lg::tuneGeneration();

                    if (!cacheOk) {
                        bool fromShared = false;
                        // 1. Copy the window's sub-rect from this frame's
                        // pre-window backdrop when an earlier window does not
                        // overlap it. This is a read from a stable texture,
                        // not the current framebuffer, so it does not force
                        // the per-window read-after-write pipeline drain.
                        if (d.useShared) {
                            auto bd = backdropFor(monitor->m_id);
                            if (bd && bd->valid && bd->capDiv == T.capDiv && bd->capture && bd->capture->getTexture()) {
                                const int sx0 = rx0 / T.capDiv, sy0 = ry0 / T.capDiv;
                                const int sw = std::max(1, rw / T.capDiv), sh = std::max(1, rh / T.capDiv);
                                if (sx0 >= 0 && sy0 >= 0 && sx0 + sw <= bd->capW && sy0 + sh <= bd->capH) {
                                    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbId(bd->capture));
                                    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbId(m_halfA));
                                    glBlitFramebuffer(sx0, sy0, sx0 + sw, sy0 + sh, 0, 0, hw, hh, GL_COLOR_BUFFER_BIT,
                                                      GL_LINEAR);
                                    fromShared = true;
                                }
                            }
                        }
                        // 1b. Fallback: overlapping/stacked windows need the
                        // live composited framebuffer, including everything
                        // drawn before this window.
                        if (!fromShared) {
                            // PERF: no glClear (blit overwrites; was fullscreen fill).
                            glBindFramebuffer(GL_FRAMEBUFFER, fbId(m_halfA));
                            g_pHyprOpenGL->setViewport(0, 0, hw, hh);
                            glBindFramebuffer(GL_READ_FRAMEBUFFER, fbId(caller));
                            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbId(m_halfA));
                            glBlitFramebuffer(rx0, ry0, rx1, ry1, 0, 0, hw, hh, GL_COLOR_BUFFER_BIT, GL_LINEAR);
                        }

                        // 1c. Sharp copy for the over-rim progressive mix
                        // (same region and UVs as L0, no Kawase passes run on it).
                        if (overRim) {
                            glBindFramebuffer(GL_FRAMEBUFFER, fbId(m_sharp));
                            g_pHyprOpenGL->setViewport(0, 0, hw, hh);
                            glBindFramebuffer(GL_READ_FRAMEBUFFER, fbId(caller));
                            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbId(m_sharp));
                            glBlitFramebuffer(rx0, ry0, rx1, ry1, 0, 0, hw, hh, GL_COLOR_BUFFER_BIT, GL_LINEAR);
                        }

                        // 2. Dual-Kawase chain in halfA -> halfB -> halfC and back.
                        // iters>=3 runs the depth-2 cycle twice. Skipped when
                        // passes==0 (sharp capture). Over-rim instead runs the
                        // fixed r=3 / 2-iteration chain: the shader ramps sharp
                        // (edge) to this (band end) across its own band width.
                        if (overRim) {
                            const float rimEffR = 3.0f * std::sqrt(2.0f) * 0.5f * (float)monitor->m_scale;
                            kawaseDown(m_halfA, m_halfB, rimEffR);
                            kawaseDown(m_halfB, m_halfC, rimEffR);
                            kawaseUp(m_halfC, m_halfB, rimEffR);
                            kawaseUp(m_halfB, m_halfA, rimEffR);
                        } else if (passes > 0) {
                            const int rounds = T.userPasses >= 3 ? 2 : 1;
                            for (int k = 0; k < rounds; k++) {
                                kawaseDown(m_halfA, m_halfB, effR);
                                if (T.userPasses >= 2) {
                                    kawaseDown(m_halfB, m_halfC, effR);
                                    kawaseUp(m_halfC, m_halfB, effR);
                                }
                                kawaseUp(m_halfB, m_halfA, effR);
                            }
                        }
                        // 2b. Bokeh scatter into the L0-size temp.
                        if (bokehOn)
                            bokehPass(effR, bokeh);

                        // This capture is reusable next frame if only window
                        // content changes.
                        if (!overRim) {
                            m_captureValid = true;
                            m_cacheBox = d.box;
                            m_cacheMon = monitor->m_id;
                            m_cacheMonScale = monitor->m_scale;
                            m_cacheMonSize = monitor->m_transformedSize;
                            m_cacheCapDiv = T.capDiv;
                            m_cachePasses = passes;
                            m_cacheHw = hw;
                            m_cacheHh = hh;
                            m_cacheBokehOn = bokehOn;
                            m_cacheBokeh = bokeh;
                            m_cacheTuneGen = lg::tuneGeneration();
                        }
                    }

                    // 3. Glass quad over the window rect (+shadow margin E).
                    {
                        const float ox = (px0 - rx0) / (float)rw, oy = (py0 - ry0) / (float)rh;
                        const float sx = (px1 - px0) / (float)rw, sy = (py1 - py0) / (float)rh;

                        // (Eg recomputed from Tune: the hoisted gate above used
                        // its own 3 reads and returned when outside damage.)
                        const float E = T.shBlur * 2.2f + std::max(std::fabs(T.shOx), std::fabs(T.shOy)) + 8.0f;
                        const float ex0 = (float)d.box.x - E, ey0 = (float)d.box.y - E;
                        const float ew = (float)d.box.w + 2 * E, eh = (float)d.box.h + 2 * E;
                        CBox quadBox{ex0, ey0, ew, eh};
                        Mat3x3 proj = g_pHyprRenderer->projectBoxToTarget(quadBox, transform);

                        glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
                        g_pHyprOpenGL->setViewport(0, 0, (int)callerSize.x, (int)callerSize.y);
                        glActiveTexture(GL_TEXTURE0);
                        // Bokeh output shares L0's size and UV contract: sample it directly.
                        // Falls back to L0 when bokeh alloc failed.
                        const bool useBokeh = bokehOn && m_halfT && m_halfT->getTexture();
                        const auto& uBlurFb = useBokeh ? m_halfT : m_halfA;
                        uBlurFb->getTexture()->bind();
                        uBlurFb->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                        uBlurFb->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                        // Sharp side of the over-rim mix on unit 1. Under-glass
                        // windows have no rim overdraw and the specialized
                        // shader strips uSharp, so don't bind it there.
                        if (overRim) {
                            glActiveTexture(GL_TEXTURE1);
                            m_sharp->getTexture()->bind();
                            m_sharp->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                            m_sharp->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                            glActiveTexture(GL_TEXTURE0);
                        }

                        auto shader = g_pHyprOpenGL->useShader(m_glass);
                        glUniformMatrix3fv(m_gu.proj, 1, GL_TRUE, proj.getMatrix().data());
                        glUniform4f(m_gu.pad, ((float)d.box.x - ex0) / ew, ((float)d.box.y - ey0) / eh,
                                   (float)d.box.w / ew, (float)d.box.h / eh);
                        glUniform1i(m_gu.blur, 0);
                        glUniform1i(m_gu.sharp, 1);
                        glUniform1f(m_gu.rimBlur, overRim ? 1.0f : 0.0f);
                        glUniform2f(m_gu.capOrigin, ox, oy);
                        glUniform2f(m_gu.capScale, sx, sy);
                        glUniform3f(m_gu.baseColor, ((d.tint >> 24) & 0xFF) / 255.f, ((d.tint >> 16) & 0xFF) / 255.f,
                                   ((d.tint >> 8) & 0xFF) / 255.f);
                        glUniform1f(m_gu.power, T.power);
                        glUniform2f(m_gu.shape, T.shapeW, T.shapeH);
                        glUniform1f(m_gu.a, T.a);
                        glUniform1f(m_gu.b, T.b);
                        glUniform1f(m_gu.c, T.c);
                        glUniform1f(m_gu.d, T.d);
                        glUniform1f(m_gu.fpower, T.fpower);
                        glUniform1f(m_gu.noise, T.noise);
                        glUniform1f(m_gu.glowW, T.glowW + d.glowAdd);
                        glUniform1f(m_gu.glowB, T.glowB);
                        glUniform1f(m_gu.glowE0, T.glowE0);
                        glUniform1f(m_gu.glowE1, T.glowE1);
                        glUniform1f(m_gu.glowT, T.glowT);
                        glUniform1f(m_gu.usePill, 1.0f);
                        // Window glass follows the same squircle exponent as
                        // the shell/window content (Hyprland's rounding_power
                        // is derived from the same squircleF). A config value
                        // >= 0 overrides it; 0 keeps the old circular glass.
                        {
                            float wsf = lg::getFloat("plugin:liquidglass:window_squircle_f", -1.0f);
                            if (wsf < 0.0f)
                                wsf = lg::getFloat("plugin:liquidglass:squircle_f", 0.5f);
                            glUniform1f(m_gu.squircleF, std::clamp(wsf, 0.0f, 1.0f));
                        }
                        glUniform4f(m_gu.radii, d.rad, d.rad, d.rad, d.rad);
                        glUniform2f(m_gu.box, (float)(px1 - px0), (float)(py1 - py0));
                        // Window-only strength (default: follow shared opacity).
                        // Negative window_opacity = follow.
                        {
                            float wop = lg::getFloat("plugin:liquidglass:window_opacity", -1.0f);
                            if (wop < 0)
                                wop = T.opacity;
                            glUniform1f(m_gu.opacity, wop * d.alphaMul);
                        }
                        glUniform3f(m_gu.shadowColor, ((T.shCol >> 24) & 0xFF) / 255.f,
                                   ((T.shCol >> 16) & 0xFF) / 255.f, ((T.shCol >> 8) & 0xFF) / 255.f);
                        glUniform1f(m_gu.shadowA, ((T.shCol & 0xFF) / 255.f));
                        glUniform2f(m_gu.shadowOff, T.shOx, T.shOy);
                        glUniform1f(m_gu.shadowBlur, T.shBlur);
                        glUniform1f(m_gu.ca, T.ca);
                        glUniform1f(m_gu.detail, T.detail);
                        glUniform1f(m_gu.lensBand, 1.0f); // windows: lens confined to the glow band
                        glUniform1f(m_gu.overRim, overRim ? 1.0f : 0.0f);
                        // PERF: precompute per-fragment log()s on CPU.
                        {
                            const float mn = std::min((float)(px1 - px0), (float)(py1 - py0));
                            const float lg = std::log(1.0f + mn / 30.0f);
                            glUniform1f(m_gu.bevW, std::max((7.0f + 3.5f * lg) * 1.5f, 4.0f));
                            glUniform1f(m_gu.edgePx, (7.0f + 3.5f * lg) * 9.0f);
                            glUniform1f(m_gu.logCME, T.c > 0.001f ? std::log(T.c * 2.718281828459045f) : 0.0f);
                        }
                        glBindVertexArray(m_vao);
                        if (dmgExt.w > 0 && dmgExt.h > 0) {
                            const int cx0 = std::max((int)std::floor(quadBox.x), (int)dmgExt.x);
                            const int cy0 = std::max((int)std::floor(quadBox.y), (int)dmgExt.y);
                            const int cx1 = std::min((int)std::ceil(quadBox.x + quadBox.w), (int)(dmgExt.x + dmgExt.w));
                            const int cy1 = std::min((int)std::ceil(quadBox.y + quadBox.h), (int)(dmgExt.y + dmgExt.h));
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
                    }
                }
            }
        }
        }

    // Blend state left as set above (Hyprland re-sets its own per draw).
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    g_pHyprOpenGL->setViewport(0, 0, (int)callerSize.x, (int)callerSize.y);
}

// --- pass element ------------------------------------------------------------
// Same execution context as the layer pills (proven target space); geometry
// rides along owned in SData so straddling windows can't alias monitors.

CWindowGlassPassElement::CWindowGlassPassElement(const SData& data) : m_data(data) {}

std::vector<UP<IPassElement>> CWindowGlassPassElement::draw() {
    if (m_data.glass && m_data.glass->get())
        m_data.glass->draw(g_pHyprRenderer->m_renderData.pMonitor.lock(), m_data.draw, m_data.overRim);
    return {};
}

std::optional<CBox> CWindowGlassPassElement::boundingBox() {
    if (m_data.glass) {
        if (auto b = m_data.glass->glassBounds())
            return b;
    }
    const auto monitor = g_pHyprRenderer->m_renderData.pMonitor.lock();
    if (!monitor)
        return std::nullopt;
    const float scale = monitor->m_scale > 0.0f ? monitor->m_scale : 1.0f;
    CBox box{0.0, 0.0, (double)((int)(monitor->m_transformedSize.x / scale)), (double)((int)(monitor->m_transformedSize.y / scale))};
    return box;
}

bool CWindowGlassPassElement::needsLiveBlur() {
    // False: own blur pyramid from the current framebuffer, same as pills.
    return false;
}

bool CWindowGlassPassElement::needsPrecomputeBlur() {
    return false;
}

bool CWindowGlassPassElement::disableSimplification() {
    return false;
}

#include "Glass.hpp"
#include "Config.hpp"
#include "Shaders.hpp"

#include <GLES3/gl32.h>
#include <hyprland/src/config/shared/complex/ComplexDataTypes.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprutils/math/Misc.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <dirent.h>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <system_error>
#include <unistd.h>

using namespace Render;
using namespace Render::GL;

// Fullscreen-triangle projection: VAO positions [0,1] -> clip [-1,1].
// (Same matrix every blur/glass user in Hyprland uses for fullscreen passes.)
static constexpr std::array<float, 9> FULLSCREEN_PROJECTION = {
    2.0f, 0.0f, 0.0f,
    0.0f, 2.0f, 0.0f,
    -1.0f, -1.0f, 1.0f,
};

CGlassLayer::CGlassLayer(PHLLS surface) : m_surface(surface) {}

// --- geometry ------------------------------------------------------------
// ~/.cache/liquid-glass-hypr/liquidglass-<name>-<MON>.json, written by the
// Quickshell side (qml/GlassLayout.qml):
//   {"monitor":"DP-1","surface":{"w":..,"h":..},"pills":[{"x":..,"y":..,
//     "w":..,"h":..,"r":[tl,tr,br,bl]}, ...]}
// Persistent cache dir on purpose — never /tmp: tmpfs wipes on reboot and
// the bridge must survive (and stay debuggable) across sessions.
// Logical px relative to the surface origin; converted to framebuffer px here.

// XDG_CACHE_HOME-aware, HOME fallback. Empty only when neither is set
// (never happens under Hyprland) — callers then skip, never touch /tmp.
static std::string geoDir() {
    if (const char* xdg = std::getenv("XDG_CACHE_HOME"); xdg && *xdg)
        return std::string(xdg) + "/liquid-glass-hypr";
    if (const char* home = std::getenv("HOME"); home && *home)
        return std::string(home) + "/.cache/liquid-glass-hypr";
    return {};
}

// Once per process: ensure the dir exists, and delete legacy /tmp bridge
// files so a stale pre-migration file can never shadow the new location.
static void ensureGeoDirOnce() {
    static bool done = false;
    if (done)
        return;
    done = true;
    const std::string dir = geoDir();
    if (!dir.empty()) {
        std::error_code ec;
        std::filesystem::create_directories(dir, ec);
    }
    if (DIR* tmp = opendir("/tmp")) {
        while (dirent* ent = readdir(tmp)) {
            const std::string name = ent->d_name ? ent->d_name : "";
            if (name.size() > 18 && name.compare(0, 13, "liquidglass-") == 0
                && name.compare(name.size() - 5, 5, ".json") == 0)
                unlink(("/tmp/" + name).c_str());
        }
        closedir(tmp);
    }
}

static const char* jsSkip(const char* p, const char* end) {
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r'))
        ++p;
    return p;
}

// End of the bracketed span starting at p (p points AT the bracket).
// Tracks nesting and strings, so '[..{..}..]' and friends resolve exactly.
static const char* jsMatch(const char* p, const char* end, char open, char close) {
    int depth = 0;
    bool inStr = false;
    for (; p < end; ++p) {
        if (inStr) {
            if (*p == '\\')
                ++p;
            else if (*p == '"')
                inStr = false;
        } else if (*p == '"') {
            inStr = true;
        } else if (*p == open) {
            ++depth;
        } else if (*p == close) {
            if (--depth == 0)
                return p;
        }
    }
    return end; // unbalanced
}

static bool jsNumber(const char*& p, const char* end, double& out) {
    p = jsSkip(p, end);
    char* stop = nullptr;
    out = std::strtod(p, &stop);
    if (stop == p)
        return false;
    p = stop;
    return true;
}

static bool findKey(const char*& p, const char* end, const char* key) {
    const std::string needle = std::string("\"") + key + "\"";
    const char* at = std::search(p, end, needle.begin(), needle.end());
    if (at == end)
        return false;
    p = at + needle.size();
    p = jsSkip(p, end);
    if (p < end && *p == ':')
        ++p;
    return true;
}

// --- layer borders ----------------------------------------------------------
// Same ring.frag as windows, but inactive tint only (no active coloring) and
// dock excluded. Inactive color is read live from general:col.inactive_border
// (matugen rewrites it per wallpaper); falls back to the dark default.
static bool inactiveBorderRGB(float& r, float& g, float& b) {
    try {
        const auto v = Config::mgr()->getConfigValue("general:col.inactive_border");
        if (!v.dataptr || !*v.dataptr)
            return false;
        auto grad = *reinterpret_cast<Config::CGradientValueData* const*>(v.dataptr);
        if (!grad || grad->m_colors.empty())
            return false;
        const auto& c = grad->m_colors[0];
        r = (float)c.r;
        g = (float)c.g;
        b = (float)c.b;
        return true;
    } catch (...) { return false; }
}

static bool fileExcludedForBorders(const std::string& path) {
    const std::string pat = lg::getString("plugin:liquidglass:layer_border_exclude", "dock");
    if (pat.empty())
        return false;
    // filename only: liquidglass-<infix>-<MON>.json
    std::string name = path;
    if (auto slash = name.find_last_of('/'); slash != std::string::npos)
        name = name.substr(slash + 1);
    size_t start = 0;
    while (start <= pat.size()) {
        size_t end = pat.find(',', start);
        if (end == std::string::npos)
            end = pat.size();
        size_t a = start;
        while (a < end && (pat[a] == ' ' || pat[a] == '\t'))
            ++a;
        size_t bb = end;
        while (bb > a && (pat[bb - 1] == ' ' || pat[bb - 1] == '\t'))
            --bb;
        if (bb > a && name.find(pat.substr(a, bb - a)) != std::string::npos)
            return true;
        if (end == pat.size())
            break;
        start = end + 1;
    }
    return false;
}

bool CGlassLayer::loadGeometry(PHLMONITOR monitor, const CBox& surfBox, std::vector<SPill>& pills, bool forBorders) {
    if (!monitor)
        return false;
    const std::string mon = monitor->m_name;

    // Self-calibrating mapping: the file declares the surface size in the
    // same units as its rects. The plugin measures the real surface box and
    // derives the conversion ratio directly — no monitor scale, no Qt DPR,
    // both of which have been observed to disagree (2 vs 1.6, nested 2 vs 1).
    // A file applies when the ratio is uniform and sane; anything else is
    // another surface's file (or garbage) and is skipped.
    (void)monitor;

    // Discover publisher files: <cache>/liquidglass-<name>-<MON>.json.
    // One cheap dir scan per frame; files parsed only on change.
    ensureGeoDirOnce();
    const std::string dir = geoDir();
    if (dir.empty())
        return false;
    const std::string prefix = "liquidglass-";
    const std::string suffix = "-" + mon + ".json";
    std::vector<std::string> seen;
    if (DIR* d = opendir(dir.c_str())) {
        while (dirent* ent = readdir(d)) {
            const std::string name = ent->d_name ? ent->d_name : "";
            if (name.size() <= prefix.size() + suffix.size() || name.compare(0, prefix.size(), prefix) != 0
                || name.compare(name.size() - suffix.size(), suffix.size(), suffix) != 0)
                continue;
            const std::string infix = name.substr(prefix.size(), name.size() - prefix.size() - suffix.size());
            if (infix.empty() || infix.find('/') != std::string::npos)
                continue;
            seen.push_back(dir + "/" + name);
        }
        closedir(d);
    }
    for (auto it = m_geoFiles.begin(); it != m_geoFiles.end();) {
        if (std::find(seen.begin(), seen.end(), it->first) == seen.end())
            it = m_geoFiles.erase(it);
        else
            ++it;
    }

    pills.clear();
    for (const auto& path : seen) {
        // Dock (and friends) keep glass body but never get border rings.
        const bool excluded = forBorders && fileExcludedForBorders(path);
        std::error_code ec;
        const auto stamp = std::filesystem::last_write_time(path, ec);
        if (ec) {
            m_geoFiles.erase(path);
            continue;
        }
        SGeoFile& cached = m_geoFiles[path]; // inserts empty on first sight
        if (cached.parsed && cached.stamp == stamp) {
            if (!excluded)
                pills.insert(pills.end(), cached.pills.begin(), cached.pills.end());
            continue;
        }

        // Parse: {"monitor":..,"surface":{"w":..,"h":..},"pills":[{x,y,w,h,"r":[4]}]}.
        // Self-calibrating mapping: the surface size is declared in the same
        // units as the rects, so the conversion ratio is measured live as
        //   ratio = surfaceBox / declaredSize
        // per frame (surfaces can move/resize; QS logical units, monitor
        // scale and Qt DPR all disagree with each other, so none of them is
        // trusted — only this measured ratio). A file applies when the ratio
        // is uniform across axes and sane; anything else is another
        // surface's file (or garbage) and contributes nothing.
        std::vector<SPill> fresh;
        bool fileOk = false;
        double ratioX = 0, ratioY = 0;
        do {
            std::ifstream f(path);
            if (!f)
                break;
            const std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
            const char* p = text.data();
            const char* end = p + text.size();

            // Surface span first: every lookup below is bounded by it, so key
            // order never matters (Qt emits keys alphabetically: h before w).
            const char* q = p;
            if (!findKey(q, end, "surface"))
                break;
            q = jsSkip(q, end);
            if (q >= end || *q != '{')
                break;
            const char* sEnd = jsMatch(q, end, '{', '}');
            if (sEnd == end)
                break;
            double sw = 0, sh = 0;
            {
                const char* t = q;
                if (!findKey(t, sEnd, "w") || !jsNumber(t, sEnd, sw))
                    break;
            }
            {
                const char* t = q;
                if (!findKey(t, sEnd, "h") || !jsNumber(t, sEnd, sh))
                    break;
            }
            if (sw <= 0 || sh <= 0)
                break;
            ratioX = surfBox.w / sw;
            ratioY = surfBox.h / sh;
            // Tight 1% uniformity: legit matches are exact to fb rounding
            // (~0.01%), while a lookalike fullscreen overlay (1600x900 vs a
            // 1600x878 bar file = 2.5% off) must NOT match — it would draw
            // every pill a second time, slightly stretched, with no content
            // (observed live as textless ghost duplicates). Morphs stay exact
            // because QML rewrites the file on every surfaceW/H change.
            if (ratioX < 0.5 || ratioX > 4.0 || ratioY < 0.5 || ratioY > 4.0
                || std::abs(ratioX - ratioY) > 0.01 * (ratioX + ratioY) * 0.5)
                break; // not this surface (or garbage)

            q = p;
            if (!findKey(q, end, "pills"))
                break;
            q = jsSkip(q, end);
            if (q >= end || *q != '[')
                break;
            const char* pEnd = jsMatch(q, end, '[', ']');
            if (pEnd == end)
                break;
            ++q;
            fileOk = true;
            // NOTE: pEnd points AT the closing ']'; the loop limit is pEnd+1
            // so the bracket itself is visible. A strict <pEnd bound can never
            // see it — every well-formed file then ends fileOk=false and no
            // surface ever draws (observed live: zero draws, zero toasts).
            const char* pLim = pEnd + 1;
            while (true) {
                q = jsSkip(q, pLim);
                if (q >= pLim) {
                    fileOk = false;
                    break;
                }
                if (*q == ']') {
                    ++q;
                    break;
                }
                if (*q == ',') {
                    ++q;
                    continue;
                }
                if (*q != '{') {
                    fileOk = false;
                    break;
                }
                const char* eEnd = jsMatch(q, pLim, '{', '}');
                if (eEnd >= pLim) {
                    fileOk = false;
                    break;
                }
                SPill pill;
                double x, y, w, h;
                bool ok = false;
                double radii[4] = {0, 0, 0, 0};
                double flares[2] = {0, 0};
                double sq = -1;
                do {
                    const char* t = q;
                    if (!findKey(t, eEnd, "x") || !jsNumber(t, eEnd, x))
                        break;
                    t = q;
                    if (!findKey(t, eEnd, "y") || !jsNumber(t, eEnd, y))
                        break;
                    t = q;
                    if (!findKey(t, eEnd, "w") || !jsNumber(t, eEnd, w))
                        break;
                    t = q;
                    if (!findKey(t, eEnd, "h") || !jsNumber(t, eEnd, h))
                        break;
                    ok = true;
                    t = q;
                    if (findKey(t, eEnd, "r")) {
                        t = jsSkip(t, eEnd);
                        if (t >= eEnd || *t != '[') {
                            ok = false;
                            break;
                        }
                        const char* rEnd = jsMatch(t, eEnd, '[', ']');
                        if (rEnd == eEnd) {
                            ok = false;
                            break;
                        }
                        ++t;
                        for (int i = 0; i < 4 && ok; i++) {
                            t = jsSkip(t, rEnd);
                            ok = jsNumber(t, rEnd, radii[i]);
                            t = jsSkip(t, rEnd);
                            if (t < rEnd && *t == ',')
                                ++t;
                        }
                    }
                    // Optional notch flare shoulders [left, right], same units
                    // as r. Absent = 0 (plain rounded rect, old files stay valid).
                    t = q;
                    if (findKey(t, eEnd, "fl")) {
                        t = jsSkip(t, eEnd);
                        if (t < eEnd && *t == '[') {
                            const char* fEnd = jsMatch(t, eEnd, '[', ']');
                            if (fEnd != eEnd) {
                                ++t;
                                for (int i = 0; i < 2 && ok; i++) {
                                    t = jsSkip(t, fEnd);
                                    ok = jsNumber(t, fEnd, flares[i]);
                                    t = jsSkip(t, fEnd);
                                    if (t < fEnd && *t == ',')
                                        ++t;
                                }
                            }
                        }
                    }
                    // Optional per-pill squircle smoothing 0..1. Absent or
                    // negative = follow the global squircle_f (old files
                    // stay valid). Animation geometry that must stay
                    // circular (the pibble launch reveal) sends 0.
                    t = q;
                    if (findKey(t, eEnd, "sq")) {
                        t = jsSkip(t, eEnd);
                        double v = -1;
                        if (jsNumber(t, eEnd, v))
                            sq = v;
                    }
                } while (false);
                if (!ok || w <= 0 || h <= 0) {
                    fileOk = false;
                    break;
                }
                q = eEnd + 1;
                // Framebuffer-absolute px, converted with the measured ratio.
                pill.x = (float)(surfBox.x + x * ratioX);
                pill.y = (float)(surfBox.y + y * ratioY);
                pill.w = (float)(w * ratioX);
                pill.h = (float)(h * ratioY);
                for (int i = 0; i < 4; i++)
                    pill.r[i] = (float)(radii[i] * (ratioX + ratioY) * 0.5);
                for (int i = 0; i < 2; i++)
                    pill.fl[i] = (float)(std::max(0.0, flares[i]) * (ratioX + ratioY) * 0.5);
                pill.sq = (float)(sq < 0 ? -1 : std::max(0.0, std::min(1.0, sq)));
                fresh.push_back(pill);
            }
        } while (false);

        // Commit only on success: a torn read (QML rewrites this file every
        // morph frame, unsynchronized with the render loop) must keep
        // last-good instead of blanking the glass — and must NOT advance
        // the stamp, so the now-complete file is retried next frame.
        if (fileOk) {
            cached.stamp = stamp;
            cached.parsed = true;
            cached.pills = std::move(fresh);
        }
        if (!(forBorders && fileExcludedForBorders(path)))
            pills.insert(pills.end(), cached.pills.begin(), cached.pills.end());
    }
    return !pills.empty();
}

// --- shaders --------------------------------------------------------------

static GLint loc(GLuint program, const char* name) {
    return glGetUniformLocation(program, name);
}

void CGlassLayer::ensureShaders() {
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

    if (!m_glass->createProgram(SHADERS.at("glass.vert"), SHADERS.at("glass.frag"), true)) {
        lg::notify("liquidglass: glass.frag failed to compile — no glass will draw");
        return;
    }
    if (!m_kawDown->createProgram(SHADERS.at("glass.vert"), SHADERS.at("kawase_down.frag"), true)) {
        lg::notify("liquidglass: kawase_down.frag failed to compile — no glass will draw");
        return;
    }
    if (!m_kawUp->createProgram(SHADERS.at("glass.vert"), SHADERS.at("kawase_up.frag"), true)) {
        lg::notify("liquidglass: kawase_up.frag failed to compile — no glass will draw");
        return;
    }
    if (!m_bokeh->createProgram(SHADERS.at("glass.vert"), SHADERS.at("bokeh.frag"), true)) {
        lg::notify("liquidglass: bokeh.frag failed to compile — no glass will draw");
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
    m_gu.flare = loc(gp, "uFlare");
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

    // Own unit quad. See Glass.hpp.
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

void CGlassLayer::ensureRing() {
    if (m_ringOk)
        return;
    if (!m_ring)
        m_ring = makeShared<CShader>();
    if (!m_ring->createProgram(SHADERS.at("glass.vert"), SHADERS.at("ring.frag"), true)) {
        lg::notify("liquidglass: ring.frag failed to compile — layer borders disabled");
        return;
    }
    const GLuint rp = m_ring->program();
    m_ru.proj = loc(rp, "proj");
    m_ru.blur = loc(rp, "uBlur");
    m_ru.inner = loc(rp, "uInner");
    m_ru.quad = loc(rp, "uQuadSize");
    m_ru.thick = loc(rp, "uThick");
    m_ru.round = loc(rp, "uRound");
    m_ru.tint = loc(rp, "uTint");
    m_ru.tint2 = loc(rp, "uTint2");
    m_ru.lerp = loc(rp, "uLerp");
    m_ru.tintMix = loc(rp, "uTintMix");
    m_ru.a = loc(rp, "uA");
    m_ru.throwMax = loc(rp, "uThrow");
    m_ru.winSize = loc(rp, "uWinSize");
    m_ru.winR = loc(rp, "uWinR");
    m_ru.shape = loc(rp, "uShape");
    m_ru.lA = loc(rp, "uLA");
    m_ru.lB = loc(rp, "uLB");
    m_ru.lC = loc(rp, "uLC");
    m_ru.lD = loc(rp, "uLD");
    m_ru.lFPower = loc(rp, "uLFPower");
    m_ru.glowW = loc(rp, "uGlowW");
    m_ru.glowE0 = loc(rp, "uGlowE0");
    m_ru.glowE1 = loc(rp, "uGlowE1");
    m_ru.glowT = loc(rp, "uGlowT");
    m_ru.glowBias = loc(rp, "uGlowBias");
    m_ru.radii = loc(rp, "uRadii");
    m_ru.useRadii = loc(rp, "uUseRadii");
    m_ru.winRadii = loc(rp, "uWinRadii");
    m_ru.fadeTop = loc(rp, "uFadeTop");
    m_ru.fadeMid = loc(rp, "uFadeMid");
    m_ru.fadeBottom = loc(rp, "uFadeBottom");
    m_ru.fadeAng = loc(rp, "uFadeAngle");
    m_ru.flare = loc(rp, "uFlare");
    m_ru.push = loc(rp, "uPush");
    m_ru.squircleF = loc(rp, "uSquircleF");
    m_ru.frameEnable = loc(rp, "uFrameEnable");
    m_ru.frameScale = loc(rp, "uFrameScale");
    m_ru.seed = loc(rp, "uSeed");
    m_ru.frieze = loc(rp, "uFrieze");
    m_ru.gilt = loc(rp, "uGilt");
    m_ru.relief = loc(rp, "uRelief");
    m_ru.shCol = loc(rp, "uShadowColor");
    m_ru.shA = loc(rp, "uShadowA");
    m_ru.shOff = loc(rp, "uShadowOff");
    m_ru.shBlur = loc(rp, "uShadowBlur");
    m_ringOk = true;
}

// --- dual kawase ------------------------------------------------------------
// L0 (halfA, hw x hh) holds the blitted capture. Downs walk L0->L1->L2,
// ups accumulate back to L0, which stays the uBlur source: the capture
// contract (region at half res, same UVs) is unchanged, only the contents
// get smoother. iters>=3 runs the depth-2 cycle twice (extra smoothing).

static GLuint fbId(const SP<Render::IFramebuffer>& fb) {
    return dynamic_cast<Render::GL::CGLFramebuffer*>(fb.get())->getFBID();
}

void CGlassLayer::ensureKawase(int hw, int hh, unsigned int format) {
    // PERF: halfT (bokeh) lazy — see ensureBokeh. A (capture) always;
    // B/C (chain) via ensureChain (passes>0 only; small pills skip).
    if (!m_halfA)
        m_halfA = g_pHyprRenderer->createFB("liquidglass-half-a");
    if (!m_halfA)
        return;
    if (m_halfA->m_size.x != hw || m_halfA->m_size.y != hh)
        m_halfA->alloc(hw, hh, format);
}

void CGlassLayer::ensureChain(int hw, int hh, unsigned int format) {
    const int qw = std::max(1, hw / 2), qh = std::max(1, hh / 2);
    const int ew = std::max(1, qw / 2), eh = std::max(1, qh / 2);
    if (!m_halfB)
        m_halfB = g_pHyprRenderer->createFB("liquidglass-half-b");
    if (!m_halfC)
        m_halfC = g_pHyprRenderer->createFB("liquidglass-half-c");
    if (!m_halfB || !m_halfC)
        return;
    if (m_halfB->m_size.x != qw || m_halfB->m_size.y != qh)
        m_halfB->alloc(qw, qh, format);
    if (m_halfC->m_size.x != ew || m_halfC->m_size.y != eh)
        m_halfC->alloc(ew, eh, format);
}

void CGlassLayer::ensureBokeh(int hw, int hh, unsigned int format) {
    if (!m_halfT)
        m_halfT = g_pHyprRenderer->createFB("liquidglass-half-t");
    if (!m_halfT)
        return;
    if (m_halfT->m_size.x != hw || m_halfT->m_size.y != hh)
        m_halfT->alloc(hw, hh, format);
}

void CGlassLayer::bokehPass(float radius, float strength) {
    // L0-size scatter into the temp (same UV contract as L0).
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

void CGlassLayer::kawaseDown(const SP<Render::IFramebuffer>& src, const SP<Render::IFramebuffer>& dst, float radius) {
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

void CGlassLayer::kawaseUp(const SP<Render::IFramebuffer>& src, const SP<Render::IFramebuffer>& dst, float radius) {
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

// --- frame -----------------------------------------------------------------

void CGlassLayer::render(PHLMONITOR monitor) {
    const auto surf = m_surface.lock();
    if (!surf || !monitor)
        return;

    // Surface box, monitor-local framebuffer px.
    CBox surfBox{surf->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT),
                 surf->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT)};
    surfBox.translate(-monitor->m_position);
    surfBox.scale(monitor->m_scale).round().noNegativeSize();
    if (!std::isfinite(surfBox.x) || !std::isfinite(surfBox.y) || surfBox.w <= 0 || surfBox.h <= 0)
        return;

    std::vector<SPill> pills;
    if (!loadGeometry(monitor, surfBox, pills) || pills.empty()) {
        // Geometry gone (file deleted): repaint the last bounds once so no
        // stale glass lingers, then go quiet. glassBounds() keeps returning
        // the last union so the pass still culls this element correctly.
        if (m_boundsOk && m_boundsLog.w > 0 && m_boundsLog.h > 0) {
            g_pHyprRenderer->damageBox(CBox{monitor->m_position.x + m_boundsLog.x, monitor->m_position.y + m_boundsLog.y,
                                           m_boundsLog.w, m_boundsLog.h});
            m_boundsOk = false;
        }
        return;
    }

    // Damage on change only — never every frame. A self-damage loop would
    // keep the compositor presenting at monitor Hz forever (idle desktop =
    // full-rate presents, GPU never sleeps). Correctness without it:
    //   - backdrop changes carry their own damage; our bounds intersect it
    //     exactly where glass pixels go stale, so the pass redraws us;
    //   - morphs/resizes change the union below -> we damage old+new;
    //   - slider/theme edits bump the tune generation -> we damage;
    //   - nothing damaged anywhere -> no frame at all -> static glass is
    //     still correct on screen.
    const uint64_t tuneGen = lg::tuneGeneration();
    // Softer-than-default drop shadow: the key still reads in old units.
    const float shBlurPad = lg::getFloat("plugin:liquidglass:shadow_blur", 57.0f) * 0.25f;
    const float shOffX = lg::getFloat("plugin:liquidglass:shadow_offset_x", 0.0f);
    const float shOffY = lg::getFloat("plugin:liquidglass:shadow_offset_y", 20.0f) * 0.5f;
    {
        float x0 = pills[0].x, y0 = pills[0].y, x1 = pills[0].x + pills[0].w, y1 = pills[0].y + pills[0].h;
        for (const auto& p : pills) {
            x0 = std::min(x0, p.x);
            y0 = std::min(y0, p.y);
            x1 = std::max(x1, p.x + p.w);
            y1 = std::max(y1, p.y + p.h);
        }
        const double inv = 1.0 / (double)monitor->m_scale;
        const double PAD = (double)(shBlurPad * 2.2f + std::max(std::fabs(shOffX), std::fabs(shOffY)) + 8.0f) * inv;
        const CBox fresh{(x0 * inv) - PAD, (y0 * inv) - PAD, (x1 - x0) * inv + 2 * PAD, (y1 - y0) * inv + 2 * PAD};
        auto sameBox = [](const CBox& a, const CBox& b) {
            return std::fabs(a.x - b.x) < 1e-3 && std::fabs(a.y - b.y) < 1e-3 && std::fabs(a.w - b.w) < 1e-3
                && std::fabs(a.h - b.h) < 1e-3;
        };
        // Whole-layer gate below needs to know whether this frame went stale.
        bool boundsChanged = false;
        if (!m_boundsOk) {
            // First paint (or repaint after empty): damage the new union.
            m_boundsLog = fresh;
            m_boundsOk = true;
            m_tuneGen = tuneGen;
            boundsChanged = true;
            g_pHyprRenderer->damageBox(CBox{monitor->m_position.x + m_boundsLog.x, monitor->m_position.y + m_boundsLog.y,
                                           m_boundsLog.w, m_boundsLog.h});
        } else if (!sameBox(m_boundsLog, fresh) || m_tuneGen != tuneGen) {
            // Morph or live-tuning: damage old+new so neither ghosts.
            const double ux0 = std::min(m_boundsLog.x, fresh.x);
            const double uy0 = std::min(m_boundsLog.y, fresh.y);
            const double ux1 = std::max(m_boundsLog.x + m_boundsLog.w, fresh.x + fresh.w);
            const double uy1 = std::max(m_boundsLog.y + m_boundsLog.h, fresh.y + fresh.h);
            m_boundsLog = fresh;
            m_tuneGen = tuneGen;
            boundsChanged = true;
            g_pHyprRenderer->damageBox(
                CBox{monitor->m_position.x + ux0, monitor->m_position.y + uy0, ux1 - ux0, uy1 - uy0});
        }

        // Whole-layer early exit ("skip entirely, keep visible"): state is
        // fresh (stale bounds/tune damaged above) and our entire draw area
        // (pills + shadow margin, monitor-local fb px) misses this frame's
        // damage → every pill below would gate-skip anyway. Skips the ~30
        // tune reads, blend setup and all FBO work. The framebuffer keeps
        // last glass pixels, so glass stays on screen at zero cost. Empty
        // damage + fresh state likewise returns (nothing to present).
        {
            const CBox dmg0 = g_pHyprRenderer->m_renderData.damage.getExtents();
            if (!boundsChanged) {
                if (dmg0.w <= 0 || dmg0.h <= 0)
                    return;
                const float EgL =
                    shBlurPad * 2.2f + std::max(std::fabs(shOffX), std::fabs(shOffY)) + 8.0f;
                double ux0 = pills[0].x - EgL, uy0 = pills[0].y - EgL;
                double ux1 = pills[0].x + pills[0].w + EgL, uy1 = pills[0].y + pills[0].h + EgL;
                for (const auto& p : pills) {
                    ux0 = std::min(ux0, (double)p.x - EgL);
                    uy0 = std::min(uy0, (double)p.y - EgL);
                    ux1 = std::max(ux1, (double)(p.x + p.w) + EgL);
                    uy1 = std::max(uy1, (double)(p.y + p.h) + EgL);
                }
                if (ux1 <= dmg0.x || uy1 <= dmg0.y || ux0 >= dmg0.x + dmg0.w || uy0 >= dmg0.y + dmg0.h)
                    return;
            }
        }
    }

    ensureShaders();
    if (!m_shadersOk)
        return;

    const auto caller = g_pHyprRenderer->m_renderData.currentFB;
    if (!caller)
        return;

    const auto callerSize = caller->m_size;

    const auto source = g_pHyprRenderer->m_renderData.currentFB;
    const int srcW = (int)source->m_size.x;
    const int srcH = (int)source->m_size.y;

    // All tunables, once per render — not once per pill per frame (~20
    // file-backed lookups x N pills of pure syscall overhead before).
    struct Tune {
        float userRadius;
        int userPasses;
        int capDiv; // working-res divisor (2 half / 4 quarter)
        int tint, shCol;
        float power, shapeW, shapeH, a, b, c, d, fpower, noise;
        float squircleF;
        float glowW, glowB, glowE0, glowE1, glowT, usePill, opacity, ca, detail;
        float shOx, shOy, shBlur;
        float bokeh;
    };
    const Tune T{
        lg::getFloat("plugin:liquidglass:blur_radius", 2.0f),
        std::max(1, std::min(3, (int)std::round(lg::getFloat("plugin:liquidglass:blur_iters", 2.0f)))),
        std::max(2, std::min(4, (int)std::round(lg::getFloat("plugin:liquidglass:capture_scale", 4.0f)))),
        lg::getInt("plugin:liquidglass:tint", 0xeef5f2ff),
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
        lg::getFloat("plugin:liquidglass:squircle_f", 0.5f),
        lg::getFloat("plugin:liquidglass:glow_weight", 0.25f),
        lg::getFloat("plugin:liquidglass:glow_bias", 0.0f),
        lg::getFloat("plugin:liquidglass:glow_edge0", 0.5f),
        lg::getFloat("plugin:liquidglass:glow_edge1", -0.5f),
        lg::getFloat("plugin:liquidglass:glow_threshold", 0.5f),
        (float)lg::getInt("plugin:liquidglass:use_pill", 1),
        lg::getFloat("plugin:liquidglass:opacity", 0.82f),
        lg::getFloat("plugin:liquidglass:ca", 0.5f),
        lg::getFloat("plugin:liquidglass:detail_preserve", 1.0f),
        lg::getFloat("plugin:liquidglass:shadow_offset_x", 0.0f),
        lg::getFloat("plugin:liquidglass:shadow_offset_y", 20.0f) * 0.5f,
        shBlurPad,
        lg::getFloat("plugin:liquidglass:bokeh", 0.0f),
    };
    const double screenMinLog = std::min(monitor->m_size.x, monitor->m_size.y); // logical px

    // Layer borders: same ring.frag as windows, 1px, inactive tint only.
    // Border pills exclude dock (still gets glass body, never rings).
    std::vector<SPill> borderPills;
    const bool layerBordersOn = lg::getInt("plugin:liquidglass:layer_borders", 1) == 1;
    float ibR = 0.19f, ibG = 0.20f, ibB = 0.27f; // fallback #313244-ish
    float tmpR = 0, tmpG = 0, tmpB = 0;
    if (inactiveBorderRGB(tmpR, tmpG, tmpB)) {
        ibR = tmpR;
        ibG = tmpG;
        ibB = tmpB;
    }
    const float layerBorW = lg::getFloat("plugin:liquidglass:layer_border_width", 1.0f);
    const float fadeTop = lg::getFloat("plugin:liquidglass:border_fade_top", 1.0f);
    const float fadeMid = lg::getFloat("plugin:liquidglass:border_fade_mid", 0.2f);
    const float fadeBot = lg::getFloat("plugin:liquidglass:border_fade_bottom", 1.0f);
    const float fadeAng = lg::getFloat("plugin:liquidglass:border_fade_angle", 33.0f);
    const float borderD = lg::getFloat("plugin:liquidglass:border_d", 30.0f);
    const float borderGlowB = lg::getFloat("plugin:liquidglass:border_glow_bias", 0.5f);
    if (layerBordersOn) {
        (void)loadGeometry(monitor, surfBox, borderPills, true);
        if (!borderPills.empty())
            ensureRing();
    }

    // This frame's damage in monitor-local fb px (same space as the quads;
    // cf. upstream renderBorder intersecting damage with fb boxes directly).
    // Quads missing it entirely are skipped (blit+blur+draw); the rest draw
    // scissored to it. Outside damage nothing presents, so this is free.
    const CBox dmgExt = g_pHyprRenderer->m_renderData.damage.getExtents();

    // Straight-alpha blending for the glass quads.
    // PERF: no glGet* save/restore per draw (each glGet stalls the pipeline;
    // was 5 gets per pill per frame). Hyprland sets its own blend state per
    // draw anyway, so we just set ours and leave it.
    glEnable(GL_BLEND);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    const auto transform =
        Math::wlTransformToHyprutils(Math::invertTransform(monitor->m_transform));

    // Pills are monitor-local framebuffer px — exactly what
    // projectBoxToTarget wants (cf. upstream MONITORBOX, which passes
    // m_transformedSize straight in). Do NOT divide by scale: that was
    // shrinking every quad 1.6x toward the corner AND desyncing it from
    // the fb-px uBox/uRadii shape math (=> effectively invisible).
    for (const auto& lp : pills) {
        const int px0 = (int)std::floor(lp.x);
        const int py0 = (int)std::floor(lp.y);
        const int px1 = (int)std::ceil(lp.x + lp.w);
        const int py1 = (int)std::ceil(lp.y + lp.h);
        if (px1 <= px0 || py1 <= py0)
            continue;

        // Size-proportional blur: small pills stay sharp, large ones ramp up
        // to the user setting, absolute max at screen size. Linear in the
        // smaller dimension (the constraining one for pill glass).
        // Radius is resolution-proportional (x monitor scale): a scale-blind
        // framebuffer-px spread reads ~half as strong on a 2.4x 4K panel as
        // on the 1.6x primary for same-size windows.
        const double pillMinLog = (double)std::min(lp.w, lp.h) / (double)monitor->m_scale;
        const float sizeK = (float)std::clamp(pillMinLog / screenMinLog, 0.0, 1.0);
        const float radius = T.userRadius * sizeK;
        // Resolution-corrected: the chain spread is radius × base texel, so a
        // smaller base (capture_scale 4) would read 2x stronger. Divide back
        // to keep screen-space blur identical across scales (2 = old look).
        const float effR = radius * std::sqrt((float)T.userPasses) * 0.5f * (float)monitor->m_scale
            * (2.0f / (float)T.capDiv);
        // Skip the chain when the effective radius is sub-visible: every
        // current pill lands at effR 0.06-0.08 (wasted passes for no readable
        // blur). Large surfaces still ramp up normally. Threshold in
        // screen-space units (scales with capDiv like effR) so the skip
        // behavior is identical at any capture_scale.
        const int passes = effR < 0.1f * (2.0f / (float)T.capDiv) ? 0 : T.userPasses;
        const bool bokehOn = T.bokeh > 0.01f;

        // Damage gate on the DRAW quad (pill + shadow margin E, same extent
        // as below): fully outside this frame's damage -> skip blit, blur
        // and draw alike. The shadow completes over damaged frames; static
        // pixels keep their correct old content.
        const float Eg = T.shBlur * 2.2f + std::max(std::fabs(T.shOx), std::fabs(T.shOy)) + 8.0f;
        if (dmgExt.w > 0 && dmgExt.h > 0) {
            const double gx0 = (double)lp.x - Eg, gy0 = (double)lp.y - Eg;
            const double gx1 = (double)(lp.x + lp.w) + Eg, gy1 = (double)(lp.y + lp.h) + Eg;
            if (gx1 <= dmgExt.x || gy1 <= dmgExt.y || gx0 >= dmgExt.x + dmgExt.w || gy0 >= dmgExt.y + dmgExt.h)
                continue;
        }

        // Capture region = pill + bleed, clamped to the source.
        int rx0 = std::max(0, px0 - PAD_PX), ry0 = std::max(0, py0 - PAD_PX);
        int rx1 = std::min(srcW, px1 + PAD_PX), ry1 = std::min(srcH, py1 + PAD_PX);
        const int rw = rx1 - rx0, rh = ry1 - ry0;
        if (rw < 8 || rh < 8)
            continue;
        // Working res: capture_scale divisor (4 = quarter-res chain; the
        // output is blurred anyway, so it upscales back nearly identically).
        const int hw = std::max(1, rw / T.capDiv), hh = std::max(1, rh / T.capDiv);

        ensureKawase(hw, hh, source->m_drmFormat);
        if (passes > 0)
            ensureChain(hw, hh, source->m_drmFormat);
        if (bokehOn)
            ensureBokeh(hw, hh, source->m_drmFormat);
        if (!m_halfA || !m_halfA->getTexture()
            || (passes > 0 && (!m_halfB || !m_halfC || !m_halfB->getTexture() || !m_halfC->getTexture()))
            || (bokehOn && (!m_halfT || !m_halfT->getTexture())))
            continue;

        g_pHyprOpenGL->setCapStatus(GL_SCISSOR_TEST, false);

        // 1. Downsample blit straight into halfA (free 2x downsample).
        // PERF: no glClear (blit overwrites every pixel; clear was a full
        // half-res fullscreen fill per pill per frame for nothing).
        glBindFramebuffer(GL_FRAMEBUFFER, fbId(m_halfA));
        g_pHyprOpenGL->setViewport(0, 0, hw, hh);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbId(source));
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbId(m_halfA));
        glBlitFramebuffer(rx0, ry0, rx1, ry1, 0, 0, hw, hh, GL_COLOR_BUFFER_BIT, GL_LINEAR);

        // 2. Dual-Kawase chain in halfA -> halfB -> halfC and back.
        // iters>=3 runs the depth-2 cycle twice (extra smoothing round).
        // Skipped entirely when passes==0 (sharp capture, same as before).
        if (passes > 0) {
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
        // 2b. Bokeh scatter into the L0-size temp (independent of the chain).
        if (bokehOn)
            bokehPass(effR, T.bokeh);

        // 3. Glass quad over the pill rect. UV mapping is normalized against
        // the captured region, so half-res and full-res agree exactly.
        // The DRAWN quad is the pill expanded by the shadow extent E: a
        // pill-sized quad would clip the shadow (its SDF lives outside the
        // pill). uPad maps quad-uv back to pill-uv for all shape math; the
        // capture mapping is unaffected (capture-space, not quad-space).
        {
            const float ox = (px0 - rx0) / (float)rw, oy = (py0 - ry0) / (float)rh;
            const float sx = (px1 - px0) / (float)rw, sy = (py1 - py0) / (float)rh;

            const float E = T.shBlur * 2.2f + std::max(std::fabs(T.shOx), std::fabs(T.shOy)) + 8.0f;
            const float ex0 = lp.x - E, ey0 = lp.y - E;
            const float ew = lp.w + 2 * E, eh = lp.h + 2 * E;
            CBox quadBox{ex0, ey0, ew, eh};
            Mat3x3 proj = g_pHyprRenderer->projectBoxToTarget(quadBox, transform);
            // Upstream uploads projectBoxToTarget with GL_TRUE and no manual
            // transpose (see renderRect/renderTexture); match exactly.

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
            // Pills never use the over-rim ramp: park uSharp on the same
            // texture (valid bind) with the mix disabled.
            glActiveTexture(GL_TEXTURE1);
            uBlurFb->getTexture()->bind();
            uBlurFb->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            uBlurFb->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glActiveTexture(GL_TEXTURE0);

            auto shader = g_pHyprOpenGL->useShader(m_glass);
            glUniformMatrix3fv(m_gu.proj, 1, GL_TRUE, proj.getMatrix().data());
            glUniform4f(m_gu.pad, (lp.x - ex0) / ew, (lp.y - ey0) / eh, lp.w / ew, lp.h / eh);
            glUniform1i(m_gu.blur, 0);
            glUniform1i(m_gu.sharp, 1);
            glUniform1f(m_gu.rimBlur, 0.0f); // pills: regular user-blur path
            glUniform2f(m_gu.capOrigin, ox, oy);
            glUniform2f(m_gu.capScale, sx, sy);
            glUniform3f(m_gu.baseColor, ((T.tint >> 24) & 0xFF) / 255.f, ((T.tint >> 16) & 0xFF) / 255.f,
                        ((T.tint >> 8) & 0xFF) / 255.f);
            glUniform1f(m_gu.power, T.power);
            glUniform2f(m_gu.shape, T.shapeW, T.shapeH);
            glUniform1f(m_gu.a, T.a);
            glUniform1f(m_gu.b, T.b);
            glUniform1f(m_gu.c, T.c);
            glUniform1f(m_gu.d, T.d);
            glUniform1f(m_gu.fpower, T.fpower);
            glUniform1f(m_gu.noise, T.noise);
            glUniform1f(m_gu.glowW, T.glowW);
            glUniform1f(m_gu.glowB, T.glowB);
            glUniform1f(m_gu.glowE0, T.glowE0);
            glUniform1f(m_gu.glowE1, T.glowE1);
            glUniform1f(m_gu.glowT, T.glowT);
            glUniform1f(m_gu.usePill, T.usePill);
            glUniform4f(m_gu.radii, lp.r[0], lp.r[1], lp.r[2], lp.r[3]);
            glUniform2f(m_gu.flare, lp.fl[0], lp.fl[1]);
            glUniform1f(m_gu.squircleF, lp.sq >= 0.0f ? lp.sq : T.squircleF);
            // Fractional true rect: uPad already centers the shape on the
            // fractional lp rect, so the shape size must be fractional too.
            // Integer floor/ceil here put the glass edge up to 0.5px off the
            // ring's fractional inner box — a sliver most visible along the
            // curved notch fillets (the ring flare centers coincide only
            // when both passes agree on the true rect).
            glUniform2f(m_gu.box, (float)lp.w, (float)lp.h);
            glUniform1f(m_gu.opacity, T.opacity);
            glUniform3f(m_gu.shadowColor, ((T.shCol >> 24) & 0xFF) / 255.f, ((T.shCol >> 16) & 0xFF) / 255.f,
                        ((T.shCol >> 8) & 0xFF) / 255.f);
            glUniform1f(m_gu.shadowA, ((T.shCol & 0xFF) / 255.f));
            glUniform2f(m_gu.shadowOff, T.shOx, T.shOy);
            glUniform1f(m_gu.shadowBlur, T.shBlur);
            glUniform1f(m_gu.ca, T.ca);
            glUniform1f(m_gu.detail, T.detail);
            glUniform1f(m_gu.lensBand, 0.0f); // pills: full-field lens
            glUniform1f(m_gu.overRim, 0.0f); // pills: never overdrawn
            // PERF: precompute per-fragment log()s on CPU (same value for all
            // fragments in this draw; GPU would redo log per fragment).
            {
                const float mn = std::min((float)lp.w, (float)lp.h);
                const float lg = std::log(1.0f + mn / 30.0f);
                glUniform1f(m_gu.bevW, std::max((7.0f + 3.5f * lg) * 1.5f, 4.0f));
                glUniform1f(m_gu.edgePx, (7.0f + 3.5f * lg) * 9.0f);
                glUniform1f(m_gu.logCME, T.c > 0.001f ? std::log(T.c * 2.718281828459045f) : 0.0f);
            }
            glBindVertexArray(m_vao);
            // Scissor to this frame's damage (same subdivision upstream uses
            // for borders): full quads shade ~1M px on clock-tick frames
            // where only ~10k px present. Skipped per-pill above when empty.
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

        // 4. Layer border ring: same material as window borders, 1px,
        // inactive tint only, vertical fade shared with windows. Reuses the
        // same halfA/halfT capture above — no second blit.
        if (layerBordersOn && m_ringOk && !borderPills.empty()) {
            bool want = false;
            for (const auto& bp : borderPills) {
                if (std::fabs(bp.x - lp.x) < 1e-3 && std::fabs(bp.y - lp.y) < 1e-3 && std::fabs(bp.w - lp.w) < 1e-3
                    && std::fabs(bp.h - lp.h) < 1e-3) {
                    want = true;
                    break;
                }
            }
            if (want) {
                int scaledBorder = (int)std::round(layerBorW * (float)monitor->m_scale);
                if (scaledBorder < 1)
                    scaledBorder = 1;
                // Fractional pill geometry: the glass body aligns to the true
                // lp rect via uPad, so the ring must too — integer floor/ceil
                // snaps the ring up to 1px off the widget frame (most visible
                // along the notch fillets). Capture quad stays pixel-grid.
                const float pw = lp.w, ph = lp.h;
                const float ix = lp.x - (float)rx0, iy = lp.y - (float)ry0;
                CBox ringBox{(double)rx0, (double)ry0, (double)rw, (double)rh};
                Mat3x3 rproj = g_pHyprRenderer->projectBoxToTarget(ringBox, transform);
                glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
                g_pHyprOpenGL->setViewport(0, 0, (int)callerSize.x, (int)callerSize.y);
                glActiveTexture(GL_TEXTURE0);
                const bool useRBokeh = bokehOn && m_halfT && m_halfT->getTexture();
                const auto& rBlurFb = useRBokeh ? m_halfT : m_halfA;
                rBlurFb->getTexture()->bind();
                rBlurFb->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                rBlurFb->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                auto rshader = g_pHyprOpenGL->useShader(m_ring);
                glUniformMatrix3fv(m_ru.proj, 1, GL_TRUE, rproj.getMatrix().data());
                glUniform1i(m_ru.blur, 0);
                glUniform4f(m_ru.inner, ix, iy, pw, ph);
                glUniform2f(m_ru.quad, (float)rw, (float)rh);
                glUniform1f(m_ru.thick, (float)scaledBorder);
                glUniform1f(m_ru.round, lp.r[0] + (float)scaledBorder);
                glUniform3f(m_ru.tint, ibR, ibG, ibB);
                glUniform3f(m_ru.tint2, ibR, ibG, ibB);
                glUniform1f(m_ru.lerp, 0.0f);
                glUniform1f(m_ru.tintMix, T.opacity);
                glUniform1f(m_ru.a, 1.0f);
                glUniform2f(m_ru.winSize, pw, ph);
                glUniform1f(m_ru.winR, (lp.r[0] + lp.r[1] + lp.r[2] + lp.r[3]) * 0.25f);
                glUniform2f(m_ru.shape, T.shapeW, T.shapeH);
                glUniform1f(m_ru.lA, T.a);
                glUniform1f(m_ru.lB, T.b);
                glUniform1f(m_ru.lC, T.c);
                glUniform1f(m_ru.lD, borderD);
                glUniform1f(m_ru.lFPower, T.fpower);
                glUniform1f(m_ru.glowW, T.glowW);
                glUniform1f(m_ru.glowE0, T.glowE0);
                glUniform1f(m_ru.glowE1, T.glowE1);
                glUniform1f(m_ru.glowT, T.glowT);
                glUniform1f(m_ru.glowBias, borderGlowB);
                glUniform1f(m_ru.throwMax, std::min(24.0f, (float)scaledBorder * 1.5f));
                glUniform1f(m_ru.useRadii, 1.0f);
                glUniform4f(m_ru.radii, lp.r[0] + (float)scaledBorder, lp.r[1] + (float)scaledBorder,
                            lp.r[2] + (float)scaledBorder, lp.r[3] + (float)scaledBorder);
                glUniform4f(m_ru.winRadii, lp.r[0], lp.r[1], lp.r[2], lp.r[3]);
                glUniform2f(m_ru.flare, lp.fl[0], lp.fl[1]);
                // Same smoothing as the glass body: the ring silhouette must
                // sit exactly on the glass edge, or a backdrop hairline
                // opens between them (most visible along notch fillets).
                glUniform1f(m_ru.squircleF, T.squircleF);
                // Push 0: the ring starts exactly on the glass edge — with
                // only backdrop underneath, the window-style 0.5 push reads
                // as a 1px gap floating off the widget frame.
                glUniform1f(m_ru.push, 0.0f);
                glUniform1f(m_ru.fadeTop, fadeTop);
                glUniform1f(m_ru.fadeMid, fadeMid);
                glUniform1f(m_ru.fadeBottom, fadeBot);
                glUniform1f(m_ru.fadeAng, fadeAng);
                // Frame relief shares the window keys; thin layer bands fall
                // under the shader's thickness LOD, fixed seed keeps pills
                // coherent instead of per-pill varied.
                glUniform1f(m_ru.frameEnable, (float)lg::getInt("plugin:liquidglass:frame_enable", 1));
                glUniform1f(m_ru.frameScale, lg::getFloat("plugin:liquidglass:frame_scale", 1.0f));
                glUniform1f(m_ru.seed, 0.37f);
                glUniform1f(m_ru.frieze, lg::getFloat("plugin:liquidglass:frame_frieze", -1.0f));
                glUniform1f(m_ru.gilt, lg::getFloat("plugin:liquidglass:frame_gilt", 1.0f));
                glUniform1f(m_ru.relief, lg::getFloat("plugin:liquidglass:frame_relief", 1.0f));
                // No ring shadow for layers: the glass pass above already
                // shadows each pill; a second one would double-darken.
                glUniform3f(m_ru.shCol, 0.0f, 0.0f, 0.0f);
                glUniform1f(m_ru.shA, 0.0f);
                glUniform2f(m_ru.shOff, 0.0f, 0.0f);
                glUniform1f(m_ru.shBlur, 1.0f);
                glBindVertexArray(m_vao);
                if (dmgExt.w > 0 && dmgExt.h > 0) {
                    const int cx0 = std::max((int)std::floor(ringBox.x), (int)dmgExt.x);
                    const int cy0 = std::max((int)std::floor(ringBox.y), (int)dmgExt.y);
                    const int cx1 = std::min((int)std::ceil(ringBox.x + ringBox.w), (int)(dmgExt.x + dmgExt.w));
                    const int cy1 = std::min((int)std::ceil(ringBox.y + ringBox.h), (int)(dmgExt.y + dmgExt.h));
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

    // Blend state left as set above (Hyprland re-sets its own per draw).
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    g_pHyprOpenGL->setViewport(0, 0, (int)callerSize.x, (int)callerSize.y);
}

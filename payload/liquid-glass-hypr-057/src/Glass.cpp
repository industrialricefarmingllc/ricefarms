#include "Glass.hpp"
#include "Config.hpp"
#include "DamageRect.hpp"
#include "Shaders.hpp"

#include <GLES3/gl32.h>
#include <hyprland/src/config/shared/complex/ComplexDataTypes.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprutils/math/Misc.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
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
static const std::string& geoDir() {
    static const std::string dir = [] {
        if (const char* xdg = std::getenv("XDG_CACHE_HOME"); xdg && *xdg)
            return std::string(xdg) + "/liquid-glass-hypr";
        if (const char* home = std::getenv("HOME"); home && *home)
            return std::string(home) + "/.cache/liquid-glass-hypr";
        return std::string();
    }();
    return dir;
}

// Once per process: ensure the dir exists, and delete legacy /tmp bridge
// files so a stale pre-migration file can never shadow the new location.
static void ensureGeoDirOnce() {
    static bool done = false;
    if (done)
        return;
    done = true;
    const auto& dir = geoDir();
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

// Directory scan cache: every glassed layer used to opendir()+stat every
// publisher file on every render. With bar + dock + OSD + launcher +
// widgets that is N_layers * N_files syscalls per frame. The bridge only
// writes at most every 16ms (GlassLayout coalesces), so a shared 8ms scan
// is fresh enough for every consumer while collapsing those syscalls to
// one scan per monitor per 8ms.
struct SGeoScanEntry {
    std::string path;
    std::filesystem::file_time_type stamp{};
};
struct SGeoScanCache {
    std::chrono::steady_clock::time_point at{};
    std::vector<SGeoScanEntry> entries;
    uint64_t generation = 0;
    bool valid = false;
};
static const SGeoScanCache& geoScan(const std::string& dir, const std::string& mon) {
    static std::map<std::string, std::map<std::string, SGeoScanCache>> cache;
    static uint64_t genCounter = 0;
    auto& c = cache[dir][mon];
    const auto now = std::chrono::steady_clock::now();
    if (c.valid && now - c.at < std::chrono::milliseconds(8))
        return c;
    std::vector<SGeoScanEntry> fresh;
    const std::string prefix = "liquidglass-";
    const std::string suffix = "-" + mon + ".json";
    if (DIR* d = opendir(dir.c_str())) {
        while (dirent* ent = readdir(d)) {
            const std::string name = ent->d_name ? ent->d_name : "";
            if (name.size() <= prefix.size() + suffix.size() || name.compare(0, prefix.size(), prefix) != 0
                || name.compare(name.size() - suffix.size(), suffix.size(), suffix) != 0)
                continue;
            const std::string infix = name.substr(prefix.size(), name.size() - prefix.size() - suffix.size());
            if (infix.empty() || infix.find('/') != std::string::npos)
                continue;
            const std::string path = dir + "/" + name;
            std::error_code ec;
            const auto stamp = std::filesystem::last_write_time(path, ec);
            if (!ec)
                fresh.push_back({path, stamp});
        }
        closedir(d);
    }
    std::sort(fresh.begin(), fresh.end(), [](const SGeoScanEntry& a, const SGeoScanEntry& b) {
        return a.path < b.path;
    });
    bool changed = fresh.size() != c.entries.size();
    if (!changed) {
        for (size_t i = 0; i < fresh.size(); ++i) {
            if (fresh[i].path != c.entries[i].path || fresh[i].stamp != c.entries[i].stamp) {
                changed = true;
                break;
            }
        }
    }
    if (changed)
        c.generation = ++genCounter;
    c.entries = std::move(fresh);
    c.at = now;
    c.valid = true;
    return c;
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

// JSON string value at p (p points just after the key's ':'). Handles the
// escapes Qt can emit for namespaces; stops at the closing quote.
static bool jsString(const char*& p, const char* end, std::string& out) {
    p = jsSkip(p, end);
    if (p >= end || *p != '"')
        return false;
    ++p;
    out.clear();
    while (p < end && *p != '"') {
        if (*p == '\\' && p + 1 < end) {
            ++p;
            switch (*p) {
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                default: out += *p; break;
            }
        } else
            out += *p;
        ++p;
    }
    if (p >= end)
        return false;
    ++p; // closing quote
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

bool CGlassLayer::loadGeometry(PHLMONITOR monitor, const CBox& surfBox, const std::string& ns, std::vector<SPill>& pills,
                               bool forBorders) {
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
    // One shared scan per monitor per 8ms; files parsed only on change.
    ensureGeoDirOnce();
    const auto& dir = geoDir();
    if (dir.empty())
        return false;
    const auto& scan = geoScan(dir, mon);
    for (auto it = m_geoFiles.begin(); it != m_geoFiles.end();) {
        bool found = false;
        for (const auto& e : scan.entries) {
            if (e.path == it->first) {
                found = true;
                break;
            }
        }
        if (!found)
            it = m_geoFiles.erase(it);
        else
            ++it;
    }

    pills.clear();
    if (!forBorders)
        m_mask = {};
    for (const auto& entry : scan.entries) {
        const auto& path = entry.path;
        const auto stamp = entry.stamp;
        // Dock (and friends) keep glass body but never get border rings.
        const bool excluded = forBorders && fileExcludedForBorders(path);
        SGeoFile& cached = m_geoFiles[path]; // inserts empty on first sight
        if (cached.parsed && cached.stamp == stamp) {
            if (!cached.foreign && !excluded) {
                if (cached.full && !forBorders && !cached.pills.empty()) {
                    // Full-surface descriptor: re-derive the box from the
                    // surface as it is THIS frame. The cached pill only
                    // carries radius/squircle, which change with the theme
                    // (and are republished when they do); the size/position
                    // must never lag the live surface, or a resize reveals a
                    // frame of glass at the previous dimensions.
                    SPill fp = cached.pills.front();
                    fp.x = (float)surfBox.x;
                    fp.y = (float)surfBox.y;
                    fp.w = (float)surfBox.w;
                    fp.h = (float)surfBox.h;
                    pills.push_back(fp);
                } else {
                    pills.insert(pills.end(), cached.pills.begin(), cached.pills.end());
                }
                if (!forBorders && cached.hasMask) {
                    m_mask.on = true;
                    m_mask.cx = cached.maskX;
                    m_mask.cy = cached.maskY;
                    m_mask.r  = cached.maskR;
                }
            }
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
        bool foreign = false;
        bool nsMatched = false;
        bool fullSurface = false;
        double ratioX = 0, ratioY = 0;
        bool maskFound = false;
        double maskX = 0, maskY = 0, maskR = 0;
        do {
            std::ifstream f(path);
            if (!f)
                break;
            const std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
            const char* p = text.data();
            const char* end = p + text.size();

            // Optional publisher identity: match this surface's layer
            // namespace exactly when the file names one. Prevents a surface
            // whose size is within the ratio tolerance (bar 896 vs an
            // always-mapped 900px launcher) from receiving another
            // publisher's pills — which drew the bar glass at the screen
            // edge, at the launcher's origin, instead of at the bar's top
            // margin. Old files omit "ns" and keep the size-only fallback.
            {
                const char* t = p;
                std::string declaredNs;
                if (findKey(t, end, "ns") && jsString(t, end, declaredNs) && !declaredNs.empty()) {
                    if (declaredNs != ns) {
                        foreign = true;
                        break;
                    }
                    nsMatched = true;
                }
            }

            // Full-surface descriptor: shape = the live committed layer
            // surface box, with radius/squircle from the first pill. No
            // per-frame size/position geometry, so resizes cannot desync.
            {
                const char* t = p;
                if (findKey(t, end, "full")) {
                    t = jsSkip(t, end);
                    if (t + 4 <= end && std::strncmp(t, "true", 4) == 0)
                        fullSurface = true;
                }
            }

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
            // Surface identity, not just namespace: the bar, dock and OSD all
            // publish under the layer namespace "quickshell", so matching the
            // namespace alone made every one of those surfaces adopt the bar's
            // pills and paint them at its own origin (duplicate backgrounds
            // all over the screen). The file names the publisher surface's
            // logical size; only hand its pills to a surface of that size.
            // Measured against the live box rather than used as the coordinate
            // ratio, so the commit race that forced `monitor->m_scale` cannot
            // reintroduce flicker. A `full` descriptor intentionally derives
            // its shape from the live box and skips this check.
            if (!fullSurface) {
                const double liveW = surfBox.w / monitor->m_scale;
                const double liveH = surfBox.h / monitor->m_scale;
                if (std::fabs(liveW - sw) > 2.0 || std::fabs(liveH - sh) > 2.0) {
                    foreign = true;
                    break;
                }
            }
            // QML geometry is in the compositor's logical pixels. The only
            // correct logical -> framebuffer factor is the monitor scale.
            // Deriving it from the layer surface size was the race: that size
            // is committed a frame after QML lays the element out, so the
            // ratio changed per frame and glass appeared/disappeared.
            ratioX = ratioY = monitor->m_scale;

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
                double uni[17] = {0};
                bool hasUnion = false;
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
                    // Optional liquid union: [ax,ay,aw,ah, ar0..ar3,
                    // bx,by,bw,bh, br0..br3, neck]. The outer x/y/w/h is the
                    // union bbox. Absent = normal one-shape pill.
                    t = q;
                    if (findKey(t, eEnd, "u")) {
                        t = jsSkip(t, eEnd);
                        if (t >= eEnd || *t != '[') {
                            ok = false;
                            break;
                        }
                        const char* uEnd = jsMatch(t, eEnd, '[', ']');
                        if (uEnd == eEnd) {
                            ok = false;
                            break;
                        }
                        ++t;
                        for (int i = 0; i < 17 && ok; i++) {
                            t = jsSkip(t, uEnd);
                            ok = jsNumber(t, uEnd, uni[i]);
                            t = jsSkip(t, uEnd);
                            if (i < 16) {
                                if (t >= uEnd || *t != ',') {
                                    ok = false;
                                    break;
                                }
                                ++t;
                            }
                        }
                        if (ok)
                            hasUnion = true;
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
                if (hasUnion) {
                    const double avg = (ratioX + ratioY) * 0.5;
                    pill.unionOn = true;
                    const double* src[2] = {uni, uni + 8};
                    float* dstRect[2] = {pill.ua, pill.ub};
                    float* dstRad[2] = {pill.uar, pill.ubr};
                    for (int s = 0; s < 2; s++) {
                        dstRect[s][0] = (float)(src[s][0] * ratioX);
                        dstRect[s][1] = (float)(src[s][1] * ratioY);
                        dstRect[s][2] = (float)(src[s][2] * ratioX);
                        dstRect[s][3] = (float)(src[s][3] * ratioY);
                        for (int i = 0; i < 4; i++)
                            dstRad[s][i] = (float)(src[s][4 + i] * avg);
                    }
                    pill.uk = (float)(std::max(0.0, uni[16]) * avg);
                }
                fresh.push_back(pill);
            }
        // Optional circular clip: {"mask":{"x":..,"y":..,"r":..}} in the same
        // surface-local logical px as the pills. Only the body pass uses it.
        if (!forBorders && fileOk) {
            const char* t = p;
            if (findKey(t, end, "mask")) {
                t = jsSkip(t, end);
                if (t < end && *t == '{') {
                    const char* mEnd = jsMatch(t, end, '{', '}');
                    if (mEnd != end) {
                        const char* k = t;
                        if (findKey(k, mEnd, "x") && jsNumber(k, mEnd, maskX)) {
                            k = t;
                            if (findKey(k, mEnd, "y") && jsNumber(k, mEnd, maskY)) {
                                k = t;
                                // r == 0 is a legitimate end-of-close frame
                                // (clip everything), not "no mask": the
                                // publisher signals absence with an empty
                                // object, so treating 0 as missing made the
                                // last close frame repaint the whole panel
                                // unmasked for a frame.
                                if (findKey(k, mEnd, "r") && jsNumber(k, mEnd, maskR) && maskR >= 0.0) {
                                    const double avg = (ratioX + ratioY) * 0.5;
                                    maskFound = true;
                                    maskX *= ratioX;
                                    maskY *= ratioY;
                                    maskR *= avg;
                                }
                            }
                        }
                    }
                }
            }
        }

        } while (false);

        // Full-surface glass: the layer surface box is the source of truth
        // (exactly what is committed and visible). Take only the stable
        // corner radius / squircle from the publisher's single pill.
        if (!forBorders && fullSurface && fileOk && !fresh.empty()) {
            SPill fp = fresh.front();
            fp.x = (float)surfBox.x;
            fp.y = (float)surfBox.y;
            fp.w = (float)surfBox.w;
            fp.h = (float)surfBox.h;
            fp.unionOn = false;
            fp.fl[0] = fp.fl[1] = 0;
            fresh.assign(1, fp);
        }

        // Commit only on success: a torn read (QML rewrites this file every
        // morph frame, unsynchronized with the render loop) must keep
        // last-good instead of blanking the glass — and must NOT advance
        // the stamp, so the now-complete file is retried next frame.
        if (fileOk) {
            cached.stamp = stamp;
            cached.parsed = true;
            cached.foreign = false;
            cached.full = fullSurface && !forBorders;
            cached.ratioX = ratioX;
            cached.ratioY = ratioY;
            cached.hasMask = maskFound;
            cached.maskX = maskX;
            cached.maskY = maskY;
            cached.maskR = maskR;
            cached.pills = std::move(fresh);
            if (!forBorders && maskFound) {
                m_mask.on = true;
                m_mask.cx = maskX;
                m_mask.cy = maskY;
                m_mask.r  = maskR;
            }
        } else if (foreign) {
            // Definitive "not this surface" (namespace mismatch), unlike a
            // torn read: advance the stamp so it isn't re-parsed every frame
            // and clear any pills cached before the file carried "ns".
            cached.stamp = stamp;
            cached.parsed = true;
            cached.foreign = true;
            cached.full = false;
            cached.pills.clear();
        }
        if (!cached.foreign && !(forBorders && fileExcludedForBorders(path)))
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
    m_gu.texel = loc(gp, "uTexel");
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
    m_gu.unionOn = loc(gp, "uUnionOn");
    m_gu.unionA = loc(gp, "uUnionA");
    m_gu.unionAR = loc(gp, "uUnionAR");
    m_gu.unionB = loc(gp, "uUnionB");
    m_gu.unionBR = loc(gp, "uUnionBR");
    m_gu.unionK = loc(gp, "uUnionK");
    m_gu.maskOn = loc(gp, "uMaskOn");
    m_gu.maskCenter = loc(gp, "uMaskCenter");
    m_gu.maskRadius = loc(gp, "uMaskRadius");
    m_gu.rimLight = loc(gp, "uRimLight");
    m_gu.rimStrength = loc(gp, "uRimStrength");
    m_gu.rimWidth = loc(gp, "uRimWidth");
    m_gu.rimAngle = loc(gp, "uRimAngle");
    m_gu.rimSplay = loc(gp, "uRimSplay");
    m_gu.rimShade = loc(gp, "uRimShade");

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
    m_ru.logCME = loc(rp, "uLogCME");
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
    m_ru.rimLight = loc(rp, "uRimLight");
    m_ru.rimStrength = loc(rp, "uRimStrength");
    m_ru.rimWidth = loc(rp, "uRimWidth");
    m_ru.rimAngle = loc(rp, "uRimAngle");
    m_ru.rimSplay = loc(rp, "uRimSplay");
    m_ru.rimShade = loc(rp, "uRimShade");
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
    g_pHyprRenderer->setViewport(0, 0, dw, dh);
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
    g_pHyprRenderer->setViewport(0, 0, dw, dh);
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
    g_pHyprRenderer->setViewport(0, 0, dw, dh);
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

void CGlassLayer::damageRim() {
    if (!m_boundsOk || m_boundsLog.w <= 0.0 || m_boundsLog.h <= 0.0)
        return;
    const float pad = 12.0f;
    const float x = (float)m_lastMonPos.x + (float)m_boundsLog.x;
    const float y = (float)m_lastMonPos.y + (float)m_boundsLog.y;
    const float w = (float)m_boundsLog.w;
    const float h = (float)m_boundsLog.h;
    // The rim line is INSIDE the glass silhouette; damage inside bands (a
    // little overlap into the interior) or the glass pass never intersects
    // the pointer move. The capture-coverage guard will widen this to the
    // full capture when needed, which is fine.
    g_pHyprRenderer->damageBox(CBox{x, y, w, pad});
    g_pHyprRenderer->damageBox(CBox{x, y + h - pad, w, pad});
    g_pHyprRenderer->damageBox(CBox{x, y, pad, h});
    g_pHyprRenderer->damageBox(CBox{x + w - pad, y, pad, h});
}

// --- frame -----------------------------------------------------------------

void CGlassLayer::render(Render::CRenderContext& ctx, PHLMONITOR monitor) {
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
    m_lastMonPos = monitor->m_position;

    const uint64_t tuneGen = lg::tuneGeneration();
    const auto& geoDirStr = geoDir();
    const uint64_t geoGen = geoDirStr.empty() ? 0 : geoScan(geoDirStr, monitor->m_name).generation;
    const bool surfSame = m_haveSurfBox && std::fabs(m_lastSurfBox.x - surfBox.x) < 1e-3 &&
        std::fabs(m_lastSurfBox.y - surfBox.y) < 1e-3 && std::fabs(m_lastSurfBox.w - surfBox.w) < 1e-3 &&
        std::fabs(m_lastSurfBox.h - surfBox.h) < 1e-3;
    // Fast path: geometry, surface box and tune are unchanged, and this
    // frame's damage misses the last glass union. loadGeometry() would
    // rebuild identical pills and then take the same early exit below.
    if (m_boundsOk && m_geoGen == geoGen && surfSame && m_tuneGen == tuneGen) {
        const CBox dmgEarly = ctx.m_data.damage.getExtents();
        if (dmgEarly.w <= 0 || dmgEarly.h <= 0)
            return;
        const double inv = 1.0 / (double)monitor->m_scale;
        const CBox dmgLog{dmgEarly.x * inv, dmgEarly.y * inv, dmgEarly.w * inv, dmgEarly.h * inv};
        if (m_boundsLog.x + m_boundsLog.w <= dmgLog.x || m_boundsLog.y + m_boundsLog.h <= dmgLog.y ||
            m_boundsLog.x >= dmgLog.x + dmgLog.w || m_boundsLog.y >= dmgLog.y + dmgLog.h)
            return;
    }

    std::vector<SPill> pills;
    const bool havePills = loadGeometry(monitor, surfBox, surf->m_namespace, pills) && !pills.empty();
    m_geoGen = geoGen;
    m_lastSurfBox = surfBox;
    m_haveSurfBox = true;
    if (!havePills) {
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
            const CBox dmg0 = ctx.m_data.damage.getExtents();
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

    const auto caller = ctx.m_data.currentFB;
    if (!caller)
        return;

    const auto callerSize = caller->m_size;

    const auto source = ctx.m_data.currentFB;
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
        std::max(1, std::min(4, (int)std::round(lg::getFloat("plugin:liquidglass:capture_scale", 4.0f)))),
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
        lg::getFloat("plugin:liquidglass:opacity", 0.23f),
        lg::getFloat("plugin:liquidglass:ca", 0.5f),
        lg::getFloat("plugin:liquidglass:detail_preserve", 1.0f),
        lg::getFloat("plugin:liquidglass:shadow_offset_x", 0.0f),
        lg::getFloat("plugin:liquidglass:shadow_offset_y", 20.0f) * 0.5f,
        shBlurPad,
        lg::getFloat("plugin:liquidglass:bokeh", 0.0f),
    };

    // Layer borders: same ring.frag as windows, 1px, inactive tint only.
    // Border pills exclude dock (still gets glass body, never rings).
    std::vector<SPill> borderPills;
    const bool layerBordersOn = lg::getInt("plugin:liquidglass:layer_borders", 1) == 1;
    float ibR = 0.19f, ibG = 0.20f, ibB = 0.27f; // fallback #313244-ish
    float layerBorW = 1.0f;
    float fadeTop = 1.0f, fadeMid = 0.2f, fadeBot = 1.0f, fadeAng = 33.0f;
    float borderD = 30.0f, borderGlowB = 0.5f;
    if (layerBordersOn) {
        float tmpR = 0, tmpG = 0, tmpB = 0;
        if (inactiveBorderRGB(tmpR, tmpG, tmpB)) {
            ibR = tmpR;
            ibG = tmpG;
            ibB = tmpB;
        }
        layerBorW = lg::getFloat("plugin:liquidglass:layer_border_width", 1.0f);
        fadeTop = lg::getFloat("plugin:liquidglass:border_fade_top", 1.0f);
        fadeMid = lg::getFloat("plugin:liquidglass:border_fade_mid", 0.2f);
        fadeBot = lg::getFloat("plugin:liquidglass:border_fade_bottom", 1.0f);
        fadeAng = lg::getFloat("plugin:liquidglass:border_fade_angle", 33.0f);
        borderD = lg::getFloat("plugin:liquidglass:border_d", 30.0f);
        borderGlowB = lg::getFloat("plugin:liquidglass:border_glow_bias", 0.5f);
        (void)loadGeometry(monitor, surfBox, surf->m_namespace, borderPills, true);
        if (!borderPills.empty())
            ensureRing();
    }

    // This frame's damage in monitor-local fb px (same space as the quads;
    // cf. upstream renderBorder intersecting damage with fb boxes directly).
    // Quads missing it entirely are skipped (blit+blur+draw); the rest draw
    // scissored to it. Outside damage nothing presents, so this is free.
    const CBox dmgExt = ctx.m_data.damage.getExtents();

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
    for (size_t pillIdx = 0; pillIdx < pills.size(); ++pillIdx) {
        const auto& lp = pills[pillIdx];
        if (m_rimFollow.size() <= pillIdx)
            m_rimFollow.resize(pillIdx + 1);
        const int px0 = (int)std::floor(lp.x);
        const int py0 = (int)std::floor(lp.y);
        const int px1 = (int)std::ceil(lp.x + lp.w);
        const int py1 = (int)std::ceil(lp.y + lp.h);
        if (px1 <= px0 || py1 <= py0)
            continue;

        // Blur radius is the user setting, full stop: a small pill gets the
        // same spread as a large panel. (It used to scale with the smaller
        // surface dimension, which kept tiny widgets sharp but made the
        // control read differently on every surface.)
        // Radius is still resolution-proportional (x monitor scale): a
        // scale-blind framebuffer-px spread reads ~half as strong on a 2.4x
        // 4K panel as on the 1.6x primary for same-size windows.
        const float radius = T.userRadius;
        // Resolution-corrected: the chain spread is radius × base texel, so a
        // smaller base (capture_scale 4) would read 2x stronger. Divide back
        // to keep screen-space blur identical across scales (2 = old look).
        const float effR = radius * std::sqrt((float)T.userPasses) * 0.5f * (float)monitor->m_scale
            * (2.0f / (float)T.capDiv);
        // Skip the chain when the effective radius is sub-visible (e.g. a
        // zero user radius). Threshold in screen-space units (scales with
        // capDiv like effR) so the skip behavior is identical at any
        // capture_scale.
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

        // Never sample a partially-repainted PILL. The pill is where this
        // surface's own content (text, icons, the launcher's mask) lives; if
        // that area was not repainted this frame, the capture still contains
        // last frame's content/composited glass and would ghost it.
        //
        // The 32px capture bleed is deliberately NOT required. It lies
        // outside the pill, so the glass does not cover it: those pixels hold
        // the backdrop (or a neighbour), which is valid even when undamaged.
        // Requiring it too made every small layer surface skip every other
        // frame — the client only damages its own surface, never the bleed —
        // so the pass requested the bleed, drew next frame, then failed again
        // as soon as any content changed. That draw/skip alternation is the
        // hover/iris flicker: the mask and moving pills advanced one frame,
        // froze one frame. Requiring the pill alone keeps the ghost guard
        // where it matters and lets the shape update every frame.
        // The notch tabs bleed 2px past the surface edge (published x:-2 /
        // x+w past the screen edge so no wallpaper hairline shows). Damage can
        // never cover pixels outside the surface, so testing the raw pill rect
        // made the two edge tabs fail the guard forever: they were skipped,
        // damaged themselves, skipped again — no glass on the left/right notch
        // while the centre clock (wholly inside) kept its glass. Test only the
        // part of the pill that lies on the surface.
        const int ix0 = std::max(px0 + 1, (int)std::floor(surfBox.x));
        const int iy0 = std::max(py0 + 1, (int)std::floor(surfBox.y));
        const int ix1 = std::min(px1 - 1, (int)std::ceil(surfBox.x + surfBox.w));
        const int iy1 = std::min(py1 - 1, (int)std::ceil(surfBox.y + surfBox.h));
        if (!lg::damageCovers(ctx, ix0, iy0, ix1, iy1)) {
            const double invS = 1.0 / (double)monitor->m_scale;
            g_pHyprRenderer->damageBox(CBox{monitor->m_position.x + rx0 * invS, monitor->m_position.y + ry0 * invS,
                                            (rx1 - rx0) * invS, (ry1 - ry0) * invS});
            continue;
        }
        // Working res: capture_scale divisor (4 = quarter-res chain; the
        // output is blurred anyway, so it upscales back nearly identically).
        const int hw = std::max(1, rw / T.capDiv), hh = std::max(1, rh / T.capDiv);

        ensureKawase(hw, hh, source->m_drmFormat);
        if (passes > 0)
            ensureChain(hw, hh, source->m_drmFormat);
        if (bokehOn)
            ensureBokeh(std::max(1, hw / 2), std::max(1, hh / 2), source->m_drmFormat);
        if (!m_halfA || !m_halfA->getTexture()
            || (passes > 0 && (!m_halfB || !m_halfC || !m_halfB->getTexture() || !m_halfC->getTexture()))
            || (bokehOn && (!m_halfT || !m_halfT->getTexture())))
            continue;

        g_pHyprOpenGL->setCapStatus(GL_SCISSOR_TEST, false);

        // 1. Downsample blit straight into halfA (free 2x downsample).
        // PERF: no glClear (blit overwrites every pixel; clear was a full
        // half-res fullscreen fill per pill per frame for nothing).
        glBindFramebuffer(GL_FRAMEBUFFER, fbId(m_halfA));
        g_pHyprRenderer->setViewport(0, 0, hw, hh);
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
            Mat3x3 proj = g_pHyprRenderer->projectBoxToTarget(ctx, quadBox, transform);
            // Upstream uploads projectBoxToTarget with GL_TRUE and no manual
            // transpose (see renderRect/renderTexture); match exactly.

            glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
            g_pHyprRenderer->setViewport(0, 0, (int)callerSize.x, (int)callerSize.y);
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
            // Dither/CA steps are in CAPTURE space. Use L0 even when the bokeh
            // texture is half-res, or enabling bokeh would double the grain
            // and CA tap spacing (bokeh shares L0's UV contract, not its
            // texel density).
            glUniform2f(m_gu.texel, 1.0f / (float)m_halfA->m_size.x, 1.0f / (float)m_halfA->m_size.y);
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
            // Apple rim light on the glass body (shared material with the
            // window-border ring). Width is logical px -> fb px here. The
            // angle follows the cursor per pill, slowly and mirrored in x.
            const bool rimOn = lg::getInt("plugin:liquidglass:glass_rim", 1) == 1;
            float rimAngle = lg::getFloat("plugin:liquidglass:rim_angle", 135.0f);
            const float rimPrev = m_rimFollow[pillIdx].angle;
            if (rimOn) {
                rimAngle = lg::rimAngleFor(CBox{lp.x, lp.y, lp.w, lp.h}, lg::cursorLocal(monitor), rimAngle, m_rimFollow[pillIdx]);
                if (m_rimFollow[pillIdx].init && std::isfinite(rimPrev) && std::abs(rimAngle - rimPrev) > 0.01f) {
                    const float inv = 1.0f / monitor->m_scale;
                    const float pad = 10.0f;
                    g_pHyprRenderer->damageBox(CBox{monitor->m_position.x + (lp.x - pad) * inv,
                                                    monitor->m_position.y + (lp.y - pad) * inv,
                                                    (lp.w + pad * 2.0f) * inv, (lp.h + pad * 2.0f) * inv});
                }
            }
            glUniform1f(m_gu.rimLight, rimOn ? 1.0f : 0.0f);
            glUniform1f(m_gu.rimStrength, std::max(0.0f, lg::getFloat("plugin:liquidglass:rim_strength", 1.0f)));
            glUniform1f(m_gu.rimWidth, std::max(0.75f, lg::getFloat("plugin:liquidglass:glass_rim_width", 1.1f) * (float)monitor->m_scale));
            glUniform1f(m_gu.rimAngle, rimAngle);
            glUniform1f(m_gu.rimSplay, std::clamp(lg::getFloat("plugin:liquidglass:rim_splay", 0.22f), 0.0f, 1.0f));
            glUniform1f(m_gu.rimShade, std::clamp(lg::getFloat("plugin:liquidglass:rim_shade", 0.009f), 0.0f, 1.0f));
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
            glUniform1i(m_gu.maskOn, m_mask.on ? 1 : 0);
            if (m_mask.on) {
                // Circle centre relative to this pill's centre, fb px.
                glUniform2f(m_gu.maskCenter,
                            (float)(m_mask.cx - ((lp.x - surfBox.x) + lp.w * 0.5)),
                            (float)(m_mask.cy - ((lp.y - surfBox.y) + lp.h * 0.5)));
                glUniform1f(m_gu.maskRadius, (float)m_mask.r);
            }
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
                glUniform1f(m_gu.unionOn, lp.unionOn ? 1.0f : 0.0f);
                glUniform4f(m_gu.unionA, lp.ua[0], lp.ua[1], lp.ua[2], lp.ua[3]);
                glUniform4f(m_gu.unionAR, lp.uar[0], lp.uar[1], lp.uar[2], lp.uar[3]);
                glUniform4f(m_gu.unionB, lp.ub[0], lp.ub[1], lp.ub[2], lp.ub[3]);
                glUniform4f(m_gu.unionBR, lp.ubr[0], lp.ubr[1], lp.ubr[2], lp.ubr[3]);
                glUniform1f(m_gu.unionK, lp.uk);
            }
            glBindVertexArray(m_vao);
            // Per damage RECT, not per damage extents (see DamageRect.hpp):
            // the pill quad carries the shadow margin, so extents-clipping
            // re-blends the halo outside this frame's repaint.
            //
            // Geometry is only applied once the live surface box matches the
            // publisher's declared size (ratio check above). During the commit
            // lag the cached previous pills are kept, so the glass stays the
            // old rounded panel instead of a new oversized pill clipped square
            // at the surface edge.
            lg::drawPerDamageRect(ctx, quadBox, [] { glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); });
            glBindVertexArray(0);
        }

        // 4. Layer border ring: same material as window borders, 1px,
        // inactive tint only, vertical fade shared with windows. Reuses the
        // same halfA/halfT capture above — no second blit.
        if (!lp.unionOn && layerBordersOn && m_ringOk && !borderPills.empty()) {
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
                Mat3x3 rproj = g_pHyprRenderer->projectBoxToTarget(ctx, ringBox, transform);
                glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
                g_pHyprRenderer->setViewport(0, 0, (int)callerSize.x, (int)callerSize.y);
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
                glUniform1f(m_ru.logCME, T.c > 0.001f ? std::log(T.c * 2.718281828459045f) : 0.0f);
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
                // Per damage RECT (see DamageRect.hpp): the ring fades to
                // alpha < 1, so extents-clipping re-blends it on pixels this
                // frame did not repaint.
                lg::drawPerDamageRect(ctx, ringBox, [] { glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); });
                glBindVertexArray(0);
            }
        }
    }

    // Blend state left as set above (Hyprland re-sets its own per draw).
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    g_pHyprRenderer->setViewport(0, 0, (int)callerSize.x, (int)callerSize.y);
}

// --- rim-only widgets (master switch off) ---------------------------------
//
// The glass body is off, but the Apple rim is an independent edge treatment.
// captureRim() runs before the layer content (same slot as the glass body)
// and keeps a quarter-res copy of the backdrop; drawRim() runs after the
// content and stamps just the rim on top, so the QML fallback background
// cannot bury it. No blur chain, bokeh, body tint or shadow runs here.

void CGlassLayer::captureRim(Render::CRenderContext& ctx, PHLMONITOR monitor) {
    m_rimReady = false;
    const auto surf = m_surface.lock();
    if (!surf || !monitor)
        return;

    CBox surfBox{surf->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT),
                 surf->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT)};
    surfBox.translate(-monitor->m_position);
    surfBox.scale(monitor->m_scale).round().noNegativeSize();
    if (!std::isfinite(surfBox.x) || !std::isfinite(surfBox.y) || surfBox.w <= 0 || surfBox.h <= 0)
        return;
    m_lastMonPos = monitor->m_position;

    std::vector<SPill> pills;
    if (!loadGeometry(monitor, surfBox, surf->m_namespace, pills) || pills.empty())
        return;
    // Circular iris clip (launcher open): the ring shader has no mask mode,
    // so don't paint a square rim over the animating circle.
    if (m_mask.on)
        return;

    float x0 = pills[0].x, y0 = pills[0].y, x1 = pills[0].x + pills[0].w, y1 = pills[0].y + pills[0].h;
    for (const auto& p : pills) {
        x0 = std::min(x0, p.x);
        y0 = std::min(y0, p.y);
        x1 = std::max(x1, p.x + p.w);
        y1 = std::max(y1, p.y + p.h);
    }

    // Bounds for damageRim()/glassBounds() (monitor-local LOGICAL px).
    const double inv = 1.0 / (double)monitor->m_scale;
    const double PAD_LOG = 12.0 * inv;
    m_boundsLog = CBox{x0 * inv - PAD_LOG, y0 * inv - PAD_LOG, (x1 - x0) * inv + 2 * PAD_LOG,
                       (y1 - y0) * inv + 2 * PAD_LOG};
    m_boundsOk = true;

    // Only the edge bands need repainting. Damage wholly inside the pill
    // interior (typing, video, cursor inside a widget) never touches the rim.
    const CBox dmg = ctx.m_data.damage.getExtents();
    if (dmg.w <= 0 || dmg.h <= 0)
        return;
    const double pad = 16.0;
    const double plate = 12.0 * (double)monitor->m_scale;
    if (dmg.x >= x0 + plate && dmg.y >= y0 + plate && dmg.x + dmg.w <= x1 - plate && dmg.y + dmg.h <= y1 - plate)
        return;
    if (dmg.x + dmg.w <= x0 - pad || dmg.y + dmg.h <= y0 - pad || dmg.x >= x1 + pad || dmg.y >= y1 + pad)
        return;

    const auto source = ctx.m_data.currentFB;
    if (!source)
        return;
    const int srcW = (int)source->m_size.x, srcH = (int)source->m_size.y;
    const int rx0 = std::max(0, (int)std::floor(x0 - pad));
    const int ry0 = std::max(0, (int)std::floor(y0 - pad));
    const int rx1 = std::min(srcW, (int)std::ceil(x1 + pad));
    const int ry1 = std::min(srcH, (int)std::ceil(y1 + pad));
    const int rw = rx1 - rx0, rh = ry1 - ry0;
    if (rw < 8 || rh < 8)
        return;

    const int hw = std::max(1, rw / 4), hh = std::max(1, rh / 4);
    ensureKawase(hw, hh, source->m_drmFormat);
    if (!m_halfA || !m_halfA->getTexture())
        return;
    ensureShaders();
    ensureRing();
    if (!m_shadersOk || !m_ringOk)
        return;

    g_pHyprOpenGL->setCapStatus(GL_SCISSOR_TEST, false);
    glBindFramebuffer(GL_FRAMEBUFFER, fbId(m_halfA));
    g_pHyprRenderer->setViewport(0, 0, hw, hh);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbId(source));
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbId(m_halfA));
    glBlitFramebuffer(rx0, ry0, rx1, ry1, 0, 0, hw, hh, GL_COLOR_BUFFER_BIT, GL_LINEAR);

    glBindFramebuffer(GL_FRAMEBUFFER, fbId(source));
    g_pHyprRenderer->setViewport(0, 0, srcW, srcH);

    m_rimPills = std::move(pills);
    m_rimCapBox = CBox{(double)rx0, (double)ry0, (double)rw, (double)rh};
    m_rimReady = true;
}

void CGlassLayer::drawRim(Render::CRenderContext& ctx, PHLMONITOR monitor) {
    if (!m_rimReady || m_rimPills.empty() || !monitor)
        return;
    const auto caller = ctx.m_data.currentFB;
    if (!caller)
        return;
    const auto callerSize = caller->m_size;
    const int rw = (int)m_rimCapBox.w, rh = (int)m_rimCapBox.h;
    if (rw < 8 || rh < 8 || !m_halfA || !m_halfA->getTexture())
        return;

    ensureRing();
    if (!m_ringOk)
        return;

    float ibR = 0.19f, ibG = 0.20f, ibB = 0.27f;
    float tmpR = 0, tmpG = 0, tmpB = 0;
    if (inactiveBorderRGB(tmpR, tmpG, tmpB)) {
        ibR = tmpR;
        ibG = tmpG;
        ibB = tmpB;
    }

    const auto transform = Math::wlTransformToHyprutils(Math::invertTransform(monitor->m_transform));
    Mat3x3 proj = g_pHyprRenderer->projectBoxToTarget(ctx, m_rimCapBox, transform);

    glEnable(GL_BLEND);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    g_pHyprOpenGL->setCapStatus(GL_SCISSOR_TEST, false);

    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    g_pHyprRenderer->setViewport(0, 0, (int)callerSize.x, (int)callerSize.y);
    glActiveTexture(GL_TEXTURE0);
    m_halfA->getTexture()->bind();
    m_halfA->getTexture()->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    m_halfA->getTexture()->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);

    auto shader = g_pHyprOpenGL->useShader(m_ring);

    const float shapeW = lg::getFloat("plugin:liquidglass:shape_width", 3.5f);
    const float shapeH = lg::getFloat("plugin:liquidglass:shape_height", 3.5f);
    const float lA = lg::getFloat("plugin:liquidglass:a", 0.7f);
    const float lB = lg::getFloat("plugin:liquidglass:b", 2.3f);
    const float lC = lg::getFloat("plugin:liquidglass:c", 5.2f);
    const float lD = lg::getFloat("plugin:liquidglass:border_d", 30.0f);
    const float lFPower = lg::getFloat("plugin:liquidglass:fpower", 1.0f);
    const float opacity = lg::getFloat("plugin:liquidglass:opacity", 0.23f);
    const float squircleF = lg::getFloat("plugin:liquidglass:squircle_f", 0.5f);
    const float rimStrength = std::max(0.0f, lg::getFloat("plugin:liquidglass:rim_strength", 1.0f));
    const float rimSplay = std::clamp(lg::getFloat("plugin:liquidglass:rim_splay", 0.22f), 0.0f, 1.0f);
    const float rimShade = std::clamp(lg::getFloat("plugin:liquidglass:rim_shade", 0.009f), 0.0f, 1.0f);
    const float rimLogical = std::max(0.0f, lg::getFloat("plugin:liquidglass:glass_rim_width", 1.1f));
    const float rimPx = std::max(0.75f, rimLogical * (float)monitor->m_scale);
    const int thick = std::max(1, (int)std::ceil(rimPx));
    const bool follow = lg::getInt("plugin:liquidglass:rim_follow", 1) != 0;

    for (size_t i = 0; i < m_rimPills.size(); ++i) {
        const auto& lp = m_rimPills[i];
        if (lp.unionOn) // unions animate through the full glass path; no stable rim outline
            continue;
        if (lp.w <= 2.0f * (float)thick || lp.h <= 2.0f * (float)thick)
            continue;
        if (m_rimFollow.size() <= i)
            m_rimFollow.resize(i + 1);

        float rimAngle = lg::getFloat("plugin:liquidglass:rim_angle", 135.0f);
        const float prev = m_rimFollow[i].angle;
        if (follow) {
            rimAngle = lg::rimAngleFor(CBox{lp.x, lp.y, lp.w, lp.h}, lg::cursorLocal(monitor), rimAngle, m_rimFollow[i]);
            if (m_rimFollow[i].init && std::isfinite(prev) && std::abs(rimAngle - prev) > 0.01f) {
                const float invS = 1.0f / (float)monitor->m_scale;
                const float pad = 12.0f;
                g_pHyprRenderer->damageBox(CBox{monitor->m_position.x + (lp.x - pad) * invS,
                                                monitor->m_position.y + (lp.y - pad) * invS,
                                                (lp.w + pad * 2.0f) * invS, (lp.h + pad * 2.0f) * invS});
            }
        }

        const float ix = lp.x - (float)m_rimCapBox.x;
        const float iy = lp.y - (float)m_rimCapBox.y;
        // Rim lives INSIDE the pill silhouette (same place as the in-glass
        // rim). ring.frag puts the band from uInner to uInner + uThick, so
        // shrink uInner by the band width and keep uThick for the outer edge.
        const float band = (float)thick;

        glUniformMatrix3fv(m_ru.proj, 1, GL_TRUE, proj.getMatrix().data());
        glUniform1i(m_ru.blur, 0);
        glUniform4f(m_ru.inner, ix + band, iy + band, lp.w - 2.0f * band, lp.h - 2.0f * band);
        glUniform2f(m_ru.quad, (float)rw, (float)rh);
        glUniform1f(m_ru.thick, band);
        glUniform1f(m_ru.round, lp.r[0]);
        glUniform3f(m_ru.tint, ibR, ibG, ibB);
        glUniform3f(m_ru.tint2, ibR, ibG, ibB);
        glUniform1f(m_ru.lerp, 0.0f);
        glUniform1f(m_ru.tintMix, opacity);
        glUniform1f(m_ru.a, 1.0f);
        glUniform2f(m_ru.winSize, lp.w, lp.h);
        glUniform1f(m_ru.winR, (lp.r[0] + lp.r[1] + lp.r[2] + lp.r[3]) * 0.25f);
        glUniform2f(m_ru.shape, shapeW, shapeH);
        glUniform1f(m_ru.lA, lA);
        glUniform1f(m_ru.lB, lB);
        glUniform1f(m_ru.lC, lC);
        glUniform1f(m_ru.lD, lD);
        glUniform1f(m_ru.lFPower, lFPower);
        glUniform1f(m_ru.logCME, lC > 0.001f ? std::log(lC * 2.718281828459045f) : 0.0f);
        glUniform1f(m_ru.glowW, 0.0f);
        glUniform1f(m_ru.glowE0, 0.5f);
        glUniform1f(m_ru.glowE1, -0.5f);
        glUniform1f(m_ru.glowT, 0.5f);
        glUniform1f(m_ru.glowBias, 0.0f);
        glUniform1f(m_ru.throwMax, std::min(24.0f, (float)thick * 1.5f));
        glUniform1f(m_ru.useRadii, 1.0f);
        glUniform4f(m_ru.radii, lp.r[0], lp.r[1], lp.r[2], lp.r[3]);
        glUniform4f(m_ru.winRadii, lp.r[0], lp.r[1], lp.r[2], lp.r[3]);
        glUniform2f(m_ru.flare, lp.fl[0], lp.fl[1]);
        glUniform1f(m_ru.squircleF, lp.sq >= 0.0f ? lp.sq : squircleF);
        glUniform1f(m_ru.push, 0.0f);
        glUniform1f(m_ru.fadeTop, 1.0f);
        glUniform1f(m_ru.fadeMid, 1.0f);
        glUniform1f(m_ru.fadeBottom, 1.0f);
        glUniform1f(m_ru.fadeAng, 0.0f);
        glUniform1f(m_ru.frameEnable, 0.0f);
        glUniform1f(m_ru.frameScale, 1.0f);
        glUniform1f(m_ru.seed, 0.37f);
        glUniform1f(m_ru.frieze, 0.0f);
        glUniform1f(m_ru.gilt, 0.0f);
        glUniform1f(m_ru.relief, 0.0f);
        glUniform3f(m_ru.shCol, 0.0f, 0.0f, 0.0f);
        glUniform1f(m_ru.shA, 0.0f);
        glUniform2f(m_ru.shOff, 0.0f, 0.0f);
        glUniform1f(m_ru.shBlur, 1.0f);
        glUniform1f(m_ru.rimLight, 1.0f);
        glUniform1f(m_ru.rimStrength, rimStrength);
        glUniform1f(m_ru.rimWidth, rimPx);
        glUniform1f(m_ru.rimAngle, rimAngle);
        glUniform1f(m_ru.rimSplay, rimSplay);
        glUniform1f(m_ru.rimShade, rimShade);

        glBindVertexArray(m_vao);
        lg::drawPerDamageRect(ctx, m_rimCapBox, [] { glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); });
        glBindVertexArray(0);
    }

    glBindFramebuffer(GL_FRAMEBUFFER, fbId(caller));
    g_pHyprRenderer->setViewport(0, 0, (int)callerSize.x, (int)callerSize.y);
}

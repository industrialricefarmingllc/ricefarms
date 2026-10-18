#include "Config.hpp"

#include <hyprland/src/config/values/ConfigValues.hpp>
#include <hyprland/src/helpers/Color.hpp>

#include <cmath>
#include <cstring>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>
#include <algorithm>

namespace lg {

namespace Key {
inline constexpr const char* ENABLED     = "plugin:liquidglass:enabled";
inline constexpr const char* NAMESPACES  = "plugin:liquidglass:namespaces";
inline constexpr const char* POWER       = "plugin:liquidglass:power";
inline constexpr const char* SHAPE_W     = "plugin:liquidglass:shape_width";
inline constexpr const char* SHAPE_H     = "plugin:liquidglass:shape_height";
// Shared squircle smoothing 0..1 (0 = circular corners, 0.5 = classic
// squircle n=4). Drives uSquircleF in glass.frag (bar/dock pills + window
// glass bodies) and mirrors the lucid/pibble QML squircle items, which
// read the same value from prefs.json.
inline constexpr const char* SQUIRCLE_F   = "plugin:liquidglass:squircle_f";
inline constexpr const char* A           = "plugin:liquidglass:a";
inline constexpr const char* B           = "plugin:liquidglass:b";
inline constexpr const char* C           = "plugin:liquidglass:c";
inline constexpr const char* D           = "plugin:liquidglass:d";
inline constexpr const char* FPOWER      = "plugin:liquidglass:fpower";
inline constexpr const char* NOISE       = "plugin:liquidglass:noise";
inline constexpr const char* BLUR_RADIUS = "plugin:liquidglass:blur_radius";
inline constexpr const char* BLUR_ITERS  = "plugin:liquidglass:blur_iters";
// Working-res divisor for the glass capture + Kawase chain (2 = half-res,
// 4 = quarter-res). The chain output is blurred content, so quarter-res
// upscales back nearly identically while using ~4x less scratch VRAM and
// ~3-4x less chain bandwidth. All downstream math (capScale UV mapping,
// per-level uHalfpixel, dither texel size) adapts automatically. 2 restores
// the old look pixel-nearly (detail-preserve term reads slightly sharper).
inline constexpr const char* CAPSCALE    = "plugin:liquidglass:capture_scale";
inline constexpr const char* GLOW_W      = "plugin:liquidglass:glow_weight";
inline constexpr const char* GLOW_B      = "plugin:liquidglass:glow_bias";
inline constexpr const char* GLOW_E0     = "plugin:liquidglass:glow_edge0";
inline constexpr const char* GLOW_E1     = "plugin:liquidglass:glow_edge1";
inline constexpr const char* GLOW_T      = "plugin:liquidglass:glow_threshold";
inline constexpr const char* OPACITY     = "plugin:liquidglass:opacity";
inline constexpr const char* TINT        = "plugin:liquidglass:tint";
inline constexpr const char* USE_PILL    = "plugin:liquidglass:use_pill";
inline constexpr const char* SHADOW      = "plugin:liquidglass:shadow_color";
inline constexpr const char* SHADOW_OX   = "plugin:liquidglass:shadow_offset_x";
inline constexpr const char* SHADOW_OY   = "plugin:liquidglass:shadow_offset_y";
inline constexpr const char* SHADOW_BLUR = "plugin:liquidglass:shadow_blur";
inline constexpr const char* CA          = "plugin:liquidglass:ca";
inline constexpr const char* DETAIL      = "plugin:liquidglass:detail_preserve";
inline constexpr const char* WINBORDERS  = "plugin:liquidglass:window_borders";
inline constexpr const char* OVERRIM    = "plugin:liquidglass:window_over_rim";
inline constexpr const char* OVERRIMEXCL = "plugin:liquidglass:window_over_rim_exclude";
inline constexpr const char* WINDOWS     = "plugin:liquidglass:windows";
inline constexpr const char* WINTINTFILE = "plugin:liquidglass:window_tint_file";
inline constexpr const char* WINOPACITY  = "plugin:liquidglass:window_opacity";
inline constexpr const char* WINACTIVEGL = "plugin:liquidglass:window_active_glow";
inline constexpr const char* BOKEH       = "plugin:liquidglass:bokeh";inline constexpr const char* NOWINSHADOW = "plugin:liquidglass:hide_window_shadows";
inline constexpr const char* BORDERBLUR = "plugin:liquidglass:border_blur_scale";
inline constexpr const char* BORDERD = "plugin:liquidglass:border_d";
inline constexpr const char* BORDERGLOWB = "plugin:liquidglass:border_glow_bias";
inline constexpr const char* LAYERBORDERS = "plugin:liquidglass:layer_borders";
inline constexpr const char* LAYERBOREXCL = "plugin:liquidglass:layer_border_exclude";
inline constexpr const char* LAYERBORW = "plugin:liquidglass:layer_border_width";
inline constexpr const char* FADETOP = "plugin:liquidglass:border_fade_top";
inline constexpr const char* FADEMID = "plugin:liquidglass:border_fade_mid";
inline constexpr const char* FADEBOT = "plugin:liquidglass:border_fade_bottom";
inline constexpr const char* FADEANG = "plugin:liquidglass:border_fade_angle";
// Neoclassical picture-frame relief carved into the border band (ring.frag).
// Procedural heightfield, no assets: courses across the band (egg-and-dart,
// bead-and-reel, frieze, dentils) + corner rosettes. No prefs twins yet.
inline constexpr const char* FRAMEENABLE = "plugin:liquidglass:frame_enable";
inline constexpr const char* FRAMESCALE = "plugin:liquidglass:frame_scale";
inline constexpr const char* FRAMESEED = "plugin:liquidglass:frame_seed_mode";
inline constexpr const char* FRAMEFRIEZE = "plugin:liquidglass:frame_frieze";
inline constexpr const char* FRAMEGILT = "plugin:liquidglass:frame_gilt";
inline constexpr const char* FRAMERELIEF = "plugin:liquidglass:frame_relief";
} // namespace Key

template <typename T, typename V>
static void add(HANDLE handle, const char* name, V def) {
    HyprlandAPI::addConfigValueV2(handle, Config::Values::makeConfigValue<T>(name, "", def, Config::Values::valueOptions_t<T>{}));
}

void registerConfig(HANDLE handle) {
    using namespace Config;
    add<Values::Int>(handle, Key::ENABLED, INTEGER{1});
    add<Values::String>(handle, Key::NAMESPACES, STRING{"quickshell"});
    add<Values::Float>(handle, Key::POWER, FLOAT{3.0});
    add<Values::Float>(handle, Key::SHAPE_W, FLOAT{3.5});
    add<Values::Float>(handle, Key::SHAPE_H, FLOAT{3.5});
    add<Values::Float>(handle, Key::SQUIRCLE_F, FLOAT{0.8});
    add<Values::Float>(handle, Key::A, FLOAT{0.7});
    add<Values::Float>(handle, Key::B, FLOAT{2.3});
    add<Values::Float>(handle, Key::C, FLOAT{5.2});
    add<Values::Float>(handle, Key::D, FLOAT{6.9});
    add<Values::Float>(handle, Key::FPOWER, FLOAT{1.0});
    add<Values::Float>(handle, Key::NOISE, FLOAT{0.06});
    add<Values::Float>(handle, Key::BLUR_RADIUS, FLOAT{2.0});
    add<Values::Float>(handle, Key::BLUR_ITERS, FLOAT{2});
    add<Values::Float>(handle, Key::CAPSCALE, FLOAT{4.0});
    add<Values::Float>(handle, Key::GLOW_W, FLOAT{0.25});
    add<Values::Float>(handle, Key::GLOW_B, FLOAT{0.0});
    add<Values::Float>(handle, Key::GLOW_E0, FLOAT{0.5});
    add<Values::Float>(handle, Key::GLOW_E1, FLOAT{-0.5});
    // Bright-cap threshold for the bipolar glow: soft-cut the |sin| lobes so
    // the non-glowing remainder dominates (~2/3 bright at 0.5, mildly tamed
    // vs the old full-lobe look at 0). No prefs twin.
    add<Values::Float>(handle, Key::GLOW_T, FLOAT{0.5});
    add<Values::Float>(handle, Key::OPACITY, FLOAT{0.82});
    // Static defaults mirror the CURRENT light theme (surface #f4fbf8).
    // The matugen tuner will push these live later; `hyprctl keyword`
    // cannot under the lua config.
    add<Values::Int>(handle, Key::TINT, INTEGER{0xeef5f2ff});
    add<Values::Int>(handle, Key::USE_PILL, INTEGER{1});
    // Shadow twin of the QML MultiEffect it replaces (volume OSD card:
    // hyprShadowBlur 0.85*52, offset 0/10 logical, hyprShadow color).
    // Offset/blur twins here are halved before use (quarter-blur /
    // half-offset convention: *0.25 / *0.5 at the call sites), so the
    // registered values read in QML units. Alpha low byte 0x11 = 0.0667:
    // the unified shadow at 33% of the OSD reference halved level (0.20),
    // used at full strength (no extra multiplier at the call sites).
    add<Values::Int>(handle, Key::SHADOW, INTEGER{0x1a1a1a11});
    add<Values::Float>(handle, Key::SHADOW_OX, FLOAT{0.0});
    add<Values::Float>(handle, Key::SHADOW_OY, FLOAT{20.0});
    add<Values::Float>(handle, Key::SHADOW_BLUR, FLOAT{57.0});
    // Chromatic aberration in the refraction taps (0 = off). No prefs twin
    // yet — static until the settings UI grows a slider.
    add<Values::Float>(handle, Key::CA, FLOAT{0.5});
    // Detail-preserving tint: scale the frost mix down where the backdrop
    // carries distinct shapes (contrast-gated in-shader). 0 restores the
    // flat mix. No prefs twin.
    add<Values::Float>(handle, Key::DETAIL, FLOAT{1.0});
    // Glass window borders (renderBorder replacement). Off by default:
    // windows keep their flat Hyprland borders. No prefs twin yet.
    add<Values::Int>(handle, Key::WINBORDERS, INTEGER{0});
    // REMOVED (no-op, kept registered for config compat): rim-only overdraw
    // on top of matched windows. The submission was deleted from hkRenderWindow
    // — no edge glass is ever drawn over regular windows anymore. Setting this
    // changes nothing.
    add<Values::Int>(handle, Key::OVERRIM, INTEGER{0});
    // Unused since the over-rim removal above (kept registered: unregistered
    // keys SEGV in getConfigValue instead of throwing).
    add<Values::String>(handle, Key::OVERRIMEXCL, STRING{"kitty,zen"});
    // Full-window UNDER-glass: comma-separated substring matches on
    // CWindow::m_class ("kitty" covers kitty terminals, "zen" covers
    // zen-browser). Empty disables window glass entirely. Glass draws BEFORE
    // the window content, so opaque (non-translucent) windows can never show
    // it — non-matching classes submit nothing at all (no capture, no blur,
    // no draw). Default "kitty,zen": only translucent terminals/browsers are
    // ever glassed. Use "*" only on fast GPUs (opaque matches still pay).
    add<Values::String>(handle, Key::WINDOWS, STRING{"kitty,zen"});
    // Window tint source: the terminal's own background color, NOT the
    // dark/light theme tint. Parsed for the last `background #rrggbb` line
    // (matugen regenerates it per theme mode, so the tint follows light/dark).
    // Falls back to the theme tint when unreadable. No prefs twin.
    add<Values::String>(handle, Key::WINTINTFILE, STRING{"~/.config/kitty/matugen-colors.conf"});
    // Window-only glass strength. Dark terminals over bright wallpapers need
    // far more tint than pills do; sharing `opacity` forces a bad compromise
    // (bar washed out vs terminal unreadable). Negative = follow `opacity`.
    // No prefs twin: set via conf or hl.config, live.
    add<Values::Float>(handle, Key::WINOPACITY, FLOAT{-1.0});
    // Active-window signal (the active border is removed in hyprland.lua):
    // extra edge glow weight while focused, ramped ~180ms in WindowGlass.
    // 0 off.
    add<Values::Float>(handle, Key::WINACTIVEGL, FLOAT{0.2});
    // Bokeh scatter over the blurred backdrop: bright-pass threshold +
    // golden-angle disc taps composited over the Kawase base. 0 = off
    // (zero cost: the pass is skipped). Prefs twin: liquidGlassBokeh.
    add<Values::Float>(handle, Key::BOKEH, FLOAT{0.0});
    // Window drop shadows are redundant next to glass borders (and double up
    // visually). Hooking the decoration (not the config) keeps the user's
    // own shadow settings intact for when this is off. No prefs twin yet.
    add<Values::Int>(handle, Key::NOWINSHADOW, INTEGER{1});
    // Ring blur is the same setting scaled down: 0.0 disables the pyramid
    // entirely (downsampled capture only — no blur passes run). No prefs.
    add<Values::Float>(handle, Key::BORDERBLUR, FLOAT{0.0});
    // Border-owned lens D (default 30): rims want a steeper profile than
    // pill bodies. The rest of the lens curve shares the pill keys.
    add<Values::Float>(handle, Key::BORDERD, FLOAT{30.0});
    // Border-owned glow bias (default 0.5): the glow weight/edges stay
    // shared with the pills. No prefs twin.
    add<Values::Float>(handle, Key::BORDERGLOWB, FLOAT{0.5});
    // Layer (quickshell pill) borders: same ring.frag as windows, 1px,
    // inactive tint only, dock excluded by default. Off by default: pills
    // keep glass bodies + shadows with no rings. No prefs twins yet.
    add<Values::Int>(handle, Key::LAYERBORDERS, INTEGER{0});
    add<Values::String>(handle, Key::LAYERBOREXCL, STRING{"dock,osd"});
    add<Values::Float>(handle, Key::LAYERBORW, FLOAT{1.0});
    // Fade for ALL borders (windows + layers): top->mid->bottom along a
    // rotated axis. 1/1/1 = no fade (old look); 1/0/1 = bright->transparent
    // ->bright. Angle in degrees, 0 = vertical.
    add<Values::Float>(handle, Key::FADETOP, FLOAT{1.0});
    add<Values::Float>(handle, Key::FADEMID, FLOAT{0.2});
    add<Values::Float>(handle, Key::FADEBOT, FLOAT{1.0});
    add<Values::Float>(handle, Key::FADEANG, FLOAT{33.0});
    // Picture-frame relief: 1 = on (auto-LOD kills it on thin bands such as
    // 1px layer borders). Scale multiplies all motif periods. Seed mode 1 =
    // per-window variation from a geometry hash, 0 = one frame everywhere.
    // Frieze -1 = per-window pick, 0 = egg-and-dart, 1 = greek key,
    // 2 = guilloche, 3 = fluting. Gilt 0 = carved stone, 1 = full gilt
    // crests. Relief = emboss + silhouette strength.
    add<Values::Int>(handle, Key::FRAMEENABLE, INTEGER{1});
    add<Values::Float>(handle, Key::FRAMESCALE, FLOAT{1.0});
    add<Values::Int>(handle, Key::FRAMESEED, INTEGER{1});
    add<Values::Float>(handle, Key::FRAMEFRIEZE, FLOAT{-1.0});
    add<Values::Float>(handle, Key::FRAMEGILT, FLOAT{1.0});
    add<Values::Float>(handle, Key::FRAMERELIEF, FLOAT{1.0});
}

// Read fresh on every call: correct across file writes, and at ~20
// lookups per glass draw the cost is noise next to the GL work. Order:
// prefs.json twin (live sliders) -> registered config value -> fallback.
namespace {
const char* tuneSuffix(const char* key);
bool        tuneLookup(const char* prefsKey, double& out);
bool        matugenColors(int& primaryRgb, int& surfaceRgb);
} // namespace
float getFloat(const char* key, float fallback) {
    if (const char* pk = tuneSuffix(key)) {
        double v = 0;
        if (tuneLookup(pk, v))
            return (float)v;
    }
    try {
        const auto v = Config::mgr()->getConfigValue(key);
        if (!v.dataptr)
            return fallback; // unregistered key: no value store (SEGVs if deref'd)
        return (float)**reinterpret_cast<Hyprlang::FLOAT* const*>(v.dataptr);
    } catch (...) { return fallback; }
}

int getInt(const char* key, int fallback) {
    if (!std::strcmp(key, Key::SHADOW)) {
        // Hue follows the theme live exactly like QML hyprShadow: matugen
        // primary at tone 10 in light mode, neutral black in dark mode.
        // Alpha stays with the registered/default low byte (0x11 = 0.0667:
        // the unified shadow at 33% of the halved OSD reference).
        int alpha = fallback & 0xFF;
        try {
            const auto v = Config::mgr()->getConfigValue(key);
            alpha = ((int)**reinterpret_cast<Hyprlang::INT* const*>(v.dataptr)) & 0xFF;
        } catch (...) {}
        int pr = -1, sr = -1;
        if (matugenColors(pr, sr) && pr >= 0)
            return ((pr << 8) & 0xFFFFFF00) | alpha;
        // else fall through to registered/default below
    }
    if (!std::strcmp(key, Key::TINT)) {
        // Tint follows the theme's surface (auto dark/light, like QML
        // bgOpaque); alpha stays with the registered/default low byte.
        int alpha = fallback & 0xFF;
        try {
            const auto v = Config::mgr()->getConfigValue(key);
            alpha = ((int)**reinterpret_cast<Hyprlang::INT* const*>(v.dataptr)) & 0xFF;
        } catch (...) {}
        int pr = -1, sr = -1;
        if (matugenColors(pr, sr) && sr >= 0)
            return ((sr << 8) & 0xFFFFFF00) | alpha;
        // else fall through to registered/default below
    }
    if (const char* pk = tuneSuffix(key)) {
        double v = 0;
        if (tuneLookup(pk, v))
            return (int)std::llround(v);
    }
    try {
        const auto v = Config::mgr()->getConfigValue(key);
        if (!v.dataptr)
            return fallback; // unregistered key: no value store (SEGVs if deref'd)
        return (int)**reinterpret_cast<Hyprlang::INT* const*>(v.dataptr);
    } catch (...) { return fallback; }
}

std::string getString(const char* key, const char* fallback) {
    // PERF: TTL cache (200ms) — windowAllowed/overRimExcluded/namespaceAllowed
    // call this per window/layer per frame (~1k/sec at 60fps); each call did
    // a config-manager lookup + std::string alloc. Window/rule edits land
    // within 200ms, imperceptible.
    struct Entry {
        std::string value;
        std::chrono::steady_clock::time_point t = std::chrono::steady_clock::now() - std::chrono::hours(1);
        bool has = false;
    };
    static std::map<std::string, Entry> cache;
    const auto now = std::chrono::steady_clock::now();
    auto it = cache.find(key ? key : "");
    if (it != cache.end() && it->second.has
        && (now - it->second.t) < std::chrono::milliseconds(200))
        return it->second.value;
    std::string out;
    try {
        const auto v = Config::mgr()->getConfigValue(key);
        if (!v.dataptr)
            out = std::string(fallback); // unregistered key: no value store (SEGVs if deref'd)
        else {
            const char* s = **reinterpret_cast<Hyprlang::STRING* const*>(v.dataptr);
            out = s ? std::string(s) : std::string(fallback);
        }
    } catch (...) { out = std::string(fallback); }
    cache[std::string(key ? key : "")] = Entry{out, now, true};
    return out;
}

bool namespaceAllowed(const std::string& ns) {
    return ns.find(getString(Key::NAMESPACES, "quickshell")) != std::string::npos;
}

bool patternMatches(const std::string& pat, const std::string& cls, bool emptyMatches);

bool windowAllowed(const std::string& cls) {
    return patternMatches(getString(Key::WINDOWS, "*"), cls, false);
}

// Rim-overdraw exclusion: translucent regulars (kitty/zen) already show the
// under-glass, so a second rim on top would double their edge glow. Same
// token convention as windowAllowed; empty disables the exclusion.
bool overRimExcluded(const std::string& cls) {
    return patternMatches(getString(Key::OVERRIMEXCL, "kitty,zen"), cls, true);
}

// Shared comma-separated matcher: substring tokens, "*" wildcard, trimmed,
// empty tokens skip. For allow-lists an empty pattern means none; for
// exclude-lists it means no exclusions.
bool patternMatches(const std::string& pat, const std::string& cls, bool emptyMatches) {
    if (pat.empty())
        return emptyMatches;
    // Comma-separated substring list: "kitty,zen" matches class "kitty"
    // and class "zen"/"zen-browser"; a "*" token matches every window.
    // Tokens are trimmed; empty tokens skip.
    size_t start = 0;
    while (start <= pat.size()) {
        size_t end = pat.find(',', start);
        if (end == std::string::npos)
            end = pat.size();
        size_t a = start;
        while (a < end && (pat[a] == ' ' || pat[a] == '\t'))
            ++a;
        size_t b = end;
        while (b > a && (pat[b - 1] == ' ' || pat[b - 1] == '\t'))
            --b;
        if (b > a && pat.compare(a, b - a, "*") == 0)
            return true; // wildcard: every window class matches
        if (b > a && cls.find(pat.substr(a, b - a)) != std::string::npos)
            return true;
        if (end == pat.size())
            break;
        start = end + 1;
    }
    return false;
}

// --- prefs.json tuner ------------------------------------------------------
// `hyprctl keyword` is dead under the lua config, so nothing can push values
// into the plugin at runtime — sliders would be decorative. Instead the
// plugin reads the shell's own prefs file (same one the settings UI writes,
// same path as Prefs.qml), mtime-gated and parsed with the same order-free
// JSON helpers as the geometry bridge. Slider drag -> file write -> live in
// the next frame. Missing file/keys fall through to the registered values,
// then to compiled fallbacks — every layer degrades, nothing throws.

namespace {

const char* tuneSuffix(const char* key) {
    static constexpr const char* P = "plugin:liquidglass:";
    const size_t n = std::strlen(P);
    if (std::strncmp(key, P, n) != 0)
        return nullptr;
    const char* s = key + n;
    if (!std::strcmp(s, "enabled")) return "liquidGlassEnabled";
    if (!std::strcmp(s, "power")) return "liquidGlassPower";
    if (!std::strcmp(s, "shape_width")) return "liquidGlassWidth";
    if (!std::strcmp(s, "shape_height")) return "liquidGlassHeight";
    if (!std::strcmp(s, "squircle_f")) return "squircleF";
    if (!std::strcmp(s, "a")) return "liquidGlassA";
    if (!std::strcmp(s, "b")) return "liquidGlassB";
    if (!std::strcmp(s, "c")) return "liquidGlassC";
    if (!std::strcmp(s, "d")) return "liquidGlassD";
    if (!std::strcmp(s, "fpower")) return "liquidGlassFPower";
    if (!std::strcmp(s, "noise")) return "liquidGlassNoise";
    if (!std::strcmp(s, "blur_radius")) return "liquidGlassBlurRadius";
    if (!std::strcmp(s, "bokeh")) return "liquidGlassBokeh";
    if (!std::strcmp(s, "blur_iters")) return "liquidGlassBlurIters";
    if (!std::strcmp(s, "glow_weight")) return "liquidGlassGlowWeight";
    if (!std::strcmp(s, "glow_bias")) return "liquidGlassGlowBias";
    if (!std::strcmp(s, "glow_edge0")) return "liquidGlassGlowEdge0";
    if (!std::strcmp(s, "glow_edge1")) return "liquidGlassGlowEdge1";
    if (!std::strcmp(s, "opacity")) return "liquidGlassOpacity";
    return nullptr; // tint/shadow/use_pill/namespaces: no prefs twins (yet)
}

std::string tunePath() {
    const char* home = std::getenv("HOME");
    if (!home || !*home)
        return {};
    return std::string(home) + "/.config/quickshell/lucidprefs/prefs.json";
}

const char* tSkip(const char* p, const char* end) {
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ','))
        ++p;
    return p;
}

// Value after "key": — number, or JSON true/false.
bool tValue(const char* p, const char* end, const char* key, double& out) {
    const std::string needle = std::string("\"") + key + "\"";
    const char* at = std::search(p, end, needle.begin(), needle.end());
    if (at == end)
        return false;
    p = at + needle.size();
    p = tSkip(p, end);
    if (p < end && *p == ':')
        ++p;
    p = tSkip(p, end);
    if (end - p >= 4 && !std::strncmp(p, "true", 4)) {
        out = 1.0;
        return true;
    }
    if (end - p >= 5 && !std::strncmp(p, "false", 5)) {
        out = 0.0;
        return true;
    }
    char* stop = nullptr;
    out = std::strtod(p, &stop);
    return stop != p;
}

struct TuneCache {
    std::filesystem::file_time_type stamp = std::filesystem::file_time_type::min();
    std::map<std::string, double> values;
    bool haveFile = false;
};

// --- matugen shadow hue ----------------------------------------------------
// QML shadow color is atTone(cPrimary, 10): the theme primary pulled down to
// tone 10, hue preserved. Ported 1:1 from Theme.qml (_lin/_gam/_y/_yAt +
// the gamut-compensated scale), fed from the same matugen.json the shell
// reads. mtime-gated like the prefs tuner. Only the HUE travels this path;
// alpha stays with the registered/default shadow_color low byte.

double mLin(double c) {
    return c <= 0.04045 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4);
}
double mGam(double c) {
    const double v = c <= 0.0031308 ? c * 12.92 : 1.055 * std::pow(c, 1.0 / 2.4) - 0.055;
    return std::max(0.0, std::min(1.0, v));
}
void mAtTone10(double r, double g, double b, double& or_, double& og, double& ob) {
    const double target = std::pow((10.0 + 16.0) / 116.0, 3); // _yAt(10)
    const double y = 0.2126 * mLin(r) + 0.7152 * mLin(g) + 0.0722 * mLin(b);
    if (y <= 0) {
        const double gr = mGam(target);
        or_ = og = ob = gr;
        return;
    }
    const double k = target / y;
    double lr = mLin(r) * k, lg = mLin(g) * k, lb = mLin(b) * k;
    const double peak = std::max({lr, lg, lb});
    if (peak > 1) {
        lr /= peak;
        lg /= peak;
        lb /= peak;
        const double yb = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb;
        const double w = yb >= 1 ? 0 : std::max(0.0, std::min(1.0, (target - yb) / (1 - yb)));
        lr += (1 - lr) * w;
        lg += (1 - lg) * w;
        lb += (1 - lb) * w;
    }
    or_ = mGam(lr);
    og = mGam(lg);
    ob = mGam(lb);
}

struct MatugenCache {
    std::filesystem::file_time_type stamp = std::filesystem::file_time_type::min();
    std::filesystem::file_time_type modeStamp = std::filesystem::file_time_type::min();
    bool ok = false;
    int primaryRgb = 0; // 0xRRGGBB, for atTone shadow hue (light) / black (dark)
    int surfaceRgb = 0; // 0xRRGGBB, for auto dark/light tint
    bool hasPrimary = false;
    bool hasSurface = false;
};

// Theme mode mirror of Theme.qml (defaults to dark when the file is
// missing). Drives the shadow hue: matugen tone-10 in light mode, neutral
// black in dark mode — exactly like QML hyprShadow.
static std::string themeMode(std::filesystem::file_time_type& stampOut) {
    const char* home = std::getenv("HOME");
    if (!home || !*home)
        return "dark";
    const std::string path = std::string(home) + "/.cache/quickshell/theme_mode";
    std::error_code ec;
    const auto st = std::filesystem::last_write_time(path, ec);
    if (ec) {
        stampOut = std::filesystem::file_time_type::min();
        return "dark";
    }
    stampOut = st;
    std::ifstream f(path);
    std::string s;
    if (f)
        std::getline(f, s);
    const auto b = s.find_first_not_of(" \t\n\r");
    if (b == std::string::npos)
        return "dark";
    const auto e = s.find_last_not_of(" \t\n\r");
    s = s.substr(b, e - b + 1);
    return s.empty() ? "dark" : s;
}

bool matugenColors(int& primaryRgb, int& surfaceRgb) {
    static MatugenCache cache;
    // PERF: stat TTL (100ms) — theme switches are rare; was 2 stats per
    // getInt(tint/shadow) call in the render thread.
    static auto lastStat = std::chrono::steady_clock::now() - std::chrono::hours(1);
    const auto now = std::chrono::steady_clock::now();
    if (cache.ok && (now - lastStat) < std::chrono::milliseconds(100)) {
        primaryRgb = cache.hasPrimary ? cache.primaryRgb : -1;
        surfaceRgb = cache.hasSurface ? cache.surfaceRgb : -1;
        return true;
    }
    lastStat = now;
    const char* home = std::getenv("HOME");
    if (!home || !*home)
        return false;
    const std::string path = std::string(home) + "/.cache/quickshell/matugen.json";
    std::error_code ec;
    const auto stamp = std::filesystem::last_write_time(path, ec);
    if (ec)
        return false;
    std::filesystem::file_time_type modeStamp = std::filesystem::file_time_type::min();
    const std::string mode = themeMode(modeStamp);
    if (!cache.ok || cache.stamp != stamp || cache.modeStamp != modeStamp) {
        MatugenCache fresh;
        fresh.stamp = stamp;
        fresh.modeStamp = modeStamp;
        std::ifstream f(path);
        if (f) {
            const std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
            const char* p = text.data();
            const char* end = p + text.size();
            auto hexKey = [&](const char* key, unsigned& v) {
                const std::string needle = std::string("\"") + key + "\"";
                const char* at = std::search(p, end, needle.begin(), needle.end());
                if (at == end)
                    return false;
                const char* q = at + needle.size();
                while (q < end && (*q == ' ' || *q == '\t' || *q == '\n' || *q == '\r' || *q == ',' || *q == ':'))
                    ++q;
                if (q < end && *q == '"')
                    ++q;
                if (q < end && *q == '#')
                    ++q;
                v = 0;
                int n = 0;
                while (q < end && n < 6) {
                    const char c = *q;
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
                    ++q;
                    ++n;
                }
                return n == 6;
            };
            unsigned pv = 0;
            const bool hasPv = hexKey("primary", pv);
            if (mode == "light" && hasPv) {
                double or_, og, ob;
                mAtTone10(((pv >> 16) & 0xFF) / 255.0, ((pv >> 8) & 0xFF) / 255.0, (pv & 0xFF) / 255.0, or_, og, ob);
                fresh.primaryRgb = ((int)std::lround(or_ * 255) << 16) | ((int)std::lround(og * 255) << 8)
                    | (int)std::lround(ob * 255);
                fresh.hasPrimary = true;
            } else if (mode != "light") {
                fresh.primaryRgb = 0x000000;
                fresh.hasPrimary = true;
            }
            unsigned sv = 0;
            if (hexKey("surface", sv)) {
                fresh.surfaceRgb = (int)sv;
                fresh.hasSurface = true;
            }
            fresh.ok = fresh.hasPrimary || fresh.hasSurface;
        }
        cache = fresh;
    }
    if (!cache.ok)
        return false;
    primaryRgb = cache.hasPrimary ? cache.primaryRgb : -1;
    surfaceRgb = cache.hasSurface ? cache.surfaceRgb : -1;
    return true;
}

bool tuneLookup(const char* prefsKey, double& out) {
    static TuneCache cache;
    // PERF: stat TTL (50ms) — was 1 stat per getFloat call (~10k stats/sec
    // in the render thread at 60fps with several windows+layers; on HDD
    // each stat stalls input). Slider/theme edits land within 50ms (20Hz),
    // imperceptible; parsing still only on mtime change.
    static auto lastStat = std::chrono::steady_clock::now() - std::chrono::hours(1);
    const auto now = std::chrono::steady_clock::now();
    const bool check = !cache.haveFile
        || (now - lastStat) > std::chrono::milliseconds(50);
    if (!check) {
        const auto it = cache.values.find(prefsKey);
        if (it == cache.values.end())
            return false;
        out = it->second;
        return true;
    }
    lastStat = now;
    const std::string path = tunePath();
    if (path.empty())
        return false;
    std::error_code ec;
    const auto stamp = std::filesystem::last_write_time(path, ec);
    if (ec)
        return false;
    if (!cache.haveFile || cache.stamp != stamp) {
        std::ifstream f(path);
        if (!f)
            return false;
        const std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        TuneCache fresh;
        fresh.stamp = stamp;
        fresh.haveFile = true;
        // Keys the tuner serves (plus the glow master switch).
        static const char* keys[] = {"liquidGlassEnabled",  "liquidGlassPower",      "liquidGlassWidth",  "liquidGlassHeight",
                                     "liquidGlassA",        "liquidGlassB",          "liquidGlassC",      "liquidGlassD",
                                     "liquidGlassFPower",   "liquidGlassNoise",      "liquidGlassBlurRadius", "liquidGlassBlurIters",
                                     "liquidGlassBokeh",    "liquidGlassGlow",       "liquidGlassGlowWeight", "liquidGlassGlowBias",
                                     "liquidGlassGlowEdge0", "liquidGlassGlowEdge1", "liquidGlassOpacity",    nullptr};
        const char* p = text.data();
        const char* end = p + text.size();
        for (int i = 0; keys[i]; i++) {
            double v = 0;
            if (tValue(p, end, keys[i], v))
                fresh.values[keys[i]] = v;
        }
        // liquidGlassGlow is a master switch: fold it into the weight so the
        // shader needs no extra uniform.
        auto itg = fresh.values.find("liquidGlassGlow");
        if (itg != fresh.values.end() && itg->second < 0.5)
            fresh.values["liquidGlassGlowWeight"] = 0.0;
        cache = std::move(fresh);
    }
    const auto it = cache.values.find(prefsKey);
    if (it == cache.values.end())
        return false;
    out = it->second;
    return true;
}

} // namespace

void notify(const std::string& text) {
    void* const handle = pluginHandle();
    if (handle)
        HyprlandAPI::addNotification(handle, text, CHyprColor{0.55, 0.75, 1.0, 1.0}, 3500);
}

uint64_t tuneGeneration() {
    static uint64_t gen = 0;
    static std::filesystem::file_time_type prefsStamp = std::filesystem::file_time_type::min();
    static std::filesystem::file_time_type matugenStamp = std::filesystem::file_time_type::min();
    static std::filesystem::file_time_type modeStamp = std::filesystem::file_time_type::min();
    static bool first = true;
    // PERF: stat TTL (50ms) — was 3 stats per call, once per layer/window
    // per frame in the render thread (~1.5k stats/sec at 60fps).
    static auto lastStat = std::chrono::steady_clock::now() - std::chrono::hours(1);
    const auto now = std::chrono::steady_clock::now();
    if (!first && (now - lastStat) < std::chrono::milliseconds(50))
        return gen;
    lastStat = now;
    const char* home = std::getenv("HOME");
    if (home && *home) {
        std::error_code ec;
        const auto ps = std::filesystem::last_write_time(std::string(home) + "/.config/quickshell/lucidprefs/prefs.json", ec);
        if (!ec && (first || ps != prefsStamp)) {
            prefsStamp = ps;
            if (!first)
                gen++;
        }
        const auto ms = std::filesystem::last_write_time(std::string(home) + "/.cache/quickshell/matugen.json", ec);
        if (!ec && (first || ms != matugenStamp)) {
            matugenStamp = ms;
            if (!first)
                gen++;
        }
        // Shadow hue follows the theme mode (QML hyprShadow twin): a
        // light/dark switch must repaint without a full reload.
        const auto ts = std::filesystem::last_write_time(std::string(home) + "/.cache/quickshell/theme_mode", ec);
        if (!ec && (first || ts != modeStamp)) {
            modeStamp = ts;
            if (!first)
                gen++;
        }
    }
    first = false;
    return gen;
}

} // namespace lg

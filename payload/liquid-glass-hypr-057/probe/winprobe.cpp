// winprobe: renderWindow call census. Hook-only, zero GL, leaves no trace
// except one log file. Answers: which eRenderPassMode do real window
// renders use (MAIN vs ALL vs POPUP), and are kitty windows mapped there?
// -> ~/.cache/liquid-glass-hypr/winprobe.log. Leave loaded (never unload live).

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/Renderer.hpp>

#include <cstdlib>
#include <fstream>
#include <map>
#include <string>

namespace {

HANDLE PHANDLE = nullptr;
CFunctionHook* G_HOOK = nullptr;

std::string cacheDir() {
    if (const char* xdg = std::getenv("XDG_CACHE_HOME"); xdg && *xdg)
        return std::string(xdg) + "/liquid-glass-hypr";
    if (const char* home = std::getenv("HOME"); home && *home)
        return std::string(home) + "/.cache/liquid-glass-hypr";
    return {};
}

void wlog(const std::string& line) {
    const std::string dir = cacheDir();
    if (dir.empty())
        return;
    std::ofstream f(dir + "/winprobe.log", std::ios::app);
    f << line << std::endl;
}

using RenderWindowFn = void (*)(Render::IHyprRenderer*, PHLWINDOW, PHLMONITOR, const Time::steady_tp&, bool,
                                Render::eRenderPassMode, bool, bool);
RenderWindowFn g_orig = nullptr;
long g_n = 0;
std::map<int, long> g_modes;
std::map<std::string, long> g_classes;

void hkRenderWindow(Render::IHyprRenderer* self, PHLWINDOW window, PHLMONITOR monitor, const Time::steady_tp& now,
                    bool decorate, Render::eRenderPassMode passMode, bool ignorePosition, bool standalone) {
    ++g_n;
    g_modes[(int)passMode]++;
    const std::string cls = window ? window->m_class : std::string("(null)");
    g_classes[cls]++;
    const bool mapped = window && window->m_isMapped;
    bool hidden = true;
    if (window) {
        try {
            hidden = window->isHidden();
        } catch (...) {}
    }
    const bool snap = g_pHyprRenderer ? g_pHyprRenderer->m_bRenderingSnapshot : false;
    // First calls in full, then 1/600 summaries (renderWindow fires per
    // window per frame — never spam the log).
    if (g_n <= 12 || g_n % 600 == 0) {
        std::string s = "win n=" + std::to_string(g_n) + " passMode=" + std::to_string((int)passMode)
            + " decorate=" + (decorate ? "1" : "0") + " ignorePos=" + (ignorePosition ? "1" : "0") + " standalone="
            + (standalone ? "1" : "0") + " snap=" + (snap ? "1" : "0") + " class=" + cls + " mapped="
            + (mapped ? "1" : "0") + " hidden=" + (hidden ? "1" : "0");
        s += " | modes:";
        for (const auto& kv : g_modes)
            s += " " + std::to_string(kv.first) + "=" + std::to_string(kv.second);
        s += " | classes:";
        int shown = 0;
        for (const auto& kv : g_classes) {
            if (++shown > 6)
                break;
            s += " " + kv.first + "=" + std::to_string(kv.second);
        }
        wlog(s);
    }
    g_orig(self, window, monitor, now, decorate, passMode, ignorePosition, standalone);
}

} // namespace

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;
    wlog("winprobe: init");
    for (const auto& m : HyprlandAPI::findFunctionsByName(PHANDLE, "renderWindow")) {
        if (!(m.demangled.contains("renderWindow") && m.demangled.contains("IHyprRenderer")))
            continue;
        G_HOOK = HyprlandAPI::createFunctionHook(PHANDLE, m.address, (void*)hkRenderWindow);
        if (G_HOOK && G_HOOK->hook()) {
            g_orig = reinterpret_cast<RenderWindowFn>(G_HOOK->m_original);
            break;
        }
        G_HOOK = nullptr;
    }
    wlog(g_orig ? "winprobe: HOOKED" : "winprobe: HOOK FAILED");
    return {"winprobe", "renderWindow census (hook-only)", "Lucid", "0.1.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    if (G_HOOK) {
        HyprlandAPI::removeFunctionHook(PHANDLE, G_HOOK);
        G_HOOK = nullptr;
    }
}

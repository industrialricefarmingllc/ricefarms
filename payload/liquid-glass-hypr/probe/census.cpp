// lgprobe v3: symbol census only. No hooks, zero interference.
// Dumps every candidate for render-critical symbols so we can see whether
// liquidglass could have hooked a never-called overload.
// -> ~/.cache/liquid-glass-hypr/probe.log. Never unload live.

#include <hyprland/src/plugins/PluginAPI.hpp>

#include <cstdlib>
#include <fstream>
#include <string>

namespace {

std::string cacheDir() {
    if (const char* xdg = std::getenv("XDG_CACHE_HOME"); xdg && *xdg)
        return std::string(xdg) + "/liquid-glass-hypr";
    if (const char* home = std::getenv("HOME"); home && *home)
        return std::string(home) + "/.cache/liquid-glass-hypr";
    return {};
}

void dump(HANDLE h, const char* sym) {
    const std::string dir = cacheDir();
    std::ofstream f(dir + "/probe.log", std::ios::app);
    const auto ms = HyprlandAPI::findFunctionsByName(h, sym);
    f << "census[" << sym << "] n=" << ms.size() << std::endl;
    for (const auto& m : ms)
        f << "  addr=" << m.address << " :: " << m.demangled << std::endl;
}

} // namespace

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    dump(handle, "renderLayer");
    dump(handle, "beginRender");
    dump(handle, "renderMonitor");
    return {"lgprobe3", "symbol census (no hooks)", "Lucid", "0.3.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {}

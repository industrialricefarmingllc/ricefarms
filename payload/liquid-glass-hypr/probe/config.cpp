// lgprobe v4: config-value census. Reads the liquidglass keys with the EXACT
// same mechanism as the real plugin (Config::mgr()->getConfigValue) and
// reports dataptr null-ness + decoded values. If `enabled` reads 0 under
// the lua config, the hook adds no elements and nothing can ever draw.
// -> ~/.cache/liquid-glass-hypr/probe.log. No hooks. Never unload live.

#include <hyprland/src/config/ConfigManager.hpp>
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

void probeLog(const std::string& line) {
    const std::string dir = cacheDir();
    if (dir.empty())
        return;
    std::ofstream f(dir + "/probe.log", std::ios::app);
    f << line << std::endl;
}

std::string readKey(const char* key) {
    try {
        const auto v = Config::mgr()->getConfigValue(key);
        if (!v.dataptr)
            return "dataptr=NULL";
        if (!*v.dataptr)
            return"text=*dataptr=NULL";
        std::string t = v.type ? v.type->name() : "?";
        // Try INT then FLOAT then STRING decoding by reported type name.
        if (t.find("long") != std::string::npos || t.find("int") != std::string::npos || t == "l" || t == "i" || t == "x")
            return "int=" + std::to_string((long long)**reinterpret_cast<Hyprlang::INT* const*>(v.dataptr)) + " type=" + t;
        if (t.find("float") != std::string::npos || t.find("double") != std::string::npos || t == "f" || t == "d")
            return "float=" + std::to_string((double)**reinterpret_cast<Hyprlang::FLOAT* const*>(v.dataptr)) + " type=" + t;
        const char* s = **reinterpret_cast<Hyprlang::STRING* const*>(v.dataptr);
        return std::string("str=") + (s ? s : "(null)") + " type=" + t;
    } catch (const std::exception& e) {
        return std::string("EXC:") + e.what();
    } catch (...) { return "EXC:unknown"; }
}

} // namespace

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    (void)handle;
    probeLog("cfg[plugin:liquidglass:enabled]=" + readKey("plugin:liquidglass:enabled"));
    probeLog("cfg[plugin:liquidglass:namespaces]=" + readKey("plugin:liquidglass:namespaces"));
    probeLog("cfg[plugin:liquidglass:opacity]=" + readKey("plugin:liquidglass:opacity"));
    probeLog("cfg[plugin:liquidglass:blur_radius]=" + readKey("plugin:liquidglass:blur_radius"));
    return {"lgprobe4", "config census (no hooks)", "Lucid", "0.4.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {}

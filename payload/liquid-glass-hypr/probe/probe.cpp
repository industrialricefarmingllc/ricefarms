// lgprobe v2: diagnostic sidecar.
// Q1: does function-hooking work at all in this session? (hook beginRender)
// Q2: is renderLayer free or held by liquidglass? (try hooking it)
// Results -> ~/.cache/liquid-glass-hypr/probe.log + summary toast.
// Hook-only, frees nothing. Never unload live.

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/Renderer.hpp>

#include <cstdlib>
#include <fstream>
#include <string>

namespace {

HANDLE PHANDLE = nullptr;
CFunctionHook* G_HOOK_BEGIN = nullptr;
CFunctionHook* G_HOOK_LAYER = nullptr;

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

void probeToast(const std::string& text) {
    if (PHANDLE)
        HyprlandAPI::addNotification(PHANDLE, text, CHyprColor{0.4, 1.0, 0.5, 1.0}, 6000);
}

using BeginRenderFn = void (*)(Render::IHyprRenderer*);
BeginRenderFn g_origBegin = nullptr;

void hkBegin(Render::IHyprRenderer* self) {
    static long n = 0;
    static bool first = false;
    ++n;
    if (!first) {
        first = true;
        probeLog("beginRender FIRST FIRE");
        probeToast("probe: beginRender fires — hooking works");
    }
    if (n % 600 == 0)
        probeLog("beginRender tick " + std::to_string(n));
    g_origBegin(self);
}

using RenderLayerFn = void (*)(Render::IHyprRenderer*, PHLLS, PHLMONITOR, const Time::steady_tp&, bool, bool);
RenderLayerFn g_origLayer = nullptr;

void hkLayer(Render::IHyprRenderer* self, PHLLS surface, PHLMONITOR monitor, const Time::steady_tp& now, bool popups, bool lockscreen) {
    static long n = 0, mappedNs = 0;
    ++n;
    if (!popups && surface && surface->m_mapped && surface->m_namespace.find("quickshell") != std::string::npos)
        ++mappedNs;
    if (n == 600)
        probeLog("layerPROBE calls=600 mappedNs=" + std::to_string(mappedNs));
    g_origLayer(self, surface, monitor, now, popups, lockscreen);
}

} // namespace

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    for (const auto& m : HyprlandAPI::findFunctionsByName(PHANDLE, "beginRender")) {
        if (!m.demangled.contains("beginRender"))
            continue;
        G_HOOK_BEGIN = HyprlandAPI::createFunctionHook(PHANDLE, m.address, (void*)hkBegin);
        if (G_HOOK_BEGIN && G_HOOK_BEGIN->hook()) {
            g_origBegin = reinterpret_cast<BeginRenderFn>(G_HOOK_BEGIN->m_original);
            break;
        }
        G_HOOK_BEGIN = nullptr;
    }
    probeLog(g_origBegin ? "probe: beginRender HOOKED" : "probe: beginRender HOOK FAILED");

    for (const auto& m : HyprlandAPI::findFunctionsByName(PHANDLE, "renderLayer")) {
        if (!(m.demangled.contains("renderLayer") && m.demangled.contains("LayerSurface")))
            continue;
        G_HOOK_LAYER = HyprlandAPI::createFunctionHook(PHANDLE, m.address, (void*)hkLayer);
        if (G_HOOK_LAYER && G_HOOK_LAYER->hook()) {
            g_origLayer = reinterpret_cast<RenderLayerFn>(G_HOOK_LAYER->m_original);
            break;
        }
        G_HOOK_LAYER = nullptr;
    }
    probeLog(g_origLayer ? "probe: renderLayer HOOKED (liquidglass does NOT hold it!)" : "probe: renderLayer OCCUPIED/FAILED (liquidglass likely holds it)");
    if (!g_origBegin)
        probeToast("probe: beginRender HOOK FAILED");

    return {"lgprobe", "diagnostic sidecar (hook-only)", "Lucid", "0.2.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    if (G_HOOK_BEGIN) {
        HyprlandAPI::removeFunctionHook(PHANDLE, G_HOOK_BEGIN);
        G_HOOK_BEGIN = nullptr;
    }
    if (G_HOOK_LAYER) {
        HyprlandAPI::removeFunctionHook(PHANDLE, G_HOOK_LAYER);
        G_HOOK_LAYER = nullptr;
    }
}

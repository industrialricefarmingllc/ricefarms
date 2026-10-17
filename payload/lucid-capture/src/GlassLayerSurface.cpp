#include "GlassLayerSurface.hpp"
#include "BuiltInPresets.hpp"
#include "ExportWorker.hpp"
#include "GlassRenderer.hpp"
#include "Globals.hpp"
#include "LayerGeometry.hpp"

#include <algorithm>
#include <cmath>
#include <sstream>
#include <utility>
#include <hyprland/src/desktop/Workspace.hpp>
#include <GLES3/gl32.h>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprutils/math/Misc.hpp>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <vector>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

static CBox transformedLayerBox(CBox pixelBox, PHLMONITOR monitor) {
    const auto transform = Math::wlTransformToHyprutils(Math::invertTransform(monitor->m_transform));
    pixelBox.transform(transform, monitor->m_transformedSize.x, monitor->m_transformedSize.y).noNegativeSize().round();
    return pixelBox;
}

CGlassLayerSurface::CGlassLayerSurface(PHLLS layerSurface)
    : m_layerSurface(layerSurface) {
}

CGlassLayerSurface::~CGlassLayerSurface() {
    // Damage the area where glass was last drawn so the compositor
    // re-renders it without the glass effect (prevents ghost artifacts).
    if (g_pHyprRenderer && m_lastSize.x > 0 && m_lastSize.y > 0 &&
        std::isfinite(m_lastPosition.x) && std::isfinite(m_lastPosition.y) &&
        std::isfinite(m_lastSize.x) && std::isfinite(m_lastSize.y)) {
        auto box = CBox{m_lastPosition, m_lastSize};
        box.expand(GlassRenderer::SAMPLE_PADDING_PX).noNegativeSize();
        if (box.w > 0.0 && box.h > 0.0)
            g_pHyprRenderer->damageBox(box);
    }
}

bool CGlassLayerSurface::resolveThemeIsDark() const {
    try {
        const auto& config = g_pGlobalState->config;
        const auto theme = readStringConfig(config.defaultTheme);
        if (!theme.empty())
            return theme != "light";
    } catch (...) {}

    return true;
}

std::string CGlassLayerSurface::resolvePresetName() const {
    try {
        // Per-namespace preset override (highest priority)
        const auto layerSurface = m_layerSurface.lock();
        if (layerSurface) {
            const auto& nsPresets = g_pGlobalState->layerNamespacePresets;
            auto it = nsPresets.find(layerSurface->m_namespace);
            if (it != nsPresets.end())
                return it->second;
        }

        const auto& config = g_pGlobalState->config;

        // Layer-wide preset override
        const auto layerPreset = readStringConfig(config.layersPreset);
        if (!layerPreset.empty())
            return std::string(layerPreset);

        // Fall back to global default preset
        const auto defaultPreset = readStringConfig(config.defaultPreset);
        if (!defaultPreset.empty())
            return std::string(defaultPreset);
    } catch (...) {}

    return "default";
}

PHLLS CGlassLayerSurface::getLayerSurface() const {
    return m_layerSurface.lock();
}

void CGlassLayerSurface::damageIfMoved() {
    const auto layerSurface = m_layerSurface.lock();
    if (!layerSurface)
        return;

    const auto currentPosition = layerSurface->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    const auto currentSize     = layerSurface->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    if (currentSize.x <= 0.0 || currentSize.y <= 0.0 ||
        !std::isfinite(currentPosition.x) || !std::isfinite(currentPosition.y) ||
        !std::isfinite(currentSize.x) || !std::isfinite(currentSize.y))
        return;

    const bool isAnimating = layerSurface->positionAnimation()->isBeingAnimated() ||
                             layerSurface->sizeAnimation()->isBeingAnimated() ||
                             layerSurface->alpha()[Desktop::View::LS_ALPHA_FADE]->isBeingAnimated() ||
                             !layerSurface->m_mapped;

    const bool moved = currentPosition != m_lastPosition || currentSize != m_lastSize;

    if (moved || isAnimating) {
        m_lastPosition  = currentPosition;
        m_lastSize      = currentSize;

        auto box = CBox{currentPosition, currentSize};
        const auto monitor = layerSurface->m_monitor.lock();
        const float scale = monitor ? monitor->m_scale : 1.0f;
        box.expand(GlassRenderer::SAMPLE_PADDING_PX / scale).noNegativeSize();
        if (box.w > 0.0 && box.h > 0.0)
            g_pHyprRenderer->damageBox(box);

        if (monitor)
            g_pGlobalState->bumpSceneGeneration(monitor);
    }
}

void CGlassLayerSurface::sampleAndRedirect(PHLMONITOR monitor, float alpha) {
    auto& shaderManager = g_pGlobalState->shaderManager;
    shaderManager.initializeIfNeeded();

    if (!shaderManager.isInitialized())
        return;

    const auto layerSurface = m_layerSurface.lock();
    if (!layerSurface)
        return;

    auto source = g_pHyprRenderer->m_renderData.currentFB;
    if (!source)
        return;

    auto layerBox = LayerGeometry::computeLayerBox(layerSurface, monitor);
    if (!layerBox)
        return;
    if (layerBox->w < 1000 || layerBox->h < 500) {
        return;
    }

    CBox transformBox = transformedLayerBox(*layerBox, monitor);

    uint64_t currentGeneration = g_pGlobalState->getSceneGeneration(monitor);
    const auto activeWs = monitor->m_activeWorkspace;
    const bool layerAnim = layerSurface->positionAnimation()->isBeingAnimated() ||
                           layerSurface->sizeAnimation()->isBeingAnimated() ||
                           layerSurface->alpha()[Desktop::View::LS_ALPHA_FADE]->isBeingAnimated();
    const bool wsAnim = activeWs && activeWs->m_renderOffset->isBeingAnimated();
    const bool isAnimating = layerAnim || wsAnim;
    // Wallpaper-aware caching: bump when wallpaper file changes (awww daemon not a window)
    static std::filesystem::file_time_type lastWallpaperTime = std::filesystem::file_time_type::min();
    bool wallpaperChanged = false;
    try {
        auto wp = std::filesystem::last_write_time("/home/nicerice/.cache/current_wallpaper");
        if (wp != lastWallpaperTime) {
            lastWallpaperTime = wp;
            wallpaperChanged = true;
            // bump generation for this monitor to force resample
            g_pGlobalState->bumpSceneGeneration(monitor);
            currentGeneration = g_pGlobalState->getSceneGeneration(monitor);
        }
    } catch (...) {}
    const bool backgroundChanged = wallpaperChanged || !m_hasCachedSample ||
                                   currentGeneration != m_lastSceneGeneration ||
                                   isAnimating;

    bool didSample = false;
    int downscaleUsed = 1;
    std::chrono::high_resolution_clock::time_point t0, t1, t2;
    t2 = t1 = t0 = std::chrono::high_resolution_clock::now();
    if (!layerSurface->m_mapped) {
        if (!m_hasCachedSample)
            return;
    } else if (backgroundChanged) {
        // Data-only: sample background without blur (perfect shader does blur). Keep cache per scene generation.
        downscaleUsed = 2; // downscale for perf, shader will handle via screenSize*downscale

        t0 = std::chrono::high_resolution_clock::now();
        GlassRenderer::sampleBackground(m_sampleFramebuffer, source, transformBox, m_samplePaddingRatio, downscaleUsed);
        t1 = std::chrono::high_resolution_clock::now();
        t2 = t1; // no blur

        m_hasCachedSample      = true;
        m_lastSceneGeneration  = currentGeneration;
        didSample = true;
    }
    // For cached case, we still need to export if file not yet written this generation
    bool needExport = didSample || (m_lastExportedGen != (int)currentGeneration);
    if (!needExport && m_hasCachedSample)
        return;
    if (!m_sampleFramebuffer || !m_hasCachedSample)
        return;

    // Export blurred sample to file for Quickshell widgets (image data only, our shader does visuals)
    // Use per-layer file keyed by namespace + y position (bar 22, dock 120, overlay)
    // This keeps QML simple: bar watches /tmp/lucid_bar.png, dock watches /tmp/lucid_dock.png
    try {
        // Distinguish by layer type and size: bar TOP 0,22 1600x878 (1404px h), dock TOP 0,120 1600x780 (1248px), global OVERLAY 0,0 1600x900 (1440px)
        // Use scaled pixel box to determine correct file, not just y (which is scaled)
        int y = (int)std::round(layerBox->y);
        int h = (int)std::round(layerBox->h);
        int w = (int)std::round(layerBox->w);
        // m_layer: 0=background,1=bottom,2=top,3=overlay (zwlr)
        uint32_t layer = layerSurface->m_layer;

        std::string baseName;
        if (layer == 2) { // TOP
            if (h > 1300) baseName = "lucid_bar";
            else baseName = "lucid_dock";
        } else if (layer == 3) { // OVERLAY
            if (y == 0 && h > 1000) baseName = "lucid_capture"; // global 0,0 full monitor
            else baseName = "lucid_launcher";
        } else {
            return;
        }
        // Include monitor name to support multi-monitor
        std::string monName = monitor ? std::string(monitor->m_name) : "unknown";
        std::string pngPath = "/tmp/" + baseName + "_" + monName + ".png";
        std::string metaPath = "/tmp/" + baseName + "_" + monName + ".json";
        std::string tmpPng = pngPath + ".tmp"; // bmp still .png.tmp

        auto t3 = std::chrono::high_resolution_clock::now();
        int sw = (int)m_sampleFramebuffer->m_size.x;
        int sh = (int)m_sampleFramebuffer->m_size.y;
        if (sw <= 0 || sh <= 0) return;
        // Read pixels from sample framebuffer (already blurred)
        std::vector<unsigned char> pixels(sw * sh * 4);
        GLuint fbid = dynamic_cast<Render::GL::CGLFramebuffer*>(m_sampleFramebuffer.get())->getFBID();
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbid);
        glReadPixels(0, 0, sw, sh, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
        glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
        // Restore currentFB binding (blurBackground already restored caller FB, but ensure)
        GLuint curFbid = dynamic_cast<Render::GL::CGLFramebuffer*>(source.get())->getFBID();
        glBindFramebuffer(GL_FRAMEBUFFER, curFbid);
        // No flip: Hyprland monitor FB is already top-left for QML (flip inverts wallpaper)
        auto t4 = std::chrono::high_resolution_clock::now();
        // Dead export: nothing consumes lucid_launcher_* (no QML or config
        // references anywhere). Skip the pixels entirely; still mark exported
        // so this stays one-and-done per generation instead of retrying.
        if (baseName == "lucid_launcher") {
            m_lastExportedGen = (int)currentGeneration;
            return;
        }
        // Hand pixels to the background encoder. The render thread only paid
        // sample + glReadPixels (~2ms); PNG encoding (~75ms) no longer blocks
        // compositing. Newest-wins per path, identical bytes on disk.
        {
            double fullW = layerBox->w + 2 * GlassRenderer::SAMPLE_PADDING_PX;
            double fullH = layerBox->h + 2 * GlassRenderer::SAMPLE_PADDING_PX;
            double padRatioX = GlassRenderer::SAMPLE_PADDING_PX / fullW;
            double padRatioY = GlassRenderer::SAMPLE_PADDING_PX / fullH;
            std::ostringstream meta;
            meta << "{\"monitor\":\"" << monName << "\",\"y\":" << y << ",\"w\":" << (int)layerBox->w << ",\"h\":" << (int)layerBox->h;
            meta << ",\"fullW\":" << (int)fullW << ",\"fullH\":" << (int)fullH;
            meta << ",\"pad\":" << GlassRenderer::SAMPLE_PADDING_PX << ",\"downscale\":" << downscaleUsed;
            meta << ",\"sampleW\":" << sw << ",\"sampleH\":" << sh;
            meta << ",\"padRatioX\":" << padRatioX << ",\"padRatioY\":" << padRatioY;
            meta << ",\"boxX\":" << (int)layerBox->x << ",\"boxY\":" << y << "}";
            CExportJob job;
            job.pngPath = pngPath;
            job.pngTmp = tmpPng;
            job.metaPath = metaPath;
            job.metaTmp = metaPath + ".tmp";
            job.metaJson = meta.str();
            job.pixels = std::move(pixels);
            job.sw = sw;
            job.sh = sh;
            job.downscaleUsed = downscaleUsed;
            // NOTE: the legacy perf log's "xy=" has always carried (y,h), not
            // (x,y) — preserved here so the log stays comparable.
            job.boxX = y;
            job.boxY = h;
            job.sampleUs = std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count();
            job.readUs = std::chrono::duration_cast<std::chrono::microseconds>(t4 - t3).count();
            exportWorker().enqueue(pngPath, std::move(job));
            m_lastExportedGen = (int)currentGeneration;
        }
    } catch (...) {}
}

void CGlassLayerSurface::compositeAndRestore(PHLMONITOR monitor, float alpha) {
    // No-op: we only capture background for Quickshell widgets.
    // Quickshell's liquidglass_true.frag does the visuals (superior shader).
    // Keep for compatibility with hyprglass hook (called after original renderLayer).
    (void)monitor;
    (void)alpha;
}

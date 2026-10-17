#include "ExportWorker.hpp"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <utility>

// Declarations only here — the implementation is compiled once via
// GlassLayerSurface.cpp (STB_IMAGE_WRITE_IMPLEMENTATION lives there).
#include "stb_image_write.h"

CExportWorker& exportWorker() {
    static CExportWorker instance;
    return instance;
}

void CExportWorker::start() {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (m_started)
        return;
    m_started = true;
    m_running = true;
    m_thread = std::thread(&CExportWorker::threadMain, this);
}

void CExportWorker::stop() {
    {
        std::lock_guard<std::mutex> lk(m_mutex);
        if (!m_started)
            return;
        m_running = false;
    }
    m_cv.notify_all();
    if (m_thread.joinable())
        m_thread.join();
    m_started = false;
}

void CExportWorker::enqueue(std::string key, CExportJob job) {
    {
        std::lock_guard<std::mutex> lk(m_mutex);
        if (!m_running)
            return;
        m_pending[std::move(key)] = std::move(job);
    }
    m_cv.notify_one();
}

void CExportWorker::threadMain() {
    // Worker-owned from here on; the render thread no longer touches it.
    stbi_write_png_compression_level = 1;

    while (true) {
        std::map<std::string, CExportJob> batch;
        {
            std::unique_lock<std::mutex> lk(m_mutex);
            m_cv.wait(lk, [&] { return !m_running || !m_pending.empty(); });
            if (!m_running && m_pending.empty())
                return;
            batch.swap(m_pending);
        }
        for (auto& [key, job] : batch) {
            const auto t0 = std::chrono::high_resolution_clock::now();
            const bool ok = stbi_write_png(job.pngTmp.c_str(), job.sw, job.sh, 4, job.pixels.data(), job.sw * 4) != 0;
            const auto t1 = std::chrono::high_resolution_clock::now();
            if (ok) {
                std::error_code ec;
                std::filesystem::rename(job.pngTmp, job.pngPath, ec);
                {
                    std::ofstream mf(job.metaTmp, std::ios::trunc);
                    mf << job.metaJson;
                }
                std::filesystem::rename(job.metaTmp, job.metaPath, ec);
            }
            // Same perf-log schema as the synchronous path (field order kept).
            const auto d_png = std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count();
            std::ofstream pf("/tmp/lucid_perf.log", std::ios::app);
            pf << "sample=" << job.sampleUs << "us blur=0us read=" << job.readUs << "us png=" << d_png << "us total="
               << (job.sampleUs + job.readUs + d_png) << "us sw=" << job.sw << " sh=" << job.sh << " downscale=" << job.downscaleUsed
               << " xy=" << job.boxX << "," << job.boxY << std::endl;
        }
    }
}

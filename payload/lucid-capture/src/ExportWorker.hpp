#pragma once

// Background PNG export for lucid capture data files.
//
// The render thread only samples + glReadPixels (~2ms), then hands pixels to
// this worker. PNG encoding (~75ms p50) and file writes happen off the render
// path, so a 4-file export burst no longer stalls compositing for ~300ms.
//
// Newest-wins per output path: if frames arrive faster than the encoder, stale
// intermediates are dropped and only the latest pixels hit disk. Pixel content
// is bit-identical to the synchronous path — same sample, same encoder,
// same compression level — so the QML side loses no accuracy, only latency.

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct CExportJob {
    std::string pngPath;
    std::string pngTmp;
    std::string metaPath;
    std::string metaTmp;
    std::string metaJson;
    std::vector<unsigned char> pixels;
    int sw = 0;
    int sh = 0;
    int downscaleUsed = 1;
    int boxX = 0;
    int boxY = 0;
    long long sampleUs = 0;
    long long readUs = 0;
};

class CExportWorker {
  public:
    void start();
    void stop();
    // Overwrites any still-queued job for the same path (newest wins).
    void enqueue(std::string key, CExportJob job);

  private:
    void threadMain();

    std::mutex m_mutex;
    std::condition_variable m_cv;
    std::map<std::string, CExportJob> m_pending;
    std::thread m_thread;
    bool m_running = false;
    bool m_started = false;
};

CExportWorker& exportWorker();

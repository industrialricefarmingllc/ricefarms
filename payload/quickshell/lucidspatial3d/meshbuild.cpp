#include "meshbuild.h"

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#if __has_include(<opencv2/geometry/2d.hpp>)
#include <opencv2/geometry/2d.hpp>
#endif

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMutex>
#include <QMutexLocker>
#include <QSaveFile>
#include <QStandardPaths>
#include <QDebug>

namespace {
constexpr int columns = 321;
constexpr int rows = 181;
// 4 subdivisions still put a vertex every ~1.3 px on a 1080p output and every
// ~2.7 px on a 4K output. 8 was visually identical, but every refined cell
// carried four times the triangles and the cache files reached 30-80 MB.
constexpr int edgeRefinement = 4;
constexpr int fineColumns = (columns - 1) * edgeRefinement + 1;
constexpr int fineRows = (rows - 1) * edgeRefinement + 1;
constexpr double farDistance = 3.3;
constexpr double depthSpan = 1.3;
constexpr double foregroundDepthScale = 0.55;
constexpr double backgroundDepthScale = 1.45;
constexpr double fovDegrees = 42.0;
constexpr double refinementThreshold = 0.08;

struct Vertex { float x, y, z, u, v; };

// Bumped with the geometry constants. A reader that sees an older magic or
// version rebuilds instead of loading a mesh from the previous refinement.
constexpr char diskMagic[8] = {'L', 'U', 'C', 'I', 'D', 'M', '2', '\0'};
constexpr quint32 diskVersion = 2;

struct DiskHeader {
    char magic[8];
    quint32 version;
    quint32 stride;
    quint64 vertices;
    float minX, minY, minZ;
    float maxX, maxY, maxZ;
    float focus;
    float background;
};

QString cacheDir() {
    QString base = qEnvironmentVariable("XDG_CACHE_HOME");
    if (base.isEmpty())
        base = QDir::homePath() + "/.cache";
    const QString dir = base + "/liquid-shell/meshes";
    QDir().mkpath(dir);
    return dir;
}

cv::Mat cropAndResize(const cv::Mat &input, double aspect,
                      int targetWidth, int targetHeight)
{
    const double sourceAspect = static_cast<double>(input.cols) / input.rows;
    cv::Rect crop(0, 0, input.cols, input.rows);
    if (sourceAspect > aspect) {
        crop.width = static_cast<int>(std::lround(input.rows * aspect));
        crop.x = (input.cols - crop.width) / 2;
    } else {
        crop.height = static_cast<int>(std::lround(input.cols / aspect));
        crop.y = (input.rows - crop.height) / 2;
    }
    cv::Mat resized;
    cv::resize(input(crop), resized, {targetWidth, targetHeight},
               0, 0, cv::INTER_LINEAR);
    return resized;
}
} // namespace

QString meshCacheKey(const QString &depthFile, const QString &matteFile,
                     float imageZoom, float outputAspect, float sourceAspect,
                     bool foreground)
{
    const QFileInfo depthInfo(depthFile);
    const QFileInfo matteInfo(matteFile);
    return QStringLiteral("%1|%2|%3|%4|%5|%6|%7|%8|%9|%10")
        .arg(depthFile, matteFile)
        .arg(depthInfo.size()).arg(depthInfo.lastModified().toMSecsSinceEpoch())
        .arg(matteInfo.size()).arg(matteInfo.lastModified().toMSecsSinceEpoch())
        .arg(imageZoom, 0, 'f', 6).arg(outputAspect, 0, 'f', 6)
        .arg(sourceAspect, 0, 'f', 6).arg(foreground ? 1 : 0);
}

QString meshDiskPath(const QString &cacheKey)
{
    const QByteArray digest = QCryptographicHash::hash(
        cacheKey.toUtf8(), QCryptographicHash::Sha256).toHex();
    return cacheDir() + "/" + QString::fromLatin1(digest) + ".mesh";
}

bool readMeshCache(const QString &cacheKey, MeshBuildResult *result)
{
    if (!result)
        return false;
    QFile file(meshDiskPath(cacheKey));
    if (!file.open(QIODevice::ReadOnly))
        return false;
    DiskHeader header{};
    if (file.read(reinterpret_cast<char *>(&header), sizeof(header)) != qint64(sizeof(header)))
        return false;
    if (std::memcmp(header.magic, diskMagic, sizeof(diskMagic)) != 0
            || header.version != diskVersion || header.stride != sizeof(Vertex)
            || header.vertices == 0)
        return false;
    const qint64 expected = qint64(header.vertices) * qint64(sizeof(Vertex));
    if (file.size() != qint64(sizeof(header)) + expected)
        return false;
    result->vertices = file.read(expected);
    if (result->vertices.size() != expected)
        return false;
    result->minimum = QVector3D(header.minX, header.minY, header.minZ);
    result->maximum = QVector3D(header.maxX, header.maxY, header.maxZ);
    result->focusDistance = header.focus;
    result->backgroundDistance = header.background;
    result->triangles = int(header.vertices / 3);
    result->refinedCells = 0;
    result->ok = true;
    return true;
}

void trimMeshCache(bool force)
{
    // Two geometry instances (background and foreground) can finish at the
    // same time now that builds run off the GUI thread.
    static QMutex trimMutex;
    QMutexLocker trimLock(&trimMutex);
    static qint64 lastTrim = 0;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (!force && now - lastTrim < 60000)
        return;
    lastTrim = now;

    qint64 limit = 2048LL * 1024 * 1024;
    bool ok = false;
    const qint64 envMb = qEnvironmentVariableIntValue("LUCID_MESH_CACHE_MB", &ok);
    if (ok && envMb > 0)
        limit = envMb * 1024 * 1024;

    QDir dir(cacheDir());
    QFileInfoList files = dir.entryInfoList({"*.mesh"}, QDir::Files, QDir::Time);
    qint64 total = 0;
    for (const QFileInfo &info : files)
        total += info.size();
    // Oldest first: entryInfoList sorts newest first.
    for (int i = files.size() - 1; i >= 0 && total > limit; --i) {
        total -= files[i].size();
        QFile::remove(files[i].absoluteFilePath());
    }
}

bool writeMeshCache(const QString &cacheKey, const MeshBuildResult &result)
{
    if (!result.ok || result.vertices.isEmpty())
        return false;
    DiskHeader header{};
    std::memcpy(header.magic, diskMagic, sizeof(diskMagic));
    header.version = diskVersion;
    header.stride = sizeof(Vertex);
    header.vertices = quint64(result.vertices.size() / sizeof(Vertex));
    header.minX = result.minimum.x();
    header.minY = result.minimum.y();
    header.minZ = result.minimum.z();
    header.maxX = result.maximum.x();
    header.maxY = result.maximum.y();
    header.maxZ = result.maximum.z();
    header.focus = result.focusDistance;
    header.background = result.backgroundDistance;

    QSaveFile file(meshDiskPath(cacheKey));
    if (!file.open(QIODevice::WriteOnly))
        return false;
    if (file.write(reinterpret_cast<const char *>(&header), sizeof(header)) != qint64(sizeof(header))
            || file.write(result.vertices) != result.vertices.size()) {
        file.cancelWriting();
        return false;
    }
    if (!file.commit())
        return false;
    trimMeshCache();
    return true;
}

MeshBuildResult buildDepthMesh(const QString &depthFile, const QString &matteFile,
                               float imageZoom, float outputAspect,
                               float sourceAspect, bool foreground)
{
    MeshBuildResult result;
    const cv::Mat rawDepth = cv::imread(depthFile.toStdString(),
                                        cv::IMREAD_UNCHANGED);
    const cv::Mat rawMatte = cv::imread(matteFile.toStdString(),
                                        cv::IMREAD_GRAYSCALE);
    if (rawDepth.empty() || rawDepth.type() != CV_16UC1 || rawMatte.empty())
        return result;
    const cv::Mat sourceDepth = cropAndResize(rawDepth, outputAspect,
                                              fineColumns, fineRows);
    const cv::Mat matte = cropAndResize(rawMatte, outputAspect,
                                        fineColumns, fineRows);
    const float pivotDepth = sourceDepth.at<std::uint16_t>(fineRows / 2, fineColumns / 2)
        / 65535.0f;
    // The mesh carries the reconstructed background. Fill the removed subject's
    // depth with a far value so its original near depth cannot pull background
    // pixels forward through the separate high-resolution foreground cutout.
    std::array<size_t, 256> backgroundHistogram{};
    size_t backgroundSamples = 0;
    for (int y = 0; y < fineRows; y += edgeRefinement) {
        for (int x = 0; x < fineColumns; x += edgeRefinement) {
            if (matte.at<std::uint8_t>(y, x) > 12) continue;
            ++backgroundHistogram[sourceDepth.at<std::uint16_t>(y, x) >> 8];
            ++backgroundSamples;
        }
    }
    double backgroundDepth = std::max(0.05, static_cast<double>(pivotDepth) * 0.5);
    size_t cumulative = 0;
    for (int bin = 0; bin < 256 && backgroundSamples > 0; ++bin) {
        cumulative += backgroundHistogram[bin];
        if (cumulative >= backgroundSamples / 5) {
            backgroundDepth = (bin + 0.5) / 256.0;
            break;
        }
    }
    cv::Mat expandedMatte;
    cv::threshold(matte, expandedMatte, 24, 255, cv::THRESH_BINARY);
    cv::dilate(expandedMatte, expandedMatte,
        cv::getStructuringElement(cv::MORPH_ELLIPSE, {15, 15}));
    cv::GaussianBlur(expandedMatte, expandedMatte, {}, 3.0);
    cv::Mat depth = sourceDepth.clone();
    if (foreground) {
        // Continue subject depth beyond the matte so transparent boundary
        // triangles cannot bend towards the original far background. The
        // high-resolution matte, rather than mesh topology, clips the outline.
        cv::Mat outside = matte <= 16;
        if (cv::countNonZero(outside) == static_cast<int>(outside.total()))
            return result;
        cv::Mat distance, labels;
        cv::distanceTransform(outside, distance, labels, cv::DIST_L2,
                              5, cv::DIST_LABEL_PIXEL);
        double maximumLabel = 0;
        cv::minMaxLoc(labels, nullptr, &maximumLabel);
        std::vector<std::uint16_t> nearestDepth(static_cast<size_t>(maximumLabel) + 1);
        for (int y = 0; y < fineRows; ++y) for (int x = 0; x < fineColumns; ++x) {
            if (!outside.at<std::uint8_t>(y, x))
                nearestDepth[labels.at<int>(y, x)] = sourceDepth.at<std::uint16_t>(y, x);
        }
        for (int y = 0; y < fineRows; ++y) for (int x = 0; x < fineColumns; ++x) {
            if (outside.at<std::uint8_t>(y, x))
                depth.at<std::uint16_t>(y, x) = nearestDepth[labels.at<int>(y, x)];
        }
        cv::GaussianBlur(depth, depth, {}, 3.0);
    } else for (int y = 0; y < fineRows; ++y) {
        auto *depthRow = depth.ptr<std::uint16_t>(y);
        const auto *matteRow = expandedMatte.ptr<std::uint8_t>(y);
        for (int x = 0; x < fineColumns; ++x) {
            const double weight = matteRow[x] / 255.0;
            depthRow[x] = static_cast<std::uint16_t>(std::lround(
                depthRow[x] * (1.0 - weight) + backgroundDepth * 65535.0 * weight));
        }
    }
    const double pivotDistance = farDistance - pivotDepth * depthSpan;
    const auto distanceAtDepth = [pivotDepth, pivotDistance, foreground](double value) {
        if (foreground)
            return pivotDistance - (value - pivotDepth) * depthSpan * foregroundDepthScale;
        if (value >= pivotDepth)
            return pivotDistance - (value - pivotDepth) * depthSpan * foregroundDepthScale;
        return pivotDistance + (pivotDepth - value) * depthSpan * backgroundDepthScale;
    };
    result.focusDistance = static_cast<float>(pivotDistance);

    const double tangent = std::tan(fovDegrees * CV_PI / 360.0);
    const double aspect = outputAspect;
    const double cropU = std::min(1.0, aspect / sourceAspect);
    const double cropV = std::min(1.0, sourceAspect / aspect);
    const double offsetU = (1.0 - cropU) * 0.5;
    const double offsetV = (1.0 - cropV) * 0.5;
    std::array<Vertex, columns * rows> vertices{};
    double maximumDistance = 0.0;
    float minX = std::numeric_limits<float>::max(), minY = minX, minZ = minX;
    float maxX = std::numeric_limits<float>::lowest(), maxY = maxX, maxZ = maxX;
    auto sampleDepth = [&depth](int x, int y) {
        return depth.at<std::uint16_t>(y, x) / 65535.0;
    };
    auto makeVertex = [&](int x, int y) {
        const double u = static_cast<double>(x) / (fineColumns - 1);
        const double v = static_cast<double>(y) / (fineRows - 1);
        const double z = distanceAtDepth(sampleDepth(x, y));
        maximumDistance = std::max(maximumDistance, z);
        const Vertex vertex {
            static_cast<float>((u * 2 - 1) * imageZoom * z * tangent * aspect),
            static_cast<float>((1 - v * 2) * imageZoom * z * tangent),
            static_cast<float>(-z),
            static_cast<float>(offsetU + u * cropU),
            static_cast<float>(1.0 - offsetV - v * cropV)
        };
        minX = std::min(minX, vertex.x); minY = std::min(minY, vertex.y);
        minZ = std::min(minZ, vertex.z);
        maxX = std::max(maxX, vertex.x); maxY = std::max(maxY, vertex.y);
        maxZ = std::max(maxZ, vertex.z);
        return vertex;
    };
    for (int y = 0; y < rows; ++y) {
        for (int x = 0; x < columns; ++x) {
            const int sampleX = x * edgeRefinement;
            const int sampleY = y * edgeRefinement;
            const size_t index = static_cast<size_t>(y) * columns + x;
            vertices[index] = makeVertex(sampleX, sampleY);
        }
    }

    std::vector<Vertex> triangles;
    triangles.reserve(static_cast<size_t>(columns - 1) * (rows - 1) * 6);
    int refinedCells = 0;
    auto appendTriangle = [&](const Vertex &a, const Vertex &b, const Vertex &c) {
        triangles.insert(triangles.end(), {a, b, c});
    };
    for (int y = 0; y + 1 < rows; ++y) for (int x = 0; x + 1 < columns; ++x) {
        const int tl = y * columns + x, tr = tl + 1, bl = tl + columns, br = bl + 1;
        const int fineX = x * edgeRefinement;
        const int fineY = y * edgeRefinement;
        double cellMin = 1.0, cellMax = 0.0;
        int maximumAlpha = 0;
        for (int sy = 0; sy <= edgeRefinement; ++sy) {
            for (int sx = 0; sx <= edgeRefinement; ++sx) {
                const double value = sampleDepth(fineX + sx, fineY + sy);
                cellMin = std::min(cellMin, value);
                cellMax = std::max(cellMax, value);
                maximumAlpha = std::max(maximumAlpha,
                    static_cast<int>(matte.at<std::uint8_t>(fineY + sy, fineX + sx)));
            }
        }
        if (foreground && maximumAlpha == 0) continue;
        if (cellMax - cellMin <= refinementThreshold) {
            appendTriangle(vertices[tl], vertices[bl], vertices[tr]);
            appendTriangle(vertices[tr], vertices[bl], vertices[br]);
            continue;
        }
        ++refinedCells;

        constexpr int patchSize = edgeRefinement + 1;
        std::array<Vertex, patchSize * patchSize> patchVertices;
        for (int sy = 0; sy < patchSize; ++sy) {
            for (int sx = 0; sx < patchSize; ++sx) {
                const int index = sy * patchSize + sx;
                patchVertices[index] = makeVertex(fineX + sx, fineY + sy);
            }
        }
        for (int sy = 0; sy < edgeRefinement; ++sy) {
            for (int sx = 0; sx < edgeRefinement; ++sx) {
                const int a = sy * patchSize + sx;
                const int b = a + 1;
                const int c = a + patchSize;
                const int d = c + 1;
                appendTriangle(patchVertices[a], patchVertices[c], patchVertices[b]);
                appendTriangle(patchVertices[b], patchVertices[c], patchVertices[d]);
            }
        }
    }
    if (triangles.empty())
        return result;
    result.vertices = QByteArray(reinterpret_cast<const char *>(triangles.data()),
        static_cast<qsizetype>(triangles.size() * sizeof(Vertex)));
    result.minimum = QVector3D(minX, minY, minZ);
    result.maximum = QVector3D(maxX, maxY, maxZ);
    result.backgroundDistance = static_cast<float>(maximumDistance + 0.25);
    result.triangles = int(triangles.size() / 3);
    result.refinedCells = refinedCells;
    result.ok = true;
    return result;
}

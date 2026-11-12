#include "depthmeshgeometry.h"
#include "meshbuild.h"

#include <QElapsedTimer>
#include <QFileInfo>
#include <QHash>
#include <QMutex>
#include <QMutexLocker>
#include <QPointer>
#include <QDebug>
#include <QStringList>
#include <QUrl>
#include <QtConcurrent/QtConcurrentRun>

#include <algorithm>
#include <cmath>

namespace {
struct MeshCacheEntry {
    QByteArray vertices;
    QByteArray indices;
    QVector3D minimum;
    QVector3D maximum;
    float focusDistance = 0.0f;
    float backgroundDistance = 0.0f;
};

// The same depth/matte pair is requested by the background mesh, the subject
// mesh, the per-screen copies and the widget foreground. Share the expensive
// vertex build: identical outputs are then a memory copy, not a second decode
// plus a rebuild.
QHash<QString, MeshCacheEntry> g_meshCache;
// Least-recently-used order for the in-memory mesh cache. The old policy wiped
// all eight entries when a ninth arrived, so revisiting any wallpaper after a
// picker sweep paid the disk read and upload again.
QStringList g_meshCacheOrder;
QMutex g_meshCacheMutex;

QString localPath(const QUrl &url)
{
    const QString path = url.isLocalFile() ? url.toLocalFile()
        : url.scheme().isEmpty() ? url.path(QUrl::FullyDecoded) : QString();
    return QFileInfo(path).isAbsolute() ? path : QString();
}
} // namespace

DepthMeshGeometry::DepthMeshGeometry(QQuick3DObject *parent)
    : QQuick3DGeometry(parent)
{
    setStride(sizeof(float) * 5);
    setPrimitiveType(PrimitiveType::Triangles);
    addAttribute(Attribute::PositionSemantic, 0, Attribute::F32Type);
    addAttribute(Attribute::TexCoord0Semantic, sizeof(float) * 3, Attribute::F32Type);
    // The mesh is indexed (UInt32); without this attribute Qt ignores the
    // index buffer and draws the deduplicated vertex buffer as loose points.
    addAttribute(Attribute::IndexSemantic, 0, Attribute::U32Type);
    m_rebuildTimer.setSingleShot(true);
    connect(&m_rebuildTimer, &QTimer::timeout, this, &DepthMeshGeometry::startBuild);
}

void DepthMeshGeometry::setDepthPath(const QUrl &path)
{
    if (m_depthPath == path) return;
    m_depthPath = path;
    emit depthPathChanged();
    rebuild();
}

void DepthMeshGeometry::setMattePath(const QUrl &path)
{
    if (m_mattePath == path) return;
    m_mattePath = path;
    emit mattePathChanged();
    rebuild();
}

void DepthMeshGeometry::setImageZoom(float zoom)
{
    const float bounded = std::clamp(zoom, 1.0f, 1.5f);
    if (std::abs(m_imageZoom - bounded) < 1e-5f) return;
    m_imageZoom = bounded;
    emit imageZoomChanged();
    rebuild();
}

void DepthMeshGeometry::setOutputAspect(float aspect)
{
    const float bounded = std::clamp(aspect, 0.5f, 4.0f);
    if (std::abs(m_outputAspect - bounded) < 1e-5f) return;
    m_outputAspect = bounded;
    emit outputAspectChanged();
    rebuild();
}

void DepthMeshGeometry::setSourceAspect(float aspect)
{
    const float bounded = std::clamp(aspect, 0.01f, 100.0f);
    if (std::abs(m_sourceAspect - bounded) < 1e-5f) return;
    m_sourceAspect = bounded;
    emit sourceAspectChanged();
    rebuild();
}

void DepthMeshGeometry::setValid(bool valid)
{
    if (m_valid == valid) return;
    m_valid = valid;
    emit validChanged();
}

void DepthMeshGeometry::setForeground(bool foreground)
{
    if (m_foreground == foreground) return;
    m_foreground = foreground;
    emit foregroundChanged();
    rebuild();
}

void DepthMeshGeometry::rebuild()
{
    ++m_generation;
    setValid(false);
    setVertexData({});
    setIndexData({});
    m_rebuildTimer.start(0);
}

void DepthMeshGeometry::startBuild()
{
    QElapsedTimer buildTimer;
    buildTimer.start();
    const quint64 generation = m_generation;
    const QString depthFile = localPath(m_depthPath);
    const QString matteFile = localPath(m_mattePath);
    if (depthFile.isEmpty() || matteFile.isEmpty()) return;
    const QString cacheKey = meshCacheKey(depthFile, matteFile, m_imageZoom,
        m_outputAspect, m_sourceAspect, m_foreground);
    {
        QMutexLocker locker(&g_meshCacheMutex);
        const auto cached = g_meshCache.constFind(cacheKey);
        if (cached != g_meshCache.constEnd()) {
            g_meshCacheOrder.removeAll(cacheKey);
            g_meshCacheOrder.append(cacheKey);
            setVertexData(cached->vertices);
            setIndexData(cached->indices);
            setBounds(cached->minimum, cached->maximum);
            m_focusDistance = cached->focusDistance;
            m_backgroundDistance = cached->backgroundDistance;
            emit focusDistanceChanged();
            emit backgroundDistanceChanged();
            setValid(true);
            update();
            qInfo().nospace() << "[Spatial3D] mesh cache hit: "
                << (m_foreground ? "foreground" : "background");
            return;
        }
    }

    // Decoding a depth map, running OpenCV and building 400k triangles on the
    // GUI thread used to block the iris and the apply for up to a second per
    // mesh (seconds on a low-power device). The disk read and the build both
    // run off the GUI thread; the result is applied only if it is still the
    // newest request, so the window and the reveal animation stay live.
    const float zoom = m_imageZoom;
    const float outputAspect = m_outputAspect;
    const float sourceAspect = m_sourceAspect;
    const bool foreground = m_foreground;
    QPointer<DepthMeshGeometry> self(this);
    QtConcurrent::run([self, generation, cacheKey, depthFile, matteFile,
                       zoom, outputAspect, sourceAspect, foreground, buildTimer]() {
        MeshBuildResult built;
        const bool fromDisk = readMeshCache(cacheKey, &built);
        if (!fromDisk)
            built = buildDepthMesh(depthFile, matteFile, zoom, outputAspect,
                                   sourceAspect, foreground);
        if (!built.ok || !self)
            return;

        MeshBuildResult result = built;
        const qint64 elapsed = buildTimer.elapsed();
        QMetaObject::invokeMethod(self.data(), [self, generation, cacheKey,
                                                result, fromDisk, elapsed]() {
            DepthMeshGeometry *geometry = self.data();
            if (!geometry || generation != geometry->m_generation)
                return;

            geometry->setVertexData(result.vertices);
            geometry->setIndexData(result.indices);
            geometry->setBounds(result.minimum, result.maximum);
            geometry->m_focusDistance = result.focusDistance;
            geometry->m_backgroundDistance = result.backgroundDistance;
            emit geometry->focusDistanceChanged();
            emit geometry->backgroundDistanceChanged();

            MeshCacheEntry entry;
            entry.vertices = result.vertices;
            entry.indices = result.indices;
            entry.minimum = result.minimum;
            entry.maximum = result.maximum;
            entry.focusDistance = result.focusDistance;
            entry.backgroundDistance = result.backgroundDistance;
            {
                QMutexLocker locker(&g_meshCacheMutex);
                while (g_meshCache.size() >= 8 && !g_meshCacheOrder.isEmpty()) {
                    const QString oldest = g_meshCacheOrder.takeFirst();
                    g_meshCache.remove(oldest);
                }
                g_meshCacheOrder.removeAll(cacheKey);
                g_meshCacheOrder.append(cacheKey);
                g_meshCache.insert(cacheKey, entry);
            }
            geometry->setValid(true);
            geometry->update();
            qInfo().nospace() << "[Spatial3D] "
                << (geometry->m_foreground ? "foreground" : "background")
                << (fromDisk ? " mesh from disk: " : " mesh ready: ")
                << result.triangles << " triangles, " << result.refinedCells
                << " refined cells, " << elapsed << " ms";
        }, Qt::QueuedConnection);

        if (!fromDisk)
            writeMeshCache(cacheKey, built);
    });
}

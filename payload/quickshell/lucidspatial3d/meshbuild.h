#pragma once

#include <QByteArray>
#include <QString>
#include <QVector3D>

// Shared depth-map mesh construction. Used by the QML geometry and by the
// offline cache builder, so both produce byte-identical vertex buffers.
struct MeshBuildResult {
    // Indexed triangle mesh. The vertex buffer is deduplicated across the
    // triangle soup (the same grid vertex is shared by up to six triangles),
    // so the cache file and the GPU upload are roughly 2.5-3x smaller than
    // the old three-vertices-per-triangle layout.
    QByteArray vertices;
    QByteArray indices;
    QVector3D minimum;
    QVector3D maximum;
    float focusDistance = 0.0f;
    float backgroundDistance = 0.0f;
    int triangles = 0;
    int refinedCells = 0;
    bool ok = false;
};

QString meshCacheKey(const QString &depthFile, const QString &matteFile,
                     float imageZoom, float outputAspect, float sourceAspect,
                     bool foreground);

// One file per key under ~/.cache/liquid-shell/meshes. Returns an empty
// string when no cache directory can be created.
QString meshDiskPath(const QString &cacheKey);

bool readMeshCache(const QString &cacheKey, MeshBuildResult *result);
bool writeMeshCache(const QString &cacheKey, const MeshBuildResult &result);

MeshBuildResult buildDepthMesh(const QString &depthFile, const QString &matteFile,
                               float imageZoom, float outputAspect,
                               float sourceAspect, bool foreground);

// Drops the oldest cache files until the directory is below the limit.
// LUCID_MESH_CACHE_MB overrides the default (2048 MB). `force` skips the
// one-minute throttle, for the CLI that writes a whole wallpaper at once.
void trimMeshCache(bool force = false);

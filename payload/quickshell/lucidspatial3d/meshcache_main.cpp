// Offline builder for the spatial mesh cache.
//
//   kos-mesh-cache --depth d.png --matte m.png --source-aspect 1.78 \
//                  --aspect 1.78 --aspect 1.6
//
// Writes one cache file per (aspect, background/foreground) so the renderer
// only has to read vertices instead of running OpenCV on a low-power device.

#include "meshbuild.h"

#include <QCommandLineParser>
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <cstdio>

static void emitJson(const QJsonObject &value)
{
    const QByteArray line = QJsonDocument(value).toJson(QJsonDocument::Compact);
    std::fwrite(line.constData(), 1, size_t(line.size()), stdout);
    std::fputc('\n', stdout);
    std::fflush(stdout);
}

static QJsonObject failure(const QString &message)
{
    return QJsonObject{{"ok", false}, {"error", message}};
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QCommandLineParser parser;
    parser.setApplicationDescription("Build the spatial mesh cache for one wallpaper.");
    parser.addHelpOption();
    parser.addOption({{"d", "depth"}, "Depth map PNG.", "path"});
    parser.addOption({{"m", "matte"}, "Matte PNG.", "path"});
    parser.addOption({{"z", "image-zoom"}, "Image zoom.", "zoom", "1.16"});
    parser.addOption({{"s", "source-aspect"}, "Source image aspect.", "aspect"});
    parser.addOption({{"a", "aspect"}, "Output aspect (repeatable).", "aspect"});
    parser.addOption({{"f", "foreground"}, "Only build the foreground mesh."});
    parser.addOption({{"b", "background"}, "Only build the background mesh."});
    parser.process(app);

    const QString depth = parser.value("depth");
    const QString matte = parser.value("matte");
    const QStringList aspects = parser.values("aspect");
    if (depth.isEmpty() || matte.isEmpty() || aspects.isEmpty()
            || parser.value("source-aspect").isEmpty()) {
        emitJson(failure("usage: --depth --matte --source-aspect --aspect"));
        return 2;
    }
    if (!QFileInfo::exists(depth) || !QFileInfo::exists(matte)) {
        emitJson(failure("depth or matte is missing"));
        return 2;
    }

    const float zoom = float(parser.value("image-zoom").toDouble());
    const float sourceAspect = float(parser.value("source-aspect").toDouble());
    const bool onlyForeground = parser.isSet("foreground");
    const bool onlyBackground = parser.isSet("background");

    for (const QString &text : aspects) {
        const float aspect = float(text.toDouble());
        for (int mode = 0; mode < 2; ++mode) {
            const bool foreground = mode == 1;
            if ((foreground && onlyBackground) || (!foreground && onlyForeground))
                continue;
            QElapsedTimer timer;
            timer.start();
            const QString key = meshCacheKey(depth, matte, zoom, aspect,
                                             sourceAspect, foreground);
            MeshBuildResult result;
            const bool cached = readMeshCache(key, &result);
            if (!cached) {
                result = buildDepthMesh(depth, matte, zoom, aspect,
                                        sourceAspect, foreground);
                if (!result.ok) {
                    emitJson(QJsonObject{{"ok", false},
                                     {"aspect", aspect},
                                     {"foreground", foreground},
                                     {"error", "mesh build failed"}});
                    continue;
                }
                if (!writeMeshCache(key, result)) {
                    emitJson(QJsonObject{{"ok", false},
                                     {"aspect", aspect},
                                     {"foreground", foreground},
                                     {"error", "could not write the mesh cache"}});
                    continue;
                }
            }
            emitJson(QJsonObject{{"ok", true},
                             {"aspect", aspect},
                             {"foreground", foreground},
                             {"cached", cached},
                             {"triangles", result.triangles},
                             {"ms", timer.elapsed()}});
        }
    }
    // One trim for the whole wallpaper, not one throttled attempt per file: a
    // sweep of several aspects could otherwise add hundreds of MB between
    // trims that the one-minute throttle skipped.
    trimMeshCache(true);
    return 0;
}

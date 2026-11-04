import QtQuick
import QtQuick3D
import qs
import Kos.Spatial3D 1.0

Item {
    id: root
    property bool foregroundOnly: false
    property url wallpaperPath
    property url depthPath
    property url backgroundPath
    property url mattePath
    property size textureSize: Qt.size(Math.max(1, width), Math.max(1, height))
    property real pointerX: 0
    property real pointerY: 0
    // Set while a focused client window freezes this surface. The mesh stays
    // loaded; only camera work and the view's paint pass stop.
    property bool animationPaused: false
    // set by SpatialSurface while the wallpaper under it changes
    property real fadeOpacity: 1
    property real outputAspect: width > 0 && height > 0 ? width / height : 16 / 9
    // The resolver already knows the poster size; using it avoids one mesh
    // rebuild when the QML Image finishes decoding.
    property real knownSourceAspect: 0
    // A VideoOutput / AnimatedImage / ShaderEffectSource for live video frames.
    // When set, the mesh samples the live frame instead of the poster file.
    property Item liveSource: null
    readonly property real imageZoom: 1.16
    readonly property real focusZ: -depthGeometry.focusDistance
    readonly property real foregroundTravel: 0.005
    readonly property vector2d boundedPointer: Qt.vector2d(
        Math.max(-1, Math.min(1, root.pointerX + SpatialShake.lookX)),
        Math.max(-1, Math.min(1, root.pointerY + SpatialShake.lookY)))
    readonly property real focusHalfHeight: depthGeometry.focusDistance
        * Math.tan(Math.PI * 42 / 360)
    readonly property real shakeScale: depthGeometry.focusDistance * SpatialShake.amplitude
    readonly property bool ready: depthGeometry.valid
        && foregroundGeometry.valid
        && (root.liveSource !== null || sourceInfo.status === Image.Ready)
        && (root.liveSource !== null || backgroundInfo.status === Image.Ready)
        && matteInfo.status === Image.Ready
    readonly property real sourceAspect: root.knownSourceAspect > 0
        ? root.knownSourceAspect
        : (sourceInfo.implicitHeight > 0
            ? sourceInfo.implicitWidth / sourceInfo.implicitHeight : outputAspect)
    readonly property vector2d cropScale: Qt.vector2d(
        Math.min(1, outputAspect / sourceAspect),
        Math.min(1, sourceAspect / outputAspect))

    Image {
        id: sourceInfo
        visible: false
        source: root.liveSource !== null ? "" : root.wallpaperPath
        autoTransform: true
        fillMode: Image.PreserveAspectCrop
        sourceSize: root.textureSize
        asynchronous: true
    }
    Image {
        id: backgroundInfo
        visible: false
        source: root.liveSource !== null ? "" : root.backgroundPath
        sourceSize: root.textureSize
        asynchronous: true
    }
    Image {
        id: matteInfo
        visible: false
        source: root.mattePath
        sourceSize: root.textureSize
        asynchronous: true
    }

    View3D {
        id: view
        anchors.fill: parent
        visible: root.ready
        camera: camera
        renderMode: View3D.Offscreen
        environment: SceneEnvironment {
            backgroundMode: SceneEnvironment.Transparent
            antialiasingMode: SceneEnvironment.MSAA
            antialiasingQuality: SceneEnvironment.Medium
        }

        PerspectiveCamera {
            id: camera
            fieldOfView: 42
            fieldOfViewOrientation: PerspectiveCamera.Vertical
            clipNear: 0.01
            clipFar: 100
            position: Qt.vector3d(0, 0, 0)
            Component.onCompleted: lookAt(Qt.vector3d(0, 0, root.focusZ))
        }

        Model {
            visible: !root.foregroundOnly && root.backgroundPath.toString().length > 0
            // Background is transparent (fade) and the subject is transparent,
            // so Qt sorts them by distance to their *bounds centre*: a scene
            // whose floor pulls the background centroid in front of the subject
            // makes the background paint last and erase it. Force the
            // background to sort behind the subject.
            depthBias: 2.0
            position: Qt.vector3d(0, 0, -depthGeometry.backgroundDistance)
            source: "#Rectangle"
            scale: Qt.vector3d(
                root.imageZoom * 2 * depthGeometry.backgroundDistance
                    * Math.tan(Math.PI * 42 / 360) * root.outputAspect / 100,
                root.imageZoom * 2 * depthGeometry.backgroundDistance
                    * Math.tan(Math.PI * 42 / 360) / 100, 1)
            materials: CustomMaterial {
                shadingMode: CustomMaterial.Unshaded
                cullMode: Material.NoCulling
                property real fade: root.fadeOpacity
                sourceBlend: CustomMaterial.One
                destinationBlend: CustomMaterial.OneMinusSrcAlpha
                vertexShader: Qt.resolvedUrl("lucidspatial3d/shaders/spatial_background.vert")
                fragmentShader: Qt.resolvedUrl("lucidspatial3d/shaders/spatial_background.frag")
                property TextureInput backgroundTexture: TextureInput {
                    texture: Texture {
                        source: root.liveSource !== null ? "" : root.backgroundPath
                        sourceItem: root.liveSource
                        minFilter: Texture.Linear
                        magFilter: Texture.Linear
                        tilingModeHorizontal: Texture.ClampToEdge
                        tilingModeVertical: Texture.ClampToEdge
                    }
                }
            }
        }

        Model {
            visible: !root.foregroundOnly
            // Same sort fix as the plane above: the depth mesh's bounds centre
            // can sit in front of the subject's (a near floor drags it there),
            // and then this model is drawn last and paints over the cutout.
            depthBias: 2.0
            geometry: DepthMeshGeometry {
                id: depthGeometry
                depthPath: root.depthPath
                mattePath: root.mattePath
                imageZoom: root.imageZoom
                outputAspect: root.outputAspect
                sourceAspect: root.sourceAspect
            }
            materials: CustomMaterial {
                shadingMode: CustomMaterial.Unshaded
                cullMode: Material.NoCulling
                property real fade: root.fadeOpacity
                sourceBlend: CustomMaterial.One
                destinationBlend: CustomMaterial.OneMinusSrcAlpha
                vertexShader: Qt.resolvedUrl("lucidspatial3d/shaders/spatial_background.vert")
                fragmentShader: Qt.resolvedUrl("lucidspatial3d/shaders/spatial_background.frag")
                property TextureInput backgroundTexture: TextureInput {
                    texture: Texture {
                        source: root.liveSource !== null ? "" : root.backgroundPath
                        sourceItem: root.liveSource
                        minFilter: Texture.Linear
                        magFilter: Texture.Linear
                        tilingModeHorizontal: Texture.ClampToEdge
                        tilingModeVertical: Texture.ClampToEdge
                    }
                }
            }
        }

        // The subject shares the background's camera, with its own depth
        // relief. Sample the original soft matte at fragment resolution so
        // fingers and hair are not clipped to a coarse triangle silhouette.
        Model {
            // Orbiting around the focus plane leaves the subject almost
            // stationary. Add a small near-field translation, opposite the
            // far field, without rebuilding the mesh or separating its matte.
            position: Qt.vector3d(
                -root.boundedPointer.x * root.focusHalfHeight * root.outputAspect
                    * root.foregroundTravel * 2,
                root.boundedPointer.y * root.focusHalfHeight
                    * root.foregroundTravel * 2, 0)
            geometry: DepthMeshGeometry {
                id: foregroundGeometry
                foreground: true
                depthPath: root.depthPath
                mattePath: root.mattePath
                imageZoom: root.imageZoom
                outputAspect: root.outputAspect
                sourceAspect: root.sourceAspect
            }
            materials: CustomMaterial {
                shadingMode: CustomMaterial.Unshaded
                cullMode: Material.NoCulling
                property real fade: root.fadeOpacity
                // 1 for the cutout surface that sits above the widget layer:
                // its matte has to be opaque inside the subject, otherwise the
                // glass underneath bleeds through the soft edge band.
                property real fgOnly: root.foregroundOnly ? 1 : 0
                sourceBlend: CustomMaterial.One
                destinationBlend: CustomMaterial.OneMinusSrcAlpha
                depthDrawMode: Material.NeverDepthDraw
                vertexShader: Qt.resolvedUrl("lucidspatial3d/shaders/spatial_subject.vert")
                fragmentShader: Qt.resolvedUrl("lucidspatial3d/shaders/spatial_subject.frag")
                property TextureInput sourceTexture: TextureInput {
                    enabled: true
                    texture: Texture {
                        source: root.liveSource !== null ? "" : root.wallpaperPath
                        sourceItem: root.liveSource
                        minFilter: Texture.Linear
                        magFilter: Texture.Linear
                        tilingModeHorizontal: Texture.ClampToEdge
                        tilingModeVertical: Texture.ClampToEdge
                    }
                }
                property TextureInput matteTexture: TextureInput {
                    enabled: true
                    texture: Texture {
                        source: root.mattePath
                        minFilter: Texture.Linear
                        magFilter: Texture.Linear
                        tilingModeHorizontal: Texture.ClampToEdge
                        tilingModeVertical: Texture.ClampToEdge
                    }
                }
                property TextureInput backgroundTexture: TextureInput {
                    enabled: true
                    texture: Texture {
                        source: root.liveSource !== null ? "" : root.backgroundPath
                        sourceItem: root.liveSource
                        minFilter: Texture.Linear
                        magFilter: Texture.Linear
                        tilingModeHorizontal: Texture.ClampToEdge
                        tilingModeVertical: Texture.ClampToEdge
                    }
                }
            }
        }
    }

    function updateCamera() {
        const tiltX = root.boundedPointer.x
        const tiltY = root.boundedPointer.y
        const yaw = tiltX * Math.PI * 4 / 180
        const pitch = -tiltY * Math.PI * 3 / 180
        const radius = depthGeometry.focusDistance
        camera.position = Qt.vector3d(
            Math.sin(yaw) * Math.cos(pitch) * radius + SpatialShake.x * root.shakeScale,
            Math.sin(pitch) * radius + SpatialShake.y * root.shakeScale,
            root.focusZ + Math.cos(yaw) * Math.cos(pitch) * radius
                + SpatialShake.z * root.shakeScale)
        camera.lookAt(Qt.vector3d(0, 0, root.focusZ))
    }
    function requestCamera() {
        if (!root.animationPaused)
            cameraSettle.restart();
    }

    // The pointer, the idle circle and the shake all land in the same event
    // loop turn. Coalescing them means one matrix rebuild per tick instead of
    // two or three; it is the same camera pose either way.
    Timer {
        id: cameraSettle

        interval: 0
        repeat: false
        onTriggered: root.updateCamera()
    }

    onBoundedPointerChanged: root.requestCamera()
    onOutputAspectChanged: root.requestCamera()
    onAnimationPausedChanged: {
        if (!root.animationPaused)
            root.requestCamera();
    }
    Connections {
        target: depthGeometry
        function onFocusDistanceChanged() { root.requestCamera() }
    }
    Connections {
        target: SpatialShake
        function onTick() { root.requestCamera() }
    }
    Component.onCompleted: updateCamera()
}

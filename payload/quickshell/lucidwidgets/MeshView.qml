import QtQuick
import QtQuick3D
import QtQuick3D.Helpers
import qs
import qs.lucidui

// an interactive turntable for a .glb: drag to orbit, scroll to zoom.
// the model auto-frames from its own bounds, whatever scale it was exported at.
Item {
    id: view

    property string source: ""
    property color background: "transparent"
    property real fill: 0.62          // how much of the frame the model takes
    property bool spinning: false

    property bool ready: false
    // The caller can hold the poller back while the preview is off screen.
    property bool active: true
    // A malformed or empty GLB never reports bounds; do not spin "loading"
    // forever. After ~10 s the preview says it could not be shown.
    property bool failed: false
    property int ticks: 0
    property vector3d boundsMin: Qt.vector3d(0, 0, 0)
    property vector3d boundsMax: Qt.vector3d(0, 0, 0)

    // Model has no status signal (that is Image); poll the bounds until the
    // asset is parsed, then frame it once.
    function frame() {
        var b = model.bounds;
        var d = Qt.vector3d(b.maximum.x - b.minimum.x, b.maximum.y - b.minimum.y, b.maximum.z - b.minimum.z);
        if (d.x + d.y + d.z <= 0)
            return false;

        view.boundsMin = b.minimum;
        view.boundsMax = b.maximum;
        var extent = Math.max(d.x, Math.max(d.y, d.z));
        var s = view.fill * 200 / Math.max(extent, 1e-6);
        model.scale = Qt.vector3d(s, s, s);
        rig.position = Qt.vector3d(-(b.minimum.x + d.x / 2) * s, -(b.minimum.y + d.y / 2) * s, -(b.minimum.z + d.z / 2) * s);
        view.ready = true;
        return true;
    }

    Timer {
        interval: 120
        repeat: true
        running: view.active && !view.ready && !view.failed && view.source !== ""
        onTriggered: {
            view.ticks += 1;
            if (view.frame())
                return ;
            if (view.ticks > 80)
                view.failed = true;
        }
    }

    onSourceChanged: {
        view.ready = false;
        view.failed = false;
        view.ticks = 0;
        model.scale = Qt.vector3d(1, 1, 1);
        rig.position = Qt.vector3d(0, 0, 0);
        model.source = view.source;
    }

    View3D {
        anchors.fill: parent
        camera: cam

        environment: SceneEnvironment {
            clearColor: view.background
            backgroundMode: view.background.a > 0 ? SceneEnvironment.Color : SceneEnvironment.Transparent
            antialiasingMode: SceneEnvironment.MSAA
            // The preview is small; High MSAA only costs framebuffer memory
            // when the machine is already tight.
            antialiasingQuality: SceneEnvironment.Medium
        }

        PerspectiveCamera {
            id: cam

            fieldOfView: 40
            clipNear: 0.01
            clipFar: 5000
            position: Qt.vector3d(0, 70, 240)
        }

        DirectionalLight {
            eulerRotation.x: -32
            eulerRotation.y: 35
            brightness: 1.1
        }

        DirectionalLight {
            eulerRotation.x: -10
            eulerRotation.y: -140
            brightness: 0.5
        }

        Node {
            id: rig

            Model {
                id: model
            }
        }
    }

    OrbitCameraController {
        anchors.fill: parent
        origin: rig
        camera: cam
    }

    // a slow turn so an untouched preview still reads as three-dimensional
    NumberAnimation {
        target: rig
        property: "eulerRotation.y"
        running: view.spinning && view.ready
        from: 0
        to: 360
        duration: 22000
        loops: Animation.Infinite
    }

    LText {
        anchors.centerIn: parent
        visible: view.source !== "" && !view.ready
        role: "labelSmall"
        text: view.failed ? "3D preview unavailable" : "loading 3D preview…"
        color: view.failed ? Theme.error : Theme.subtext
    }
}

import QtQuick
import Quickshell
import Quickshell.Wayland

// Minimal glass test shell for the nested rig. One bottom dock pill with
// opaque content (proves draw order: content over glass) + geometry writer.
// No Prefs/Theme dependencies on purpose. GlassLayout.qml is vendored here
// (see its header) because quickshell confines imports to this folder.

// Minimal glass test shell for the nested rig. One bottom dock pill with
// opaque content (proves draw order: content over glass) + geometry writer.
// No Prefs/Theme dependencies on purpose.

ShellRoot {
    PanelWindow {
        id: dock

        anchors {
            bottom: true
            left: true
            right: true
        }
        implicitHeight: 80
        color: "transparent"

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12
            width: 400
            height: 56
            radius: 28
            color: "#202020"

            Text {
                anchors.centerIn: parent
                text: "glass test"
                color: "white"
                font.pixelSize: 16
                // Test-rig heartbeat: forces layer damage continuously so the
                // glass pipeline runs every frame (a static scene renders
                // once and idles, which tells us nothing).
                SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    NumberAnimation { from: 0.75; to: 1.0; duration: 500 }
                    NumberAnimation { from: 1.0; to: 0.75; duration: 500 }
                }
            }
        }

        GlassLayout {
            name: "testdock"
            targetScreen: dock.screen
            surfaceW: dock.width
            surfaceH: dock.height
            pills: [{
                x: (dock.width - 400) / 2,
                y: dock.height - 12 - 56,
                w: 400,
                h: 56,
                r: [28, 28, 28, 28]
            }]
        }
    }
}

import QtQuick
import Quickshell
import qs
pragma Singleton

// Passive camera tremble for the 3D wallpaper. Continuous incommensurate
// sines give a smooth, irregular drift with continuous position and velocity;
// there is no random step to snap between, which was what made earlier
// 15 Hz target updates feel jittery.
// A slow twenty-second circle carries the view angle around the frame, like
// tracing a circle with the mouse, so the tremble wanders instead of staying
// pinned near one point.
Singleton {
    id: root

    property real x: 0
    property real y: 0
    property real z: 0
    // Slow idle look-around: the same view-angle change as moving the mouse in
    // a circle, one lap every twenty seconds. The renderer adds it to the
    // pointer input, so it still runs while the pointer is parked on a window.
    property real lookX: 0
    property real lookY: 0
    property real phase: 0
    // Renderer multiplies this by the mesh focus distance. Slower sines read
    // as less motion at the same travel, so this is up from the old 0.0032.
    readonly property real amplitude: 0.0046
    readonly property real orbitPeriod: 20
    // fraction of the pointer range the circle covers
    readonly property real orbitRadius: 0.2125
    // A focused client window covers the wallpaper the user is looking at.
    // Every surface is paused in that state, so the only timer that would
    // still wake the renderer is this one; stop it when no screen is free.
    readonly property bool running: Prefs.spatialWallpapers && SpatialWall.hasVisual
        && SpatialWall.displaysAwake
        && !SpatialWall.allScreensFocused && !SpatialWall.meshBusy
    // A widget in hand already owns the eye. Do not spend a fullscreen 3D
    // capture per tick on a wallpaper nobody is watching; the camera keeps its
    // last pose and resumes when the pointer lets go.
    readonly property bool pointerBusy: Widgets.dragUid !== ""
        || Widgets.liveUid !== "" || Widgets.marquee !== null
        || Widgets.panelDragging

    signal tick()

    // Compress the peaks and lift the ordinary middle of the motion:
    //   f(0) = 0, f(0.3) = 0.36 (+20%), f(1) = 0.67 (-33%)
    // with a monotonic quadratic on the magnitude and the original sign.
    function shape(value) {
        const x = Math.max(-1, Math.min(1, value));
        const magnitude = Math.abs(x);
        const shaped = 1.328 * magnitude - 0.658 * magnitude * magnitude;
        return x < 0 ? -shaped : shaped;
    }

    // Half the old sine speed (1.7/4.1/9.3 became 0.85/2.05/4.65 and so on):
    // clearly calmer than the old tremor, but still enough travel to see.
    function step() {
        // Advance by the timer's real interval, so changing the update rate
        // does not also change the idle motion's speed.
        root.phase += 0.033;
        const p = root.phase;
        // Three incommensurate bands: slow drift, a little sway, tiny tremor.
        const fastX = 0.55 * Math.sin(p * 0.85 + 0.3)
            + 0.30 * Math.sin(p * 2.05 + 1.7)
            + 0.15 * Math.sin(p * 4.65 + 2.1);
        const fastY = 0.55 * Math.sin(p * 0.65 + 2.2)
            + 0.30 * Math.sin(p * 1.85 + 0.8)
            + 0.15 * Math.sin(p * 4.05 + 2.8);
        const fastZ = 0.55 * Math.sin(p * 0.95 + 1.1)
            + 0.30 * Math.sin(p * 2.35 + 2.4)
            + 0.15 * Math.sin(p * 4.35 + 0.2);
        root.x = root.shape(fastX);
        root.y = root.shape(fastY);
        root.z = root.shape(fastZ);
        // The view angle follows the right half of the circle, swept back and
        // forth: x stays on the right, y travels from top to bottom and back.
        // At the ends the sweep eases out, so the turn-around is soft.
        const ramp = Math.min(1, p / root.orbitPeriod);
        const ease = ramp * ramp * (3 - 2 * ramp);
        const sweep = Math.sin(2 * Math.PI * (p % root.orbitPeriod) / root.orbitPeriod);
        const angle = (Math.PI / 2) * sweep;
        root.lookX = root.orbitRadius * ease * Math.cos(angle);
        root.lookY = root.orbitRadius * ease * Math.sin(angle);
        root.tick();
    }

    onRunningChanged: {
        if (!root.running) {
            root.x = root.y = root.z = 0;
            root.lookX = root.lookY = 0;
            root.phase = 0;
            root.tick();
        }
    }

    // 30 Hz is the smoothness/power compromise for a slow idle drift. Every
    // tick dirties the camera and repaints the fullscreen 3D wallpaper on every
    // output, so this is far more expensive than the timer math suggests.
    // While the launcher is up the motion is invisible behind the panel and the
    // render threads are needed for the reveal, so park the timer instead of
    // stopping it: changing `running` resets the pose and would snap the
    // wallpaper to center when the launcher opens.
    Timer {
        interval: SpatialWall.launcherOpen ? 3600000 : 33
        repeat: true
        running: root.running && !root.pointerBusy
        onTriggered: root.step()
    }
}

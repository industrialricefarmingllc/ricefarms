import QtQuick

// Small numeric spring for the bar's liquid morph.
//
// Vitreus describes its drawer motion with `stiffness, damping` pairs (mass
// 1); the expanding panel uses `drip = 170, 18`. Keeping the integrator here
// (instead of a Behavior) lets the bar read both value and velocity every
// frame and feed them to the shape shader — the velocity is what makes the
// body stretch like a drop instead of just easing.
Item {
    id: root

    property real value: 0
    property real target: 0
    property real velocity: 0
    property real stiffness: 170
    property real damping: 18
    property real mass: 1
    property real epsilon: 0.002
    property bool running: false

    signal settled()

    // A hitch must not explode the integrator; substeps keep it stable.
    readonly property real _dtMax: 0.05
    readonly property real _substep: 0.004

    function kick(v) {
        root.velocity += v;
        root.running = true;
    }

    function snap(v) {
        root.value = v;
        root.velocity = 0;
        root.running = false;
    }

    function step(dt) {
        if (!(dt > 0))
            return;

        dt = Math.min(dt, root._dtMax);
        const steps = Math.max(1, Math.ceil(dt / root._substep));
        const h = dt / steps;

        for (let i = 0; i < steps; i++) {
            const accel = (-root.stiffness * (root.value - root.target) - root.damping * root.velocity) / Math.max(0.001, root.mass);
            root.velocity += accel * h;
            root.value += root.velocity * h;
        }

        if (Math.abs(root.value - root.target) < root.epsilon && Math.abs(root.velocity) < root.epsilon) {
            root.value = root.target;
            root.velocity = 0;
            root.running = false;
            root.settled();
        }
    }

    onTargetChanged: {
        if (Math.abs(root.value - root.target) > 0.0001)
            root.running = true;

    }

    FrameAnimation {
        running: root.running
        onTriggered: root.step(frameTime)
    }

}

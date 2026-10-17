// Launch-morph ooze (see launcher/MorphOverlay.qml).
//
// The app-open animation as a liquid surface: a dot at the tile holds,
// a cord oozes out of it, the window swells viscously at the cord's far
// end, and the whole mass settles into the crisp window rect. Analytic
// goo field (blurred SDF sum, threshold 0.5 - the SVG #goo trick of blur
// 10 / contrast 18/-7, minus the filter), so necks and bridges come free.
//
// Motion is ONE progress value (oozeProg), driven by a soft QML spring:
// size/center mixes use it raw so the spring's overshoot pops past full,
// gates use it clamped so sculpting never oscillates. Macro geometry
// (tile -> window) arrives as uniforms in item-local px; the flight item
// is the static union of both, so endpoints glide live with settle and
// no snapshot/retarget logic can chase or teleport.
//
// Build (mirrors the other vendored shaders):
//   /usr/lib/qt6/bin/qsb --qt6 -o morph-ooze.frag.qsb morph-ooze.frag
// Commit both files; the stage loads the .qsb.
#version 440
layout(location=0) in vec2 qt_TexCoord0;
layout(location=0) out vec4 fragColor;
layout(std140, binding=0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 oozeColor;
    vec2 oozeRes;
    float oozeProg;
    vec2 oozeFrom;
    float oozeFromR;
    vec2 oozeTo;
    vec2 oozeToHalf;
    float oozeToR;
};
float sdCircle(vec2 p, float r) {
    return length(p) - r;
}
float sdRoundBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}
void main() {
    vec2 p = qt_TexCoord0 * oozeRes;
    float s = oozeProg;
    float t = clamp(s, 0.0, 1.0);

    // Dot: holds at the tile, travels into the window center late,
    // absorbed on arrival. Clean circle - all character is the window's.
    float presence = 1.0 - smoothstep(0.70, 0.92, t);
    vec2 bc = mix(oozeFrom, oozeTo, smoothstep(0.0, 0.75, t));
    float br = oozeFromR * presence;
    float sdB = sdCircle(p - bc, br);

    // Window: bud swelling viscously at the cord's far end. Size/center
    // take the RAW spring so the overshoot pops past full; gates take
    // the clamped one so nothing oscillates.
    float gc = smoothstep(0.0, 0.80, t);
    vec2 gcc = mix(oozeFrom, oozeTo, gc);
    float gs = smoothstep(0.0, 0.85, t);
    vec2 ghalf = mix(vec2(oozeFromR * 0.4), oozeToHalf, max(s, gs));

    // Relaxed corner radius while traveling, crisp at fusion. Oversized
    // early so the bud stays blobby even before the relax curve starts.
    float gR = mix(min(oozeToHalf.x, oozeToHalf.y) * 0.3, oozeToR, smoothstep(0.55, 0.97, t));
    vec2 grel = p - gcc;
    float sdW0 = sdRoundBox(grel, ghalf, gR);

    // Flank sculpting in SDF space (radius displacement cannot move a
    // box's flat edges - measured 0px of bow; bumps give ~25px). Capped
    // so paint always fits the flight item's margin (see MorphOverlay).
    float gmax = max(ghalf.x, ghalf.y);
    float genv = smoothstep(0.05, 0.20, t) * (1.0 - smoothstep(0.80, 0.97, t));
    float sway = 0.15 * ghalf.y * sin(6.28318 * t * 1.5);
    float pushAmp = min(0.16 * gmax, 48.0) * genv;
    float pushR = pushAmp
        * exp(-pow((grel.y - sway) / max(ghalf.y * 0.5, 1.0), 2.0))
        * exp(-pow((grel.x - ghalf.x) / 50.0, 2.0));
    float pushL = pushAmp
        * exp(-pow((grel.y + sway) / max(ghalf.y * 0.5, 1.0), 2.0))
        * exp(-pow((grel.x + ghalf.x) / 50.0, 2.0));
    float gthD = 2.1 - 6.28318 * t * 0.55;
    vec2 dentC = vec2(cos(gthD), sin(gthD)) * min(ghalf.x, ghalf.y) * 0.9;
    float dent = 0.10 * gmax * genv
        * exp(-pow(length(grel - dentC) / 70.0, 2.0));
    float bulgeB = min(0.14 * gmax, 48.0) * genv
        * exp(-pow((grel.y - ghalf.y) / 50.0, 2.0))
        * exp(-pow(grel.x / max(ghalf.x * 0.6, 1.0), 2.0));
    float sdW = sdW0 - pushR - pushL - bulgeB + dent;

    // Cord: the stretched surface between dot and window underside.
    float cordW = smoothstep(0.0, 0.25, t);
    vec2 ca = bc;
    vec2 cb = vec2(gcc.x, gcc.y + ghalf.y * 0.7);
    vec2 pa = p - ca;
    vec2 ba = cb - ca;
    float hh = clamp(dot(pa, ba) / max(dot(ba, ba), 1.0), 0.0, 1.0);
    float sdC = length(pa - ba * hh) - 16.0 * cordW;

    float blur = 18.0;
    float fB = 1.0 - smoothstep(-blur, blur, sdB);
    float fW = 1.0 - smoothstep(-blur, blur, sdW);
    float fC = (1.0 - smoothstep(-blur, blur, sdC)) * step(0.001, cordW);

    float f = fB + fW + fC;
    float a = smoothstep(0.47, 0.53, f);
    fragColor = vec4(oozeColor.rgb, a * qt_Opacity);
}

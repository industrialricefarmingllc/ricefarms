// Liquid blob for the launch morph (see launcher/MorphOverlay.qml).
//
// One shape that flows into the window: a rounded-rect SDF with an
// animated wobble on its outline, drawn procedurally (no source texture,
// no blur/threshold stage). Macro motion (position/size/squash) stays in
// QML animations; this owns the micro liquid - the edge breathing while
// traveling, settling dead calm exactly at landing (wobble -> 0).
//
// Build (mirrors Lucid's vendored shaders):
//   /usr/lib/qt6/bin/qsb --qt6 -o morph-liquid.frag.qsb morph-liquid.frag
// Commit both files; the daemon loads the .qsb.
#version 440
layout(location=0) in vec2 qt_TexCoord0;
layout(location=0) out vec4 fragColor;
layout(std140, binding=0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 liqColor;
    vec2 liqRes;
    float liqRadius;
    float liqWobble;
    float liqTime;
};
float sdRoundBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}
void main() {
    // Item space, px: UV spans the item whatever its backing store, so no
    // DPR math is needed here - only edge quality varies.
    vec2 p = qt_TexCoord0 * liqRes;
    vec2 c = liqRes * 0.5;
    vec2 d = p - c;
    // Wobble rides the outline angle: two incommensurate sine fields, so
    // the edge breathes organically instead of sliding. Amplitude is in px.
    float ang = atan(d.y, d.x);
    float w = sin(ang * 5.0 + liqTime * 6.0) * 0.6 + sin(ang * 3.0 - liqTime * 4.3) * 0.4;
    float disp = w * liqWobble;
    // Keep the SDF box a fixed inset back from the item edge so the wobble
    // never clips against the item bounds.
    float inset = 9.0;
    float sd = sdRoundBox(d, liqRes * 0.5 - vec2(inset), liqRadius + disp);
    float a = 1.0 - smoothstep(-1.0, 1.0, sd);
    fragColor = vec4(liqColor.rgb, a * qt_Opacity);
}

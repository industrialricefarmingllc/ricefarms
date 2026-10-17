// Inverted squircle fillet (Qt 6 ShaderEffect, qsb-baked).
//
// Fills the unit box where the point lies OUTSIDE the superellipse disc
// around discCenter: the concave shoulder of a notch tab. At exponent 2
// this is exactly the old PathArc flare. See squircle_rect.frag header
// for the .qsb build note.

#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 fillColor;
    vec2 itemSize;
    float exponent;
    vec2 discCenter;
    float mirrorFlag;
};

void main() {
    vec2 uv = qt_TexCoord0;
    float x = mix(uv.x, 1.0 - uv.x, mirrorFlag);
    // Unit-space distance from the disc center, y-down like the box.
    vec2 q = vec2(abs(x - discCenter.x), abs(uv.y - discCenter.y));
    // Degenerate size guard: a 0-size flare fills nothing.
    vec2 mn = max(itemSize, vec2(1.0));
    vec2 qn = q * mn / min(mn.x, mn.y);
    float v = pow(qn.x, exponent) + pow(qn.y, exponent);
    // ~1.5px anti-aliased edge in value space (dv/dpx ~ n/S).
    float w = 1.5 * exponent / min(mn.x, mn.y);
    float a = smoothstep(1.0 - w, 1.0 + w, v);
    if (a <= 0.001)
        discard;
    fragColor = vec4(fillColor.rgb * a * fillColor.a, a * fillColor.a) * qt_Opacity;
}

// Inverted squircle fillet (Qt 6 ShaderEffect, qsb-baked).
//
// Fills the unit box where the point lies OUTSIDE the superellipse disc
// around discCenter: the concave shoulder of a notch tab. At exponent 2
// this is exactly the old PathArc flare. A border, when asked for, follows
// only that concave arc: the box's straight sides are internal to the tab
// and must not show an outline. See squircle_rect.frag header for the .qsb
// build note.

#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 fillColor;
    vec4 borderColor;
    float borderWidth;
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
    // Pixel-accurate edge, as squircle_corners.frag does: dividing the field
    // by its screen-space derivative keeps the transition one pixel wide at
    // any exponent or flare size. The old fixed band in value space widened
    // with the exponent and read as a blurry shoulder.
    float fw = max(fwidth(v), 1e-6);
    // signed distance to the arc in px (the shape is the outside of the disc)
    float edge = (v - 1.0) / fw;
    float a = smoothstep(-0.5, 0.5, edge);
    if (a <= 0.001)
        discard;
    // no border width: fill right to the arc edge, as before the border existed
    float fillA = borderWidth > 1e-4 ? smoothstep(-0.5, 0.5, edge - borderWidth) : 1.0;
    vec3 rgb = mix(borderColor.rgb, fillColor.rgb, fillA);
    float outA = a * mix(borderColor.a, fillColor.a, fillA);
    fragColor = vec4(rgb * outA, outA) * qt_Opacity;
}

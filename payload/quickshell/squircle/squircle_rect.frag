// Squircle fill + border fragment shader (Qt 6 ShaderEffect, qsb-baked).
//
// Source of truth is this .frag; the .qsb beside it is build output
// (`qsb squircle_rect.frag -o squircle_rect.qsb`). Qt 6 ShaderEffect only
// accepts .qsb URLs — raw .frag source renders nothing (and fails the
// lookup against the *using* file's directory, hence Qt.resolvedUrl in
// SquircleRect.qml).
//
// Uniforms come from SquircleRect.qml QML properties matched by name:
//   fillColor / borderColor (vec4), borderWidth px, borderTop 0/1,
//   borderGap (left/right px dropped from the top), itemSize = w/h,
//   radii = [tl, tr, br, bl] px, exponent n.
//
// At n = 2 the corner SDF is exactly circular, matching Rectangle.

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
    vec4 radii;
    float exponent;
    float borderTop;
    vec2 borderGap;
};

float sdSquircleBox4(vec2 p, vec2 b, vec4 r, float n) {
    float rt = (p.x > 0.0) ? r.y : r.x;
    float rb = (p.x > 0.0) ? r.z : r.w;
    float rad = (p.y > 0.0) ? rb : rt;
    vec2 ap = abs(p);
    vec2 c = b - vec2(rad);
    if (rad > 0.01 && ap.x > c.x && ap.y > c.y) {
        if (n <= 2.001)
            return length(ap - c) - rad; // exact circle: f = 0 is Rectangle
        // L^n norm field: 0 exactly on the superellipse, exact circle at
        // n = 2, bounded and monotone in the corner interior (num/den is a
        // near-surface linearisation that dives to -hundreds of px one
        // corner-width in, which steps dist/glow hard along x = b.x - rad
        // and y = b.y - rad).
        vec2 q = (ap - c) / rad;
        return (pow(pow(q.x, n) + pow(q.y, n), 1.0 / n) - 1.0) * rad;
    }
    vec2 q2 = ap - b + vec2(rad);
    return min(max(q2.x, q2.y), 0.0) + length(max(q2, 0.0)) - rad;
}

void main() {
    vec2 p = (qt_TexCoord0 - vec2(0.5)) * itemSize;
    float sd = sdSquircleBox4(p, itemSize * 0.5, radii, exponent);
    // Pixel-accurate edge, as squircle_corners.frag does. A fixed band in
    // distance space left the first row ~16% transparent, which read as a
    // 1px rim along a tab flush with the screen edge. fwidth(sd) is the
    // distance covered by one pixel, so the ramp stays one pixel wide at any
    // scale and the first row is fully opaque.
    //
    // fwidth is only a pixel footprint on the edge, where this SDF is metric
    // (|grad sd| = 1). Inside a superellipse corner the gradient of the
    // normalised field collapses towards the corner's centre while sd itself
    // stays finite, so fwidth explodes into the thousands and the smoothstep
    // band below grows wide enough to eat a faint arc out of the fill — the
    // stray transparent line inside every rounded corner. Cap the footprint
    // at a size no real pixel grid produces; on the edge the derivative is
    // 1/scale and always under the cap, so the edge itself is unchanged.
    float fw = clamp(fwidth(sd), 1e-6, 2.0);
    float bodyA = 1.0 - smoothstep(-0.5 * fw, 0.5 * fw, sd);
    if (bodyA <= 0.001)
        discard;
    // Edge masks, all in px: a notch tab grows out of the screen edge, so the
    // top border is off there; and a side border stops where a concave
    // shoulder flare (which draws its own arc) takes over, so the notch does
    // not read as a separate shape stuck onto the tab.
    //
    // The top band carries the fill/border boundary's whole pixel footprint
    // (fw), not just borderWidth: on a fractional output scale that boundary
    // lands between device rows, and its antialiasing bled one row past a band
    // exactly borderWidth tall — a hairline of border colour under the screen
    // edge, which read as the tab sitting a pixel low.
    vec2 halfSize = itemSize * 0.5;
    float topBand = (1.0 - borderTop) * step(p.y, -halfSize.y + borderWidth + fw);
    float leftBand = step(0.5, borderGap.x) * step(p.x, -halfSize.x + borderWidth) * step(p.y, -halfSize.y + borderGap.x);
    float rightBand = step(0.5, borderGap.y) * step(halfSize.x - borderWidth, p.x) * step(p.y, -halfSize.y + borderGap.y);
    float bw = borderWidth * max(0.0, 1.0 - min(1.0, topBand + leftBand + rightBand));
    float fillA = 1.0 - smoothstep(-0.5 * fw, 0.5 * fw, sd + bw);
    vec3 rgb = mix(borderColor.rgb, fillColor.rgb, fillA);
    float a = bodyA * mix(borderColor.a, fillColor.a, fillA);
    fragColor = vec4(rgb * a, a) * qt_Opacity;
}

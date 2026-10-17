// Squircle fill + border fragment shader (Qt 6 ShaderEffect, qsb-baked).
//
// Source of truth is this .frag; the .qsb beside it is build output
// (`qsb squircle_rect.frag -o squircle_rect.qsb`). Qt 6 ShaderEffect only
// accepts .qsb URLs — raw .frag source renders nothing (and fails the
// lookup against the *using* file's directory, hence Qt.resolvedUrl in
// SquircleRect.qml).
//
// Uniforms come from SquircleRect.qml QML properties matched by name:
//   fillColor / borderColor (vec4), borderWidth px, itemSize = w/h,
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
        vec2 q = (ap - c) / rad;
        float n2 = 2.0 * n - 2.0;
        float num = pow(q.x, n) + pow(q.y, n) - 1.0;
        float den = n * sqrt(pow(q.x, n2) + pow(q.y, n2)) + 0.0001;
        return num / den * rad;
    }
    vec2 q2 = ap - b + vec2(rad);
    return min(max(q2.x, q2.y), 0.0) + length(max(q2, 0.0)) - rad;
}

void main() {
    vec2 p = (qt_TexCoord0 - vec2(0.5)) * itemSize;
    float sd = sdSquircleBox4(p, itemSize * 0.5, radii, exponent);
    float aa = 1.0;
    float bodyA = 1.0 - smoothstep(-aa, aa, sd);
    if (bodyA <= 0.001)
        discard;
    float fillA = 1.0 - smoothstep(-aa, aa, sd + borderWidth);
    vec3 rgb = mix(borderColor.rgb, fillColor.rgb, fillA);
    float a = bodyA * mix(borderColor.a, fillColor.a, fillA);
    fragColor = vec4(rgb * a, a) * qt_Opacity;
}

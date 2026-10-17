// White squircle alpha mask (Qt 6 ShaderEffect, qsb-baked).
// Same SDF as squircle_rect.frag; borderless, premultiplied white output
// for use as OpacityMask / MultiEffect maskSource. See squircle_rect.frag
// header for the .qsb build note.

#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
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
    float a = 1.0 - smoothstep(-0.75, 0.75, sd);
    if (a <= 0.001)
        discard;
    fragColor = vec4(a, a, a, a) * qt_Opacity;
}

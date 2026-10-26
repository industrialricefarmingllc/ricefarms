// Liquid bar body for the top-bar expansion (Qt 6 ShaderEffect, qsb-baked).
//
// Two squircle boxes (the compact pill and the expanding panel) merged with a
// smooth minimum. That is the same trick Vitreus' glass uses for its drawer
// necks: where the boxes meet, the distance field rounds into a web instead
// of two hard silhouettes. The panel box starts as a small circle at the
// pressed point, so the body appears to grow out of the click.
//
// Source of truth is this .frag; the .qsb beside it is build output:
//   /usr/lib/qt6/bin/qsb --qt6 liquid_shape.frag -o liquid_shape.frag.qsb
//
// Uniforms come from LiquidShape.qml:
//   fillColor, itemSize, compactRect, compactRadii, panelRect,
//   panelRadii, exponent, goo.

#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 fillColor;
    vec2 itemSize;
    vec4 compactRect;   // x, y, w, h in item px
    vec4 compactRadii;  // tl, tr, br, bl
    vec4 panelRect;
    vec4 panelRadii;
    float exponent;
    float goo;
};

// Same superellipse SDF as squircle_rect.frag, so the final silhouette is
// pixel-identical to the normal SquircleRect body it hands over to.
float sdSquircleBox4(vec2 p, vec2 b, vec4 r, float n) {
    float rt = (p.x > 0.0) ? r.y : r.x;
    float rb = (p.x > 0.0) ? r.z : r.w;
    float rad = (p.y > 0.0) ? rb : rt;
    vec2 ap = abs(p);
    vec2 c = b - vec2(rad);
    if (rad > 0.01 && ap.x > c.x && ap.y > c.y) {
        if (n <= 2.001)
            return length(ap - c) - rad;
        vec2 q = (ap - c) / rad;
        float n2 = 2.0 * n - 2.0;
        float num = pow(q.x, n) + pow(q.y, n) - 1.0;
        float den = n * sqrt(pow(q.x, n2) + pow(q.y, n2)) + 0.0001;
        return num / den * rad;
    }
    vec2 q2 = ap - b + vec2(rad);
    return min(max(q2.x, q2.y), 0.0) + length(max(q2, 0.0)) - rad;
}

// Polynomial smooth min: b wins far from a, a wins far from b, and the band
// between them rounds off. `k` is the width of the liquid bridge.
float smin(float a, float b, float k) {
    k = max(k, 0.001);
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

void main() {
    vec2 p = qt_TexCoord0 * itemSize;

    vec2 cc = compactRect.xy + compactRect.zw * 0.5;
    float dc = sdSquircleBox4(p - cc, compactRect.zw * 0.5, compactRadii, exponent);

    vec2 pc = panelRect.xy + panelRect.zw * 0.5;
    float dp = sdSquircleBox4(p - pc, panelRect.zw * 0.5, panelRadii, exponent);

    float d = smin(dc, dp, goo);
    float a = 1.0 - smoothstep(-0.75, 0.75, d);
    if (a <= 0.001)
        discard;

    float outA = a * fillColor.a * qt_Opacity;
    fragColor = vec4(fillColor.rgb * outA, outA);
}

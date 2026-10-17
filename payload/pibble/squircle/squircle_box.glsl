// Squircle rounded-rect SDF shared by the QML squircle items.
//
// p is item-space px relative to the rect center, halfBox the half size,
// r the [tl, tr, br, bl] radii (y-down quadrant pick, same convention as
// the liquid-glass-hypr plugin's sdRoundBox4), n the superellipse
// exponent (2 = circle, 4 = classic squircle at f = 0.5).
//
// Inside a rounded corner quadrant the edge is a superellipse arc; on
// straight edges it falls back to the exact box SDF, so radius 0 stays a
// sharp square corner. At n = 2 the corner term is the exact circle SDF,
// i.e. this reduces pixel-for-pixel to the old Rectangle look.
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

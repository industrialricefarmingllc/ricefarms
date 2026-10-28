// Shared squircle math for the Lucid + Pibble shells.
//
// One parameter rules every corner in both shells:
//
//   f in [0, 1]  — corner smoothing ("squircle factor").
//                  0   = classic circular rounded rect (bit-identical to the
//                        old Rectangle radius / PathArc look).
//                  0.5 = classic squircle (superellipse exponent n = 4).
//                  1   = near-rect superellipse (n = 6, the top of the
//                        LiquidGlass "Power" slider range).
//
// Mapping:  n(f) = 2 + 4*f, so f = 0.5 lands exactly on n = 4.
//
// Why a superellipse: with n = 2 the corner SDF below reduces *exactly* to
// the circle SDF (|q|^2 - 1)/(2|q|), so dialling f back to 0 restores the
// old look pixel-for-pixel. The same exponent drives the QML ShaderEffect
// corners here and the liquid-glass-hypr compositor plugin
// (plugin:liquidglass:squircle_f -> uSquircleF -> sdSquircleBox4), so the
// QML content clip and the plugin-drawn glass agree on one shape.
//
// Corner convention (shared with the plugin): radii are [tl, tr, br, bl]
// and the active corner is picked by quadrant, y-down:
//   right half (x > 0) -> tr/br, bottom half (y > 0) -> br/bl.
//
// Inverted corners (screen bezel, notch flares) are the same curve turned
// inside out: unit box INTERSECT outside-of-superellipse around a disc
// center c. BarFlare/DockFlare/ScreenCorners only differ in c:
//   bar notch flare (top edge):    c = (0, 1)  (outer-bottom corner)
//   dock notch flare (bottom edge): c = (0, 0) (outer-top corner)
//   screen bezel corner:            c = (1, 1)  (inner corner)
// Mirroring flips c.x. At n = 2 each reproduces the old PathArc exactly.
.pragma library

// Clamp a smoothing factor into range. NaN/undefined fall back to 0.5.
function clampF(f) {
    if (f === undefined || f === null || isNaN(f))
        return 0.5;
    return Math.max(0, Math.min(1, f));
}

// Superellipse exponent for a smoothing factor. f = 0.5 -> 4.
function exponent(f) {
    return 2 + 4 * clampF(f);
}

// Pick one corner radius from [tl, tr, br, bl] by sign of p, y-down.
// sx > 0 is the right half, sy > 0 the bottom half.
function pickRadius(r, sx, sy) {
    var rt = sx > 0 ? r[1] : r[0];
    var rb = sx > 0 ? r[2] : r[3];
    return sy > 0 ? rb : rt;
}

// SVG path for a squircle rect (for Shape+PathSvg masks and fills that
// must behave exactly like a plain Rectangle item: no shaders, no .qsb,
// no maskSource quirks). w/h in px, r = [tl, tr, br, bl], n the
// superellipse exponent. Sampling is adaptive per corner (~3.5px per
// segment, 6..64 samples): a fixed count facets visibly once radii grow
// past ~40px. At n = 2 the samples sit exactly on the circular arcs.
function svgSquirclePath(w, h, r, n) {
    if (!(w > 0) || !(h > 0))
        return "";
    var tl = Math.max(0, r[0]), tr = Math.max(0, r[1]);
    var br = Math.max(0, r[2]), bl = Math.max(0, r[3]);
    function fnum(v) {
        return (Math.round(v * 100) / 100).toString();
    }
    function arc(cx, cy, rad, a0, a1) {
        var s = Math.max(6, Math.min(64, Math.ceil(rad / 3.5)));
        var pts = [];
        for (var i = 0; i <= s; i++) {
            var a = a0 + (a1 - a0) * (i / s);
            var c = Math.cos(a), sn = Math.sin(a);
            var px = cx + rad * Math.sign(c) * Math.pow(Math.abs(c), 2 / n);
            var py = cy + rad * Math.sign(sn) * Math.pow(Math.abs(sn), 2 / n);
            pts.push((i === 0 ? "L " : "") + fnum(px) + " " + fnum(py));
        }
        // first point of each arc duplicates the line endpoint; PathSvg
        // tolerates the zero-length segment, keep the builder simple
        return pts.join(" ");
    }
    var d = "M " + fnum(tl) + " 0 ";
    d += "L " + fnum(w - tr) + " 0 ";
    if (tr > 0)
        d += arc(w - tr, tr, tr, -Math.PI / 2, 0) + " ";
    d += "L " + fnum(w) + " " + fnum(h - br) + " ";
    if (br > 0)
        d += arc(w - br, h - br, br, 0, Math.PI / 2) + " ";
    d += "L " + fnum(bl) + " " + fnum(h) + " ";
    if (bl > 0)
        d += arc(bl, h - bl, bl, Math.PI / 2, Math.PI) + " ";
    d += "L 0 " + fnum(tl) + " ";
    if (tl > 0)
        d += arc(tl, tl, tl, Math.PI, Math.PI * 1.5) + " ";
    return d + "Z";
}

// Superellipse field value |qx|^n + |qy|^n for unit-space q. The curve is
// v = 1; v > 1 is outside. Used by the inverted-corner shaders.
function field(qx, qy, n) {
    return Math.pow(Math.abs(qx), n) + Math.pow(Math.abs(qy), n);
}

// Approximate pixel-space SDF of a squircle rounded box, for host-side
// geometry (masks, hit-testing). Mirrors sdSquircleBox4 in GLSL.
function sdBox(px, py, hw, hh, r, n) {
    var rt = px > 0 ? r[1] : r[0];
    var rb = px > 0 ? r[2] : r[3];
    var rad = py > 0 ? rb : rt;
    var ax = Math.abs(px), ay = Math.abs(py);
    var cx = hw - rad, cy = hh - rad;
    if (rad > 0.01 && ax > cx && ay > cy) {
        if (n <= 2.001)
            return Math.hypot(ax - cx, ay - cy) - rad; // exact circle
        var qx = (ax - cx) / rad, qy = (ay - cy) / rad;
        var n2 = 2 * n - 2;
        var num = Math.pow(qx, n) + Math.pow(qy, n) - 1;
        var den = n * Math.sqrt(Math.pow(qx, n2) + Math.pow(qy, n2)) + 0.0001;
        return num / den * rad;
    }
    var q2x = ax - hw + rad, q2y = ay - hh + rad;
    return Math.min(Math.max(q2x, q2y), 0) + Math.hypot(Math.max(q2x, 0), Math.max(q2y, 0)) - rad;
}

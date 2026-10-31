.pragma library

// Twemoji asset name for an emoji string: lowercase hex codepoints joined by
// "-", with U+FE0F dropped. The bundled set is named from the emoji without
// the presentation selector, so "🏳️‍🌈" resolves to 1f3f3-200d-1f308.
function assetName(emoji) {
    if (!emoji)
        return "";

    var out = [];
    for (var i = 0; i < emoji.length; i++) {
        var c = emoji.charCodeAt(i);
        if (c === 0xFE0F)
            continue;

        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < emoji.length) {
            var d = emoji.charCodeAt(i + 1);
            if (d >= 0xDC00 && d <= 0xDFFF) {
                c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00);
                i++;
            }
        }
        out.push(c.toString(16));
    }
    return out.join("-");
}

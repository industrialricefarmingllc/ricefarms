.pragma library

// Twemoji inline for text that Qt renders as rich text. The bundled asset set
// uses lowercase hex codepoints (FE0F dropped), e.g. 1f600 or 1f1fa-1f1f8.
//
// Discord messages mix two more kinds of emoji into that text:
// - real custom emoji tags, <:name:id> and <a:name:id>
// - the links Vencord/Equicord's FakeNitro sends, either
//   [name](https://cdn.discordapp.com/emojis/id.webp?...) or the bare URL
// Both become the CDN image a Discord client would paint.

function isRegional(cp) {
    return cp >= 0x1F1E6 && cp <= 0x1F1FF;
}

function isModifier(cp) {
    return cp >= 0x1F3FB && cp <= 0x1F3FF;
}

function isEmoji(cp) {
    return (cp >= 0x1F000 && cp <= 0x1FAFF)
        || (cp >= 0x2600 && cp <= 0x27BF)
        || (cp >= 0x2B00 && cp <= 0x2BFF)
        || cp === 0x00A9 || cp === 0x00AE || cp === 0x203C || cp === 0x2049
        || cp === 0x2122 || cp === 0x2139
        || (cp >= 0x2194 && cp <= 0x2199) || (cp >= 0x21A9 && cp <= 0x21AA)
        || (cp >= 0x231A && cp <= 0x231B) || cp === 0x2328 || cp === 0x23CF
        || (cp >= 0x23E9 && cp <= 0x23F3) || (cp >= 0x23F8 && cp <= 0x23FA)
        || cp === 0x24C2 || (cp >= 0x25AA && cp <= 0x25AB)
        || cp === 0x25B6 || cp === 0x25C0 || (cp >= 0x25FB && cp <= 0x25FE)
        || (cp >= 0x2934 && cp <= 0x2935) || (cp >= 0x2B05 && cp <= 0x2B07)
        || cp === 0x3030 || cp === 0x303D || cp === 0x3297 || cp === 0x3299
        || cp === 0xFE0F || cp === 0x20E3 || cp === 0x200D;
}

function codePointLength(cp) {
    return cp > 0xFFFF ? 2 : 1;
}

// End index of the emoji sequence starting at i: modifiers, variation
// selectors, keycaps, regional pairs and ZWJ joiners belong to it.
function scanRun(text, i) {
    var cp = text.codePointAt(i);
    var j = i + codePointLength(cp);
    while (j < text.length) {
        var next = text.codePointAt(j);
        var nextLength = codePointLength(next);
        if (isModifier(next) || next === 0xFE0F || next === 0x20E3) {
            j += nextLength;
            continue;
        }
        if (next === 0x200D) {
            j += nextLength;
            if (j < text.length) {
                var joined = text.codePointAt(j);
                j += codePointLength(joined);
            }
            continue;
        }
        if (isRegional(cp) && isRegional(next))
            j += nextLength;

        break;
    }
    return j;
}

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

function escapeHtml(text) {
    return String(text || "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
}

function escapeAttr(text) {
    return escapeHtml(text).replace(/'/g, "&#39;");
}

// HTML-safe input (already escaped/linkified) -> HTML with Twemoji <img> tags.
// `images` receives one entry per emitted <img>, in document order, so callers
// can overlay animations on the exact inline positions.
function emojiHtml(html, size, base, images) {
    var text = String(html || "");
    var out = "";
    var box = Math.round(size);
    var i = 0;
    while (i < text.length) {
        var cp = text.codePointAt(i);
        var length = codePointLength(cp);
        if (!isEmoji(cp)) {
            out += text.substr(i, length);
            i += length;
            continue;
        }

        var j = scanRun(text, i);
        var run = text.substr(i, j - i);
        var asset = assetName(run);
        if (asset !== "") {
            // Height only: Qt then keeps the image's own aspect ratio instead
            // of stretching it into a square slot.
            out += '<img src="' + base + asset + '.svg" height="' + box + '" align="middle">';
            if (images)
                images.push({animated: false, box: box});
        } else {
            out += run;
        }

        i = j;
    }
    return out;
}

// ------------------------------------------------------------- Discord emoji
// A custom emoji the CDN can paint, from a /emojis/<id>.<ext> link.
function emojiFromUrl(url) {
    var target = String(url || "");
    var match = target.match(/^https?:\/\/(?:cdn\.discordapp\.com|media\.discordapp\.net)\/emojis\/(\d+)\.(png|webp|gif)(?:[?#]|$)/i);
    if (!match)
        return null;

    var animated = match[2].toLowerCase() === "gif";
    if (/[?&]animated=true(?:&|$)/i.test(target))
        animated = true;

    var name = "";
    var named = target.match(/[?&]name=([^&]+)/);
    if (named) {
        try {
            name = decodeURIComponent(named[1]);
        } catch (error) {
            name = named[1];
        }
    }
    return {id: match[1], animated: animated, name: name};
}

// WebP is not available in this Qt build, and animated emoji keep their GIF.
// Ask the CDN for the PNG/GIF form a Discord client uses.
function emojiImage(id, animated, name, box, images, transparent) {
    var px = Math.max(1, Math.round(box));
    var source = px <= 24 ? 64 : (px <= 48 ? 128 : 256);
    var url = "https://cdn.discordapp.com/emojis/" + id
        + (animated ? ".gif" : ".png") + "?size=" + source;

    // Animated emoji get a transparent square placeholder, not the GIF's first
    // frame: the live AnimatedImage is the only thing that paints the emoji, so
    // a transparent frame cannot show through a later transparent frame.
    // A static preview (comment snippet) passes no transparent source, so it
    // keeps the GIF's first frame. Static emoji keep the height-only image so
    // their own aspect is preserved.
    var src = animated && String(transparent || "") !== "" ? String(transparent) : url;
    var html = '<img src="' + src + '" height="' + px + '" align="middle"';

    var label = name ? ":" + name + ":" : "";
    if (label !== "")
        html += ' title="' + escapeAttr(label) + '" alt="' + escapeAttr(label) + '"';

    if (images)
        images.push({animated: animated === true, box: px, url: url});
    return html + ">";
}

// A fragment only owns indentation when it starts a raw line; spaces after an
// inline emoji must stay breakable.
function atLineStart(text, index) {
    return index === 0 || String(text || "").charAt(index - 1) === "\n";
}

function isEmojiCdn(url) {
    return emojiFromUrl(url) !== null;
}

function trimUrl(url) {
    return String(url || "").replace(/[.,;:!?]+$/, "");
}

// Discord enlarges a message that holds at most 27 emoji and nothing else.
// Returns the emoji count for such a message, or 0 for ordinary text.
function scanJumbo(text) {
    var rest = String(text || "").trim();
    if (rest === "")
        return 0;

    var count = 0;
    rest = rest
        .replace(/(\\)?<a?:[A-Za-z0-9_]+:(\d+)>/g, function (match, slash) {
            if (slash)
                return match;
            count++;
            return "";
        })
        .replace(/\[[^\]]*\]\((https?:\/\/[^\s)]+)\)/g, function (match, url) {
            if (emojiFromUrl(url)) {
                count++;
                return "";
            }
            return match;
        })
        .replace(/https?:\/\/[^\s<>"']+/g, function (url) {
            if (emojiFromUrl(trimUrl(url))) {
                count++;
                return "";
            }
            return url;
        });

    var i = 0;
    while (i < rest.length) {
        var cp = rest.codePointAt(i);
        var length = codePointLength(cp);
        if (cp === 0x20 || cp === 0x09 || cp === 0x0A || cp === 0x0D) {
            i += length;
            continue;
        }
        if (!isEmoji(cp) || cp === 0xFE0F || cp === 0x200D)
            return 0;

        i = scanRun(rest, i);
        count++;
    }
    return count > 0 && count <= 27 ? count : 0;
}

// One ordinary text run: escape, keep leading spaces, break lines, and turn
// Unicode emoji into Twemoji.
function plainText(text, box, base, linkify, linkColor, atLineStart, images) {
    var safe = escapeHtml(text);
    if (linkify) {
        safe = safe.replace(/(https?:\/\/[^\s<>"']+)/g, function (url) {
            return '<a href="' + url + '" style="color:' + linkColor + '">' + url + '</a>';
        });
    }
    safe = safe.replace(/\n( +)/g, function (match, spaces) {
        return "\n" + spaces.replace(/ /g, "&nbsp;");
    });
    if (atLineStart) {
        safe = safe.replace(/^ +/, function (spaces) {
            return spaces.replace(/ /g, "&nbsp;");
        });
    }
    safe = safe.replace(/\n/g, "<br>");
    return emojiHtml(safe, box, base, images);
}

// Raw Discord text -> rich HTML with Twemoji, custom emoji images and, when
// linkify is on, clickable links. This is the whole body renderer; keeping the
// token scan in one pass means an emoji tag or FakeNitro link can never be
// escaped or linkified as literal text first.
// Also returns the emitted images in document order; animated custom emoji
// carry their GIF URL so a TextEdit can overlay a live AnimatedImage.
function discordParts(text, size, base, transparent, linkify, linkColor, allowJumbo) {
    var raw = String(text || "");
    var box = (allowJumbo !== false && scanJumbo(raw) > 0) ? Math.round(size * 2.8) : Math.round(size);
    var color = String(linkColor || "#000000");
    var out = "";
    var images = [];
    var last = 0;
    var token = /(\\)?<(a?):([A-Za-z0-9_]+):(\d+)>|\[([^\]]*)\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<>"']+)/g;
    var match;
    while ((match = token.exec(raw)) !== null) {
        out += plainText(raw.slice(last, match.index), box, base, false, color, atLineStart(raw, last), images);
        last = token.lastIndex;

        if (match[4] !== undefined) {
            if (match[1] === "\\")
                out += plainText(match[0].slice(1), box, base, false, color, false, images);
            else
                out += emojiImage(match[4], match[2] === "a", match[3], box, images, transparent);
            continue;
        }

        if (match[6] !== undefined) {
            var linked = emojiFromUrl(match[6]);
            if (linked)
                out += emojiImage(linked.id, linked.animated, linked.name || match[5], box, images, transparent);
            else if (linkify)
                out += '<a href="' + escapeAttr(match[6]) + '" style="color:' + color + '">' + plainText(match[5], box, base, false, color, false, images) + '</a>';
            else
                out += plainText(match[5], box, base, false, color, false, images);
            continue;
        }

        if (match[7] !== undefined) {
            var bare = trimUrl(match[7]);
            var bareEmoji = emojiFromUrl(bare);
            if (bareEmoji)
                out += emojiImage(bareEmoji.id, bareEmoji.animated, bareEmoji.name, box, images, transparent);
            else if (linkify)
                out += '<a href="' + escapeAttr(bare) + '" style="color:' + color + '">' + plainText(bare, box, base, false, color, false, images) + '</a>';
            else
                out += plainText(bare, box, base, false, color, false, images);

            out += plainText(match[7].slice(bare.length), box, base, false, color, false, images);
            continue;
        }
    }

    out += plainText(raw.slice(last), box, base, false, color, false, images);
    return {html: out, images: images};
}

function discord(text, size, base, transparent, linkify, linkColor, allowJumbo) {
    return discordParts(text, size, base, transparent, linkify, linkColor, allowJumbo).html;
}

function rich(text, size, base) {
    var safe = escapeHtml(text)
        .replace(/\n/g, "<br>")
        .replace(/^ +/gm, function (spaces) {
            return spaces.replace(/ /g, "&nbsp;");
        });
    return emojiHtml(safe, size, base);
}

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

// A digit, # or * followed by an optional FE0F and U+20E3 is one keycap emoji.
// It must be consumed from the leading character; starting at FE0F would emit
// the base character as text and a lone combining keycap image.
function isKeycapStart(text, i) {
    var cp = text.codePointAt(i);
    if (cp !== 0x23 && cp !== 0x2A && (cp < 0x30 || cp > 0x39))
        return false;
    var j = i + codePointLength(cp);
    if (text.codePointAt(j) === 0xFE0F)
        j++;
    return text.codePointAt(j) === 0x20E3;
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
function emojiHtml(html, size, base, images, transparent) {
    var text = String(html || "");
    var out = "";
    var box = Math.round(size);
    var i = 0;
    while (i < text.length) {
        var cp = text.codePointAt(i);
        var length = codePointLength(cp);
        if (!isEmoji(cp) && !isKeycapStart(text, i)) {
            out += text.substr(i, length);
            i += length;
            continue;
        }

        var j = scanRun(text, i);
        var run = text.substr(i, j - i);
        var asset = assetName(run);
        if (asset !== "") {
            // Height only: Qt then keeps the image's own aspect ratio instead
            // of stretching it into a square slot. The body passes a
            // transparent placeholder and paints the emoji as a live Twemoji
            // item, so rich text never has to upscale the SVG's 36 px raster.
            var source = String(transparent || "") !== "" ? String(transparent) : base + asset + ".svg";
            out += '<img src="' + source + '" width="' + box + '" height="' + box
                + '" align="middle">';
            if (images)
                images.push({animated: false, box: box, emoji: run});
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
        if ((!isEmoji(cp) && !isKeycapStart(rest, i)) || cp === 0xFE0F || cp === 0x200D)
            return 0;

        i = scanRun(rest, i);
        count++;
    }
    return count > 0 && count <= 27 ? count : 0;
}

// One ordinary text run: escape, keep leading spaces, break lines, and turn
// Unicode emoji into Twemoji. Markdown has already reduced the text around it
// to HTML tags, so this only has to deal with literal characters.
function plainTextRaw(text, box, base, linkify, linkColor, lineStart, images, transparent) {
    var safe = escapeHtml(text);
    // Handles are links even where URLs are not linkified (token runs render
    // with linkify disabled). The guard avoids an @ inside a URL path.
    safe = safe.replace(/(^|[\s(])@([A-Za-z0-9_]{1,15})(?=$|[\s.,!?;:)])/g, function (match, before, handle) {
        return before + '<a href="profile:@' + handle + '" style="color:' + linkColor + '">@' + handle + '</a>';
    });
    if (linkify) {
        safe = safe.replace(/(https?:\/\/[^\s<>"']+)/g, function (url) {
            return '<a href="' + url + '" style="color:' + linkColor + '">' + url + '</a>';
        });
    }
    safe = safe.replace(/\n( +)/g, function (match, spaces) {
        return "\n" + spaces.replace(/ /g, "&nbsp;");
    });
    if (lineStart) {
        safe = safe.replace(/^ +/, function (spaces) {
            return spaces.replace(/ /g, "&nbsp;");
        });
    }
    safe = safe.replace(/\n/g, "<br>");
    return emojiHtml(safe, box, base, images, transparent);
}

var ESCAPABLE = "\\`*_{}[]()#+-.!~>|";

function markdownClose(text, from, marker, underscore) {
    var index = text.indexOf(marker, from);
    while (index >= 0) {
        var before = text.charAt(index - 1);
        var after = text.charAt(index + marker.length);
        if (index > from && before !== "" && !/\s/.test(before)) {
            if (!underscore || after === "" || !/[A-Za-z0-9]/.test(after))
                return index;
        }
        index = text.indexOf(marker, index + marker.length);
    }
    return -1;
}

function markdownInline(text, box, base, transparent, linkify, linkColor, atStart, images, style) {
    var raw = String(text || "");
    var colors = style || {};
    var codeBg = String(colors.codeBg || "#2a2a31");
    var codeText = String(colors.codeText || "#e8e8ea");
    var out = "";
    var buffer = "";
    var first = atStart === true;

    function flush() {
        if (buffer !== "") {
            out += inlineTokens(buffer, box, base, transparent, linkify, linkColor, images, style, first);
            buffer = "";
        }
        first = false;
    }

    var i = 0;
    while (i < raw.length) {
        var ch = raw.charAt(i);
        if (ch === "\\" && i + 1 < raw.length && ESCAPABLE.indexOf(raw.charAt(i + 1)) >= 0) {
            buffer += raw.charAt(i + 1);
            i += 2;
            continue;
        }

        // Inline code is literal: no emphasis, links or emoji inside it.
        if (ch === "`") {
            var codeEnd = raw.indexOf("`", i + 1);
            if (codeEnd > i + 1) {
                flush();
                out += '<code style="font-family: monospace; font-style:normal; background-color:' + codeBg
                    + '; color:' + codeText + '">' + escapeHtml(raw.slice(i + 1, codeEnd)) + '</code>';
                i = codeEnd + 1;
                continue;
            }
        }

        // Keep a quoted reply's media in the quote block. Discord shows the
        // referenced attachment there; a plain link would lose it.
        if (ch === "!" && raw.charAt(i + 1) === "[") {
            var picture = /^!\[([^\]]*)\]\(((?:https?|file):\/\/[^\s)]+)\)/.exec(raw.substr(i));
            if (picture) {
                flush();
                // Width-only keeps the image's aspect ratio and, unlike a
                // height-only embed, cannot run past the narrow quote column.
                var pictureWidth = Math.min(200, Math.max(120, Math.round(box * 7)));
                out += '<img src="' + escapeAttr(picture[2]) + '" alt="' + escapeAttr(picture[1] || "media")
                    + '" width="' + pictureWidth + '" align="middle">';
                i += picture[0].length;
                continue;
            }
        }

        // A Markdown link is parsed before emphasis so **bold labels** work.
        // Equicord/Vencord wrap a fake emoji as [name](cdn-url), which is the
        // emoji itself, not a link: paint it the same as a bare CDN link.
        if (ch === "[") {
            var link = /^\[([^\]]*)\]\((https?:\/\/[^\s)]+)\)/.exec(raw.substr(i));
            if (link) {
                flush();
                var linkedEmoji = emojiFromUrl(link[2]);
                if (linkedEmoji)
                    out += emojiImage(linkedEmoji.id, linkedEmoji.animated, linkedEmoji.name || link[1], box, images, transparent);
                else
                    out += '<a href="' + escapeAttr(link[2]) + '" style="color:' + linkColor + '">'
                        + markdownInline(link[1], box, base, transparent, linkify, linkColor, false, images, style)
                        + '</a>';
                i += link[0].length;
                continue;
            }
        }

        // A URL is opaque. Underscores and asterisks in a path are not markup.
        if ((ch === "h" || ch === "H") && /^https?:\/\//i.test(raw.substr(i))) {
            var url = /^https?:\/\/[^\s<>"']+/i.exec(raw.substr(i));
            if (url) {
                buffer += url[0];
                i += url[0].length;
                continue;
            }
        }

        var marker = "";
        var tag = "";
        var underscore = false;
        var rest = raw.substr(i);
        if ((rest.indexOf("***") === 0 || rest.indexOf("___") === 0)
            && i + 3 < raw.length && !/\s/.test(raw.charAt(i + 3))) {
            marker = rest.substr(0, 3);
            tag = "both";
            underscore = marker.charAt(0) === "_";
        } else if ((rest.indexOf("**") === 0 || rest.indexOf("__") === 0)
            && i + 2 < raw.length && !/\s/.test(raw.charAt(i + 2))) {
            marker = rest.substr(0, 2);
            // Discord writes __underlined__; standard Markdown readers often
            // write __bold__. Underline is the convention this client shows.
            tag = marker === "__" ? "u" : "b";
            underscore = marker === "__";
        } else if (rest.indexOf("~~") === 0 && i + 2 < raw.length && !/\s/.test(raw.charAt(i + 2))) {
            marker = "~~";
            tag = "s";
        } else if ((ch === "*" || ch === "_") && i + 1 < raw.length && !/\s/.test(raw.charAt(i + 1))) {
            marker = ch;
            tag = "i";
            underscore = ch === "_";
        }

        if (marker !== "" && underscore && i > 0 && /[A-Za-z0-9]/.test(raw.charAt(i - 1)))
            marker = "";

        if (marker !== "") {
            var close = markdownClose(raw, i + marker.length, marker, underscore);
            if (close > i) {
                flush();
                var inner = markdownInline(raw.slice(i + marker.length, close), box, base, transparent,
                    linkify, linkColor, false, images, style);
                if (tag === "both")
                    out += "<b><i>" + inner + "</i></b>";
                else
                    out += "<" + tag + ">" + inner + "</" + tag + ">";
                i = close + marker.length;
                continue;
            }
        }

        buffer += ch;
        i++;
    }
    flush();
    return out;
}

function plainText(text, box, base, linkify, linkColor, atStart, images, style) {
    return markdownInline(text, box, base, "", linkify, linkColor, atStart, images, style);
}

function inlineTokens(text, box, base, transparent, linkify, color, images, style, atStart) {
    var raw = String(text || "");
    var out = "";
    var last = 0;
    // Emoji tags, Markdown links and bare URLs are tokenised after emphasis has
    // been resolved. A URL is kept intact by markdownInline, so its underscores
    // cannot turn into italics.
    var token = /(\\)?<(a?):([A-Za-z0-9_]+):(\d+)>|\[([^\]]*)\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<>"']+)/g;
    var match;

    function literal(value, start) {
        return plainTextRaw(value, box, base, false, color,
            start === 0 ? atStart : atLineStart(raw, start), images, transparent);
    }

    while ((match = token.exec(raw)) !== null) {
        out += literal(raw.slice(last, match.index), last);
        last = token.lastIndex;

        if (match[4] !== undefined) {
            if (match[1] === "\\")
                out += plainTextRaw(match[0].slice(1), box, base, false, color, false, images, transparent);
            else
                out += emojiImage(match[4], match[2] === "a", match[3], box, images, transparent);
            continue;
        }

        if (match[6] !== undefined) {
            var linked = emojiFromUrl(match[6]);
            if (linked)
                out += emojiImage(linked.id, linked.animated, linked.name || match[5], box, images, transparent);
            else if (linkify)
                out += '<a href="' + escapeAttr(match[6]) + '" style="color:' + color + '">'
                    + markdownInline(match[5], box, base, transparent, false, color, false, images, style) + '</a>';
            else
                out += markdownInline(match[5], box, base, transparent, false, color, false, images, style);
            continue;
        }

        if (match[7] !== undefined) {
            var bare = trimUrl(match[7]);
            var bareEmoji = emojiFromUrl(bare);
            if (bareEmoji)
                out += emojiImage(bareEmoji.id, bareEmoji.animated, bareEmoji.name, box, images, transparent);
            else if (linkify)
                out += '<a href="' + escapeAttr(bare) + '" style="color:' + color + '">'
                    + plainTextRaw(bare, box, base, false, color, false, images, transparent) + '</a>';
            else
                out += plainTextRaw(bare, box, base, false, color, false, images, transparent);

            out += plainTextRaw(match[7].slice(bare.length), box, base, false, color, false, images, transparent);
            continue;
        }
    }

    out += literal(raw.slice(last), last);
    return out;
}

function inlineSegment(raw, box, base, transparent, linkify, color, images, style) {
    return markdownInline(raw, box, base, transparent, linkify, color, true, images, style);
}

function fenceAt(line) {
    var match = /^\s{0,3}(`{3,}|~{3,})(.*)$/.exec(String(line || ""));
    if (!match)
        return null;
    return {char: match[1].charAt(0), length: match[1].length, info: match[2].trim()};
}

function quoteAt(line) {
    var match = /^\s{0,3}>\s?(.*)$/.exec(String(line || ""));
    return match ? match[1] : null;
}

function headingAt(line) {
    return /^\s{0,3}(#{1,6})\s+(.*)$/.exec(String(line || ""));
}

function ruleAt(line) {
    return /^\s{0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$/.test(String(line || ""));
}

function listAt(line) {
    var match = /^\s{0,3}([-+*]|\d{1,9}[.)])\s+(.*)$/.exec(String(line || ""));
    if (!match)
        return null;
    return {marker: match[1], ordered: /^\d/.test(match[1]), content: match[2]};
}

function blockStarts(line) {
    return fenceAt(line) !== null || quoteAt(line) !== null || headingAt(line) !== null
        || ruleAt(line) || listAt(line) !== null;
}

function quoteBlock(html, style) {
    // The empty bar cell stretches to the table row's height, so the line
    // covers every wrapped line and the padding around them. No background:
    // the quote is distinguished by the bar and the reduced text opacity.
    return '<br><table cellspacing="0" cellpadding="0" width="100%"><tr>'
        + '<td width="3" bgcolor="' + style.quoteBar + '"></td>'
        + '<td style="padding-left:10px; padding-top:4px; padding-bottom:4px; font-style:italic">'
        + '<span style="color:' + style.quoteText + '; font-style:italic">' + html + '</span>'
        + '</td></tr></table>';
}

function codeBlock(text, style) {
    var safe = escapeHtml(text)
        .replace(/\t/g, "&nbsp;&nbsp;&nbsp;&nbsp;")
        .replace(/ /g, "&nbsp;")
        .replace(/\n/g, "<br>");
    return '<br><table cellspacing="0" cellpadding="0" width="100%"><tr>'
        + '<td bgcolor="' + style.codeBg + '" style="padding:8px">'
        + '<span style="font-family: monospace; color:' + style.codeText + '">' + safe + '</span>'
        + '</td></tr></table><br>';
}

function renderBlocks(raw, box, base, transparent, linkify, color, images, style, fontSize, depth) {
    var lines = String(raw || "").replace(/\r\n?/g, "\n").split("\n");
    var out = [];
    var i = 0;
    while (i < lines.length) {
        var line = lines[i];
        var fence = fenceAt(line);
        if (fence !== null) {
            var code = [];
            i++;
            while (i < lines.length) {
                var close = /^\s{0,3}(`{3,}|~{3,})\s*$/.exec(lines[i]);
                if (close && close[1].charAt(0) === fence.char && close[1].length >= fence.length) {
                    i++;
                    break;
                }
                code.push(lines[i]);
                i++;
            }
            out.push(codeBlock(code.join("\n"), style));
            continue;
        }

        var quoted = quoteAt(line);
        if (quoted !== null) {
            var quote = [];
            while (i < lines.length) {
                var next = quoteAt(lines[i]);
                if (next === null)
                    break;
                quote.push(next);
                i++;
            }
            var quoteHtml = "";
            var rows = [];
            for (var q = 0; q < quote.length; q++)
                rows.push(inlineSegment(quote[q], box, base, transparent, linkify, color, images, style));
            quoteHtml = rows.join("<br>");
            out.push(quoteBlock(quoteHtml, style));
            continue;
        }

        var heading = headingAt(line);
        if (heading !== null) {
            var level = heading[1].length;
            var scale = [0, 1.5, 1.32, 1.2, 1.12, 1.06, 1.0][level];
            var px = Math.max(1, Math.round(fontSize * scale));
            out.push('<br><span style="font-size:' + px + 'px; font-weight:600">'
                + inlineSegment(heading[2], box, base, transparent, linkify, color, images, style)
                + '</span><br>');
            i++;
            continue;
        }

        if (ruleAt(line)) {
            out.push('<hr>');
            i++;
            continue;
        }

        var item = listAt(line);
        if (item !== null) {
            var ordered = item.ordered;
            var parts = [];
            while (i < lines.length) {
                var entry = listAt(lines[i]);
                if (entry === null || entry.ordered !== ordered)
                    break;
                var content = entry.content;
                var task = /^\[([ xX])\]\s+(.*)$/.exec(content);
                if (task) {
                    content = (task[1].toLowerCase() === "x" ? "☑ " : "☐ ") + task[2];
                }
                parts.push("<li>" + inlineSegment(content, box, base, transparent, linkify, color, images, style) + "</li>");
                i++;
            }
            out.push("<" + (ordered ? "ol" : "ul") + ">" + parts.join("") + "</" + (ordered ? "ol" : "ul") + ">");
            continue;
        }

        if (String(line).trim() === "") {
            out.push("<br>");
            i++;
            continue;
        }

        var paragraph = [line];
        i++;
        while (i < lines.length && String(lines[i]).trim() !== "" && !blockStarts(lines[i])) {
            paragraph.push(lines[i]);
            i++;
        }
        var rendered = [];
        for (var p = 0; p < paragraph.length; p++)
            rendered.push(inlineSegment(paragraph[p], box, base, transparent, linkify, color, images, style));
        out.push(rendered.join("<br>"));
    }

    return out.join("").replace(/^<br>/, "").replace(/(<br>){3,}/g, "<br><br>").replace(/(?:<br>)+$/, "");
}

function renderInline(raw, box, base, transparent, linkify, color, images, style) {
    var lines = String(raw || "").replace(/\r\n?/g, "\n").split("\n");
    var out = [];
    for (var i = 0; i < lines.length; i++)
        out.push(inlineSegment(lines[i], box, base, transparent, linkify, color, images, style));
    return out.join("<br>").replace(/(<br>){3,}/g, "<br><br>");
}

function defaultColors(colors) {
    var style = colors || {};
    return {
        quoteBar: String(style.quoteBar || "#7aa2f7"),
        quoteText: String(style.quoteText || "rgba(232,232,234,0.6)"),
        codeBg: String(style.codeBg || "#2a2a31"),
        codeText: String(style.codeText || "#e8e8ea"),
        rule: String(style.rule || "#4a4a52")
    };
}

// Raw Discord text -> rich HTML with Markdown, Twemoji, custom emoji images
// and, when linkify is on, clickable links. Keeping the token scan in one pass
// means an emoji tag or FakeNitro link can never be escaped or linkified as
// literal text first. Also returns the emitted images in document order.
function discordParts(text, size, base, transparent, linkify, linkColor, allowJumbo, colors, fontSize) {
    var raw = String(text || "");
    var box = (allowJumbo !== false && scanJumbo(raw) > 0) ? Math.round(size * 2.8) : Math.round(size);
    var color = String(linkColor || "#000000");
    var style = defaultColors(colors);
    var images = [];
    var font = Number(fontSize || size || 0);
    var html = allowJumbo === false
        ? renderInline(raw, box, base, transparent, linkify, color, images, style)
        : renderBlocks(raw, box, base, transparent, linkify, color, images, style, font, 0);
    return {html: html, images: images};
}

function discord(text, size, base, transparent, linkify, linkColor, allowJumbo, colors, fontSize) {
    return discordParts(text, size, base, transparent, linkify, linkColor, allowJumbo, colors, fontSize).html;
}

function rich(text, size, base, colors, fontSize) {
    var style = defaultColors(colors);
    var images = [];
    var box = Math.round(size);
    return renderBlocks(String(text || ""), box, base, "", false, "#000000", images, style, Number(fontSize || size || 0), 0);
}

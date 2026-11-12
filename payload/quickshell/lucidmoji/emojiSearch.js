.pragma library

// Shared by the LucidMoji picker and the social composer's inline `:name:`
// suggestions. Two rankings live here because the pickers are used differently:
//
// - wordStarts is LucidMoji's original name-first ranking (start of name, then
//   word starts in the name, then keyword hits).
// - matches is the launcher/dock ranking used inline: every query word is a
//   substring of the normalized name+guild+keywords haystack (or its compact
//   form), server emoji come first, and results are ordered by usage count.
function normalize(value) {
    return String(value || "").toLowerCase().replace(/[-_\s]+/g, " ").trim();
}

function wordStarts(data, query, limit) {
    var q = String(query || "").trim().toLowerCase().replace(/^:+|:+$/g, "");
    if (q === "")
        return [];

    var starts = [];
    var words = [];
    var rest = [];
    var anchored = " " + q;
    for (var i = 0; i < (data || []).length; i++) {
        var entry = data[i];
        if (!entry)
            continue;
        var name = String(entry.n || "").toLowerCase();
        var keyword = String(entry.s || (name + " " + String(entry.k || ""))).toLowerCase();
        if (name.indexOf(q) === 0)
            starts.push(entry);
        else if ((" " + name).indexOf(anchored) !== -1)
            words.push(entry);
        else if ((" " + keyword).indexOf(anchored) !== -1)
            rest.push(entry);
    }
    var out = starts.concat(words, rest);
    return limit && limit > 0 ? out.slice(0, limit) : out;
}

function matches(data, query, limit, counts) {
    var q = normalize(String(query || "").replace(/^:+|:+$/g, ""));
    if (q === "")
        return [];

    var words = q.split(" ").filter(function (word) {
        return word !== "";
    });
    if (words.length === 0)
        return [];

    var found = [];
    for (var i = 0; i < (data || []).length; i++) {
        var entry = data[i];
        if (!entry)
            continue;
        var hay = String(entry.hay || normalize(String(entry.n || "") + " " + String(entry.k || "") + " " + String(entry.s || "")));
        var compact = String(entry.hayCompact || hay.replace(/ /g, ""));
        var hit = true;
        for (var w = 0; w < words.length; w++) {
            if (hay.indexOf(words[w]) === -1 && compact.indexOf(words[w]) === -1) {
                hit = false;
                break;
            }
        }
        if (hit)
            found.push(entry);
    }

    // Same ordering as the launcher's emoji wall: server emoji first, then the
    // most-used entries, then name and stable key.
    var usage = counts || ({});
    found.sort(function (a, b) {
        var ac = a.custom === true ? 0 : 1;
        var bc = b.custom === true ? 0 : 1;
        if (ac !== bc)
            return ac - bc;

        var au = Number(usage[a.u] || 0);
        var bu = Number(usage[b.u] || 0);
        if (au !== bu)
            return bu - au;

        var an = String(a.n || "").toLowerCase();
        var bn = String(b.n || "").toLowerCase();
        if (an !== bn)
            return an < bn ? -1 : 1;

        var ak = String(a.u || "");
        var bk = String(b.u || "");
        return ak < bk ? -1 : (ak > bk ? 1 : 0);
    });
    return limit && limit > 0 ? found.slice(0, limit) : found;
}

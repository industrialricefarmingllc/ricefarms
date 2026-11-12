import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs
import qs.lucidui
import "../squircle"
import "social"
import "social/emoji.js" as SocialEmoji
import "../lucidmoji/emojiSearch.js" as EmojiSearch

// A tweet-like feed over the canonical lucid.social/feed@1 format.
//
// Everything source-specific happens in ~/src/lucid-social.  This card only
// knows posts, comments, media and streams, which is why another source can be
// added behind it without touching QML.
WidgetBody {
    id: w

    // The Social card reads as a solid surface, not a stack of translucent
    // tints. Tone overrides stay opaque too, because toneFill alone carries
    // the shell's glass alpha.
    fill: {
        switch (w.tone) {
        case "primary":
            return Theme.primaryContainer;
        case "secondary":
            return Theme.secondaryContainer;
        case "tertiary":
            return Theme.tertiaryContainer;
        }
        return Theme.surfaceContainer;
    }

    readonly property string home: Quickshell.env("HOME")
    readonly property string service: {
        var configured = Quickshell.env("LUCID_SOCIAL_BIN");
        if (configured !== undefined && configured !== null && String(configured) !== "")
            return String(configured);

        return w.home + "/src/lucid-social/bin/lucid-social";
    }
    readonly property string schemaFeed: "lucid.social/feed"
    readonly property int schemaVersion: 1
    readonly property int feedLimit: 20

    // Per-card selection.  Off-lists rather than on-lists, so a new stream that
    // appears later starts on, while every explicit choice is still remembered.
    readonly property var offSources: w.listOpt("socialSourcesOff")
    readonly property var offStreams: w.listOpt("socialStreamsOff")
    readonly property var onStreams: w.listOpt("socialStreamsOn")
    readonly property var hiddenItems: w.listOpt("socialHidden")

    property var sources: []
    property var items: []
    property var feedErrors: []
    // loading | ready | empty | failed
    property string phase: "loading"
    property string fatal: ""
    property string actionError: ""
    property bool streamsLoading: false
    property bool refreshing: false
    property bool booted: false
    property bool feedDirty: false
    property bool feedDirtyRefresh: false
    property bool feedAppend: false
    property bool feedLoadingMore: false
    property bool feedAtEnd: false
    property bool feedMorePending: false
    property int feedRequestLimit: 0
    property bool pickerOpen: false
    property bool newPostOpen: false
    property var sendTargets: []
    property bool sendTargetsLoading: false
    property string sendTargetId: ""
    property string sendTargetAccount: ""
    property string sendTargetTitle: ""
    property string sendTargetGuild: ""
    property string newPostError: ""
    property bool sending: false
    property string newPostLocalId: ""
    property string newPostBody: ""
    property var newPostImages: []
    property string detailId: ""
    property var detailPost: null
    property var comments: []
    property bool commentsLoading: false
    property string commentsError: ""
    property var contextComments: []
    property string contextCursor: ""
    property bool contextLoading: false
    property bool contextHasMore: false
    property bool contextReady: false
    property int contextSeq: 0
    property int pendingContextSeq: 0
    property real contextHeightBefore: 0
    property real contextYBefore: 0
    property real contextAnchorY: 0
    property real contextAnchorHeight: 0
    property bool contextAnchorPending: false
    property bool threadOpening: false
    property bool threadLoaded: false
    property bool contextLoaded: false
    property bool threadAutoScrolling: false
    property bool threadScrollRestarting: false
    property int threadLimit: 20
    property bool nestedFilled: false
    // Replies to a reply stay hidden until their parent is explicitly expanded.
    property int branchPreviewLimit: 0
    property var expandedBranches: ({})
    readonly property var commentView: w.buildCommentView()
    property string replyTo: ""
    property string replyName: ""
    property string composeError: ""
    // One entry per in-flight comment. Each send owns a row in `comments`
    // from the moment Enter is pressed, so several can be in flight at once.
    property var commentJobs: []
    property int pendingSeq: 0
    property var likeQueue: []
    property string authBusyKey: ""
    property string authError: ""
    property string authStatus: ""
    property var seenPostIds: ({})
    property bool discordEventsReady: false
    property bool openThreadReady: false
    property bool mediaViewerOpen: false
    property var mediaViewerValue: null
    property rect mediaViewerFrom: Qt.rect(0, 0, 0, 0)
    property var mediaViewerScreen: null
    // The exact texture the card already decoded, painted under the full-res
    // image while that one loads.
    property string mediaViewerPreviewSource: ""
    property real mediaViewerPreviewWidth: 0
    property real mediaViewerPreviewHeight: 0
    property rect mediaViewerClip: Qt.rect(0, 0, 0, 0)
    property string discordEventChannel: ""
    property string discordEventSlug: ""
    // A busy Discord gateway fires events every few seconds. The feed reacts
    // to them almost at once; the minute timer is only a fallback for sources
    // that have no websocket.
    property double lastFeedRefresh: 0
    property double lastThreadRefresh: 0
    readonly property int feedRefreshInterval: 60000
    readonly property int discordFeedInterval: 1000
    property int threadSeq: 0
    property int threadCommentTotal: -1
    property int feedSeq: 0
    property int feedAnchorSeq: 0
    property bool dbgScroll: true
    property bool feedAnchorOn: true
    property int dbgYCount: 0
    property real dbgLastY: 0

    function dbgFeed(tag) {
        if (!w.dbgScroll || !feedScroll)
            return;
        console.log("SCROLLDBG", tag,
            "cy", feedScroll.contentY.toFixed(1),
            "ch", feedScroll.contentHeight.toFixed(1),
            "h", feedScroll.height.toFixed(1),
            "count", feedScroll.count,
            "wheel", feedWheel.running,
            "seq", w.feedAnchorSeq,
            "items", w.items.length,
            "shown", w.shownItems.length);
    }
    property int clockTick: 0
    property string searchQuery: ""
    property string channelQuery: ""
    // Service-side search: channels first, then a seven-day local index.
    property var searchResults: []
    property var searchChannels: []
    property var searchScopeStreams: []
    property string searchResultQuery: ""
    property bool searchServed: false
    property bool searchLoading: false
    property bool searchDirty: false

    readonly property var sample: w.preview ? w.sampleItems() : []
    readonly property var shownItems: {
        var source = w.preview ? w.sample : w.items;
        var hidden = w.hiddenItems;
        var seen = {};
        var out = [];
        for (var i = 0; i < source.length; i++) {
            var item = source[i];
            if (!item || !item.id || hidden.indexOf(item.id) >= 0 || seen[item.id])
                continue;
            // The live feed request excludes these, but a response that was
            // already in flight can merge old items back after a toggle. Keep
            // the visible model tied to the current switches as well.
            if (!w.sourceOn(String(item.source || "")))
                continue;
            var streamIds = item.stream_ids || [];
            if (streamIds.length > 0) {
                var streamVisible = false;
                for (var s = 0; s < streamIds.length; s++) {
                    if (w.streamOn(String(streamIds[s]))) {
                        streamVisible = true;
                        break;
                    }
                }
                if (!streamVisible)
                    continue;
            }
            if (w.sources.length > 0 && w.sourceInfo(String(item.source || "")) === null)
                continue;

            seen[item.id] = true;
            out.push(item);
        }
        // The service already merges by time; doing it again here keeps the
        // card correct if a source ever returns streams in a different order.
        out.sort((a, b) => {
            var when = Date.parse(b.created_at) - Date.parse(a.created_at);
            if (when !== 0)
                return when;
            var aid = String(a.id), bid = String(b.id);
            return bid < aid ? -1 : (bid > aid ? 1 : 0);
        });
        var query = w.searchQuery.trim();
        if (query === "")
            return out;

        var matches = [];
        for (var j = 0; j < out.length; j++) {
            var score = Math.max(
                w.fuzzyScore(query, out[j].title || ""),
                w.fuzzyScore(query, out[j].body || ""),
                w.authorScore(query, out[j]),
                w.channelScore(query, out[j])
            );
            if (score >= 0)
                matches.push({"score": score, "item": out[j]});
        }
        matches.sort((a, b) => (b.score - a.score) || (Date.parse(b.item.created_at) - Date.parse(a.item.created_at)));
        var local = [];
        for (var k = 0; k < matches.length; k++)
            local.push(matches[k].item);

        // While the service is still answering, the local page gives instant
        // feedback. Once it replies, combine its older hits with the local
        // ones (new posts may not be indexed yet).
        if (!w.searchServed || w.searchResultQuery !== query)
            return local;

        if (w.searchScopeStreams.length > 0) {
            var scoped = [];
            for (var n = 0; n < local.length; n++) {
                var ids = local[n].stream_ids || [];
                for (var t = 0; t < ids.length; t++) {
                    if (w.searchScopeStreams.indexOf(String(ids[t])) >= 0) {
                        scoped.push(local[n]);
                        break;
                    }
                }
            }
            local = scoped;
        }

        var byId = ({});
        for (var r = 0; r < w.searchResults.length; r++) {
            var hit = w.searchResults[r];
            if (hit && hit.id)
                byId[hit.id] = hit;
        }
        for (var p = 0; p < local.length; p++) {
            if (local[p] && local[p].id && byId[local[p].id] === undefined)
                byId[local[p].id] = local[p];
        }
        var combined = [];
        for (var id in byId)
            combined.push(byId[id]);
        combined.sort((a, b) => {
            var when = Date.parse(b.created_at) - Date.parse(a.created_at);
            if (when !== 0)
                return when;
            var aid = String(a.id), bid = String(b.id);
            return bid < aid ? -1 : (bid > aid ? 1 : 0);
        });
        return combined;
    }
    readonly property var contextView: {
        var source = w.contextComments;
        var out = [];
        var last = null;
        var lastAuthor = "";
        var groupStart = 0;
        for (var i = 0; i < source.length; i++) {
            var value = source[i];
            if (!value)
                continue;
            var author = value.author || ({});
            var key = String(author.id || author.handle || author.display_name || "");
            var when = Date.parse(value.created_at);
            if (!isFinite(when))
                when = 0;
            // The grouping window is measured from the first message in the
            // block, not from its newest message. A long burst otherwise turns
            // into one block whose total span far exceeds the window.
            if (last !== null && key !== "" && key === lastAuthor && groupStart > 0 && when > 0 && when - groupStart <= 7200000) {
                var text = String(value.body || "");
                if (text !== "")
                    last.body = String(last.body || "") + (last.body ? "\n" : "") + text;
                last.body_segments = (last.body_segments || []).concat(value.body_segments && value.body_segments.length ? value.body_segments : (text ? [text] : []));
                last.media = (last.media || []).concat(value.media || []);
                continue;
            }
            var copy = Object.assign({}, value);
            copy.body_segments = (value.body_segments && value.body_segments.length ? value.body_segments.slice() : (value.body ? [String(value.body)] : []));
            copy.media = (value.media || []).slice();
            out.push(copy);
            last = copy;
            lastAuthor = key;
            groupStart = when;
        }
        return out;
    }
    readonly property var shownSendTargets: {
        var query = w.channelQuery.trim();
        if (query === "")
            return w.sendTargets;

        var found = [];
        for (var i = 0; i < w.sendTargets.length; i++) {
            var target = w.sendTargets[i];
            var score = Math.max(w.fuzzyScore(query, target.title || ""), w.fuzzyScore(query, target.subtitle || ""));
            if (score >= 0)
                found.push({"score": score, "target": target});
        }
        found.sort((a, b) => (b.score - a.score) || String(a.target.title).localeCompare(String(b.target.title)));
        var out = [];
        for (var j = 0; j < found.length; j++)
            out.push(found[j].target);
        return out;
    }
    readonly property bool detailOpen: w.detailId !== ""
    readonly property real pickerReveal: w.pickerOpen ? 1 : 0
    readonly property real detailReveal: w.detailOpen ? 1 : 0
    readonly property int activeStreams: w.countActiveStreams()
    readonly property int activeSources: w.countActiveSources()
    readonly property string statusLine: {
        if (w.fatal !== "")
            return "Feed service unavailable";

        if (w.phase === "loading")
            return "Loading feeds…";

        if (w.refreshing)
            return "Refreshing…";

        var count = w.activeStreams;
        var label = count + (count === 1 ? " stream" : " streams");
        if (w.actionError !== "")
            return label + " · action failed";

        if (w.feedErrors.length > 0)
            return label + " · " + w.feedErrors.length + " stale";

        return label;
    }

    // --------------------------------------------------------------- helpers
    readonly property string emojiBase: Qt.resolvedUrl("../assets/twemoji/")
    // 1x1 transparent SVG used as the layout placeholder for animated emoji;
    // the AnimatedImage overlay paints the only visible frame.
    readonly property string emojiTransparent: Qt.resolvedUrl("../assets/transparent.svg")
    // The LucidMoji catalogue plus the Discord custom emoji inventory power
    // the composer's inline `:shortcode:` suggestions. Both load on first use.
    property var unicodeEmojiCatalog: []
    property var customEmojiCatalog: []
    property var emojiCatalog: []
    property bool emojiCatalogRequested: false
    property bool emojiUsageReady: false
    readonly property var emojiUsageCounts: emojiUsageAdapter.emojiCounts || ({})

    function requestEmojiCatalog() {
        if (!w.emojiCatalogRequested) {
            w.emojiCatalogRequested = true;
            if (w.live && w.service !== "") {
                emojisProc.command = [w.service, "emojis", "--json"];
                emojisProc.running = true;
            }
        }
    }

    function rebuildEmojiCatalog() {
        w.emojiCatalog = w.customEmojiCatalog.concat(w.unicodeEmojiCatalog);
    }

    function recordEmojiUse(key) {
        if (String(key || "") === "" || !w.emojiUsageReady)
            return ;
        var counts = emojiUsageAdapter.emojiCounts || ({});
        var next = ({});
        for (var k in counts)
            next[k] = counts[k];
        next[key] = Number(next[key] || 0) + 1;
        emojiUsageAdapter.emojiCounts = next;
        emojiUsageFile.writeAdapter();
    }

    function consumeEmojis(text) {
        try {
            var source = (JSON.parse(text) || {}).emojis || [];
            var out = [];
            for (var i = 0; i < source.length; i++) {
                var entry = source[i];
                if (!entry || !entry.name || !entry.copy)
                    continue;
                var name = String(entry.name);
                var guild = String(entry.guild || "");
                var hay = EmojiSearch.normalize(name + " " + guild + " server discord custom");
                out.push({
                    "e": "",
                    "n": name,
                    "k": guild,
                    "s": (name + " " + guild).toLowerCase(),
                    "u": "server-" + String(entry.id || ""),
                    "hay": hay,
                    "hayCompact": hay.replace(/ /g, ""),
                    "image": String(entry.image || ""),
                    "copy": String(entry.copy || ""),
                    "animated": entry.animated === true,
                    "custom": true
                });
            }
            w.customEmojiCatalog = out;
            w.rebuildEmojiCatalog();
        } catch (error) {
        }
    }

    FontLoader {
        id: inputEmojiFont

        source: Qt.resolvedUrl("../assets/fonts/TwemojiMozilla.ttf")
    }

    FileView {
        id: emojiUsageFile

        path: Qt.resolvedUrl("../luciddocks/usage.json")
        blockLoading: true
        watchChanges: true
        onLoaded: w.emojiUsageReady = true
        onLoadFailed: w.emojiUsageReady = true

        adapter: JsonAdapter {
            id: emojiUsageAdapter

            property var counts: ({})
            property var emojiCounts: ({})
        }
    }

    FileView {
        id: emojiCatalogFile

        path: w.emojiCatalogRequested ? Qt.resolvedUrl("../lucidmoji/emoji.json") : ""

        onLoaded: {
            try {
                var data = (JSON.parse(emojiCatalogFile.text()) || {}).emoji || [];
                for (var i = 0; i < data.length; i++) {
                    data[i].s = (String(data[i].n || "") + " " + String(data[i].k || "")).toLowerCase();
                    data[i].u = "emoji-" + i;
                    data[i].hay = EmojiSearch.normalize(String(data[i].n || "") + " " + String(data[i].k || "") + " " + String(data[i].s || ""));
                    data[i].hayCompact = data[i].hay.replace(/ /g, "");
                }
                w.unicodeEmojiCatalog = data;
                w.rebuildEmojiCatalog();
            } catch (error) {
                w.unicodeEmojiCatalog = [];
            }
        }
    }

    function emojiHtml(html, size) {
        return SocialEmoji.emojiHtml(html, size, w.emojiBase);
    }

    function emojiRich(value, size) {
        return SocialEmoji.rich(value, size, w.emojiBase);
    }

    // Discord bodies: Twemoji for Unicode, the CDN image for <:name:id> tags,
    // and the CDN image for Vencord/Equicord FakeNitro links. `linkify` also
    // keeps ordinary URLs clickable in the post cards.
    function discordRich(value, size, linkify, linkColor) {
        return SocialEmoji.discord(value, size, w.emojiBase, w.emojiTransparent, linkify, linkColor, true);
    }

    // Compact snippet text (comment previews): emoji images, but no jumbo.
    // Animated emoji use their first frame because there is no overlay here.
    function previewRich(value, size) {
        return SocialEmoji.discord(value, size, w.emojiBase, "", false, "#000000", false);
    }

    // Like discordRich, but also reports every emitted image in document
    // order so SocialBody can overlay live GIFs on animated custom emoji.
    function discordParts(value, size, linkify, linkColor) {
        return SocialEmoji.discordParts(value, size, w.emojiBase, w.emojiTransparent, linkify, linkColor, true);
    }

    // A FakeNitro emoji link is the emoji itself. Media parsers must leave it
    // in the body so the emoji renderer can paint it.
    function isEmojiLink(value) {
        return SocialEmoji.isEmojiCdn(value);
    }

    // Strict subsequence search. Exact substrings win, then in-order matches
    // that start early and stay close together; scattered letters are rejected.
    function authorScore(query, item) {
        var author = (item || {}).author || {};
        var name = String(query || "").trim();
        if (name.charAt(0) === "@")
            name = name.slice(1);
        if (name === "")
            return -1;
        return Math.max(
            w.fuzzyScore(name, author.display_name || ""),
            w.fuzzyScore(name, author.handle || "")
        );
    }

    function channelScore(query, item) {
        var name = String(query || "").trim();
        if (name.charAt(0) === "@" || name.charAt(0) === "#")
            name = name.slice(1);
        if (name === "")
            return -1;

        var best = -1;
        var extra = (item || {}).extra || {};
        if (extra.channel)
            best = Math.max(best, w.fuzzyScore(name, String(extra.channel)));

        var ids = (item || {}).stream_ids || [];
        for (var i = 0; i < ids.length; i++) {
            var stream = w.streamById(ids[i]);
            if (stream)
                best = Math.max(best, w.fuzzyScore(name, stream.title || ""));
        }
        return best;
    }

    function fuzzyScore(query, value) {
        var q = String(query || "").toLowerCase();
        var text = String(value || "").toLowerCase();
        if (q === "")
            return 0;

        if (text === "")
            return -1;

        var exact = text.indexOf(q);
        if (exact >= 0)
            return 1000 - Math.min(exact, 300);

        var first = -1;
        var last = -1;
        var cursor = 0;
        var score = 0;
        for (var i = 0; i < q.length; i++) {
            var found = text.indexOf(q[i], cursor);
            if (found < 0)
                return -1;

            if (first < 0)
                first = found;

            var boundary = found === 0 || !/[a-z0-9]/.test(text[found - 1]);
            score += 60 - Math.min(found, 200) * 0.2;
            if (boundary)
                score += 25;
            if (last >= 0)
                score -= (found - last - 1) * 8;

            last = found;
            cursor = found + 1;
        }
        // A match spread across half the post is noise, not a search hit.
        if (first > 80 || last - first + 1 > q.length * 3 + 6)
            return -1;

        return score - first * 0.4;
    }

    function listOpt(key) {
        var value = w.opt(key);
        if (Array.isArray(value))
            return value.slice();

        if (typeof value === "string" && value !== "") {
            try {
                var parsed = JSON.parse(value);
                return Array.isArray(parsed) ? parsed : [];
            } catch (error) {
                return [];
            }
        }
        return [];
    }

    function includes(list, id) {
        return (list || []).indexOf(id) >= 0;
    }

    function sourceOn(id) {
        return !w.includes(w.offSources, id);
    }

    function streamById(id) {
        for (var i = 0; i < w.sources.length; i++) {
            var streams = w.sources[i].streams || [];
            for (var j = 0; j < streams.length; j++) {
                if (streams[j].id === id)
                    return streams[j];
            }
        }
        return null;
    }

    function streamOn(id) {
        var stream = w.streamById(id);
        if (stream === null)
            return false;

        return stream.default_selected === false ? w.includes(w.onStreams, id) : !w.includes(w.offStreams, id);
    }

    // A gateway event only matters if its account/channel can actually appear
    // in this card. Server streams are treated as wildcards for their account;
    // DM/channel streams match their channel id exactly.
    function discordEventRelevant(slug, channelId) {
        var source = w.sourceInfo("discord");
        if (source === null || !w.sourceOn("discord"))
            return false;

        var streams = source.streams || [];
        var wildcard = false;
        for (var i = 0; i < streams.length; i++) {
            var stream = streams[i];
            var id = String(stream.id || "");
            if (!id.startsWith("discord/" + slug + "/"))
                continue;
            if (!w.streamOn(id))
                continue;

            var extra = stream.extra || {};
            if (extra.kind === "server" || id.indexOf("/server_") >= 0) {
                wildcard = true;
                continue;
            }
            var streamChannel = String(extra.channel_id || "");
            if (streamChannel === "" && id.indexOf("/dm_") >= 0)
                streamChannel = id.split("/dm_")[1];
            if (streamChannel === "" && id.indexOf("/channel_") >= 0)
                streamChannel = id.split("/channel_")[1];
            if (streamChannel === String(channelId))
                return true;
        }
        return wildcard;
    }

    function sourceInfo(id) {
        for (var i = 0; i < w.sources.length; i++) {
            if (w.sources[i].id === id)
                return w.sources[i];

        }
        return null;
    }

    function sourceTitle(id) {
        var found = w.sourceInfo(id);
        if (found)
            return found.title;

        var fallback = {
            "hackernews": "Hacker News",
            "twitter": "X",
            "bluesky": "Bluesky",
            "youtube": "YouTube",
            "nexusmods": "Nexus Mods",
            "discord": "Discord"
        };
        return fallback[id] || id;
    }

    function sourceGlyph(id) {
        var found = w.sourceInfo(id);
        if (found)
            return found.glyph || "public";

        var fallback = {
            "hackernews": "public",
            "twitter": "close",
            "bluesky": "cloud",
            "youtube": "movie",
            "nexusmods": "widgets",
            "discord": "chat"
        };
        return fallback[id] || "public";
    }

    function claimIntro(id) {
        if (id === "" || w.seenPostIds[id] === true)
            return false;

        var next = Object.assign({}, w.seenPostIds);
        next[id] = true;
        w.seenPostIds = next;
        return true;
    }

    function countActiveStreams() {
        var total = 0;
        for (var i = 0; i < w.sources.length; i++) {
            var source = w.sources[i];
            if (!w.sourceOn(source.id))
                continue;

            var streams = source.streams || [];
            for (var j = 0; j < streams.length; j++) {
                if (streams[j].configured !== false && w.streamOn(streams[j].id))
                    total++;

            }
        }
        return total;
    }

    function countActiveSources() {
        var total = 0;
        for (var i = 0; i < w.sources.length; i++) {
            if (w.sourceOn(w.sources[i].id) && (w.sources[i].streams || []).length > 0)
                total++;

        }
        return total;
    }

    function count(value) {
        var number = Number(value);
        if (!isFinite(number) || number < 0)
            return "";

        if (number >= 1000000)
            return (number / 1000000).toFixed(number >= 10000000 ? 0 : 1) + "m";

        if (number >= 1000)
            return (number / 1000).toFixed(number >= 10000 ? 0 : 1) + "k";

        return String(Math.round(number));
    }

    function ago(value) {
        var tick = w.clockTick;
        var stamp = Date.parse(value);
        if (isNaN(stamp))
            return "";

        var seconds = Math.max(0, (Date.now() - stamp) / 1000);
        if (seconds < 60)
            return "now";

        if (seconds < 3600)
            return Math.floor(seconds / 60) + "m";

        if (seconds < 86400)
            return Math.floor(seconds / 3600) + "h";

        if (seconds < 86400 * 7)
            return Math.floor(seconds / 86400) + "d";

        return new Date(stamp).toLocaleDateString(Qt.locale(), "d MMM");
    }

    function stamp(minutesAgo) {
        return new Date(Date.now() - minutesAgo * 60000).toISOString().replace(/\.\d+Z$/, "Z");
    }

    function sampleItems() {
        var me = {
            "id": "ari",
            "handle": "@ari@lucid.local",
            "display_name": "Ari",
            "avatar_url": "",
            "profile_url": ""
        };
        var someone = {
            "id": "mira",
            "handle": "@mira@lucid.local",
            "display_name": "Mira Chen",
            "avatar_url": "",
            "profile_url": ""
        };
        var caps = {
            "like": true,
            "comment": true,
            "share": true,
            "media": true,
            "grouping": false
        };
        return [
            {
                "id": "preview/1",
                "source": "bluesky",
                "stream_ids": ["bluesky/discover"],
                "kind": "post",
                "author": me,
                "title": "",
                "body": "The card is a lens on the same feed, whichever source it came from.\n\nWalked out after the rain and the whole valley was glowing.",
                "body_format": "plain",
                "created_at": w.stamp(12),
                "url": "https://example.com",
                "media": [],
                "stats": {"likes": 128, "comments": 3, "reposts": 14, "score": null},
                "liked": false,
                "capabilities": caps,
                "comments_preview": [{
                    "id": "preview/c1",
                    "post_id": "preview/1",
                    "parent_id": "preview/1",
                    "depth": 0,
                    "author": someone,
                    "body": "The second frame is unreal.",
                    "body_format": "plain",
                    "created_at": w.stamp(10),
                    "url": "",
                    "media": [],
                    "stats": {"likes": 3, "comments": null, "reposts": null, "score": null},
                    "liked": false,
                    "capabilities": caps,
                    "grouped": false,
                    "pending": false,
                    "ref": {}
                }],
                "comment_count": 3,
                "ref": {},
                "extra": {}
            },
            {
                "id": "preview/2",
                "source": "hackernews",
                "stream_ids": ["hackernews/front_page"],
                "kind": "post",
                "author": {
                    "id": "hn",
                    "handle": "Hacker News",
                    "display_name": "Hacker News",
                    "avatar_url": "",
                    "profile_url": ""
                },
                "title": "A single-file social feed with a canonical data format",
                "body": "",
                "body_format": "plain",
                "created_at": w.stamp(70),
                "url": "https://news.ycombinator.com",
                "media": [],
                "stats": {"likes": null, "comments": 86, "reposts": null, "score": 241},
                "liked": null,
                "capabilities": {"like": false, "comment": false, "share": true, "media": false, "grouping": false},
                "comments_preview": [],
                "comment_count": 86,
                "ref": {},
                "extra": {}
            }
        ];
    }

    // ---------------------------------------------------------------- startup
    function boot() {
        if (w.booted)
            return ;

        if (w.preview) {
            w.booted = true;
            w.phase = "ready";
            return ;
        }
        if (!w.live)
            return ;

        w.booted = true;
        w.loadStreams();
        // The New Post channel list is independent of the visible feed and can
        // start loading in parallel so the panel is ready before first use.
        w.loadSendTargets();
        w.loadFeed(true, true);
    }

    Component.onCompleted: w.boot()
    onLiveChanged: {
        if (w.live)
            w.boot();

    }
    onSearchQueryChanged: {
        feedWheel.stop();
        feedScroll.contentY = 0;
        w.clearSearch();
        if (w.searchQuery.trim() === "") {
            searchDebounce.stop();
            if (searchProc.running)
                searchProc.running = false;
            return ;
        }
        if (searchProc.running)
            w.searchDirty = true;
        else
            searchDebounce.restart();
    }
    onChannelQueryChanged: {
        targetList.contentY = 0;
        if (w.channelQuery === "" || w.sendTargetId === "")
            return ;

        var visible = false;
        for (var i = 0; i < w.shownSendTargets.length; i++) {
            var target = w.shownSendTargets[i];
            if (String(target.channel_id || "") === w.sendTargetId && String(target.account || "") === w.sendTargetAccount) {
                visible = true;
                break;
            }
        }
        if (!visible) {
            w.sendTargetId = "";
            w.sendTargetAccount = "";
            w.sendTargetTitle = "";
        }
    }
    onNewPostOpenChanged: {
        w.channelQuery = "";
        searchInput.text = w.newPostOpen ? "" : w.searchQuery;
    }
    onPreviewChanged: {
        if (w.preview) {
            w.booted = true;
            w.phase = "ready";
        }
    }

    // Ctrl+F is only live while the pointer is over this card, so it cannot
    // steal the shortcut from a focused window elsewhere on the desktop.
    Shortcut {
        sequence: "Ctrl+F"
        enabled: w.hovered && w.live && !w.preview
        onActivated: {
            searchInput.forceActiveFocus();
            searchInput.selectAll();
        }
    }

    Timer {
        interval: 60000
        repeat: true
        running: true
        onTriggered: w.clockTick++
    }

    IpcHandler {
        target: "socialdebug"

        function state(): string {
            return JSON.stringify({
                "cy": feedScroll.contentY,
                "ch": feedScroll.contentHeight,
                "h": feedScroll.height,
                "count": feedScroll.count,
                "ci": feedScroll.currentIndex,
                "origin": feedScroll.originY,
                "begin": feedScroll.atYBeginning,
                "end": feedScroll.atYEnd,
                "items": w.items.length,
                "shown": w.shownItems.length,
                "wheel": feedWheel.running,
                "seq": w.feedAnchorSeq
            });
        }

        function sety(y: real): void {
            feedWheel.stop();
            feedScroll.contentY = y;
            w.dbgFeed("ipc-sety " + y);
        }

        function wheel(dir: string, count: int): void {
            var fake = {"angleDelta": {"y": dir === "up" ? 120 : -120}, "pixelDelta": {"y": 0}};
            for (var i = 0; i < count; i++) {
                w.feedAnchorSeq++;
                w.wheelBy(feedScroll, fake, feedWheel);
            }
            w.dbgFeed("ipc-wheel " + dir + " " + count);
        }

        function refresh(): void {
            w.loadFeed(true, true);
        }

        function prepend(): void {
            if (w.items.length === 0)
                return;
            var copy = JSON.parse(JSON.stringify(w.items[0]));
            copy.id = "debug/new/" + Date.now();
            copy.created_at = new Date().toISOString();
            w.items = [copy].concat(w.items);
            w.dbgFeed("ipc-prepend");
        }

        function topid(): string {
            var a = w.captureFeedAnchor();
            return a ? String(a.id) : "";
        }

        function anchor(on: bool): void {
            w.feedAnchorOn = on;
            w.dbgFeed("ipc-anchor " + on);
        }

        function top(): void {
            feedScroll.positionViewAtBeginning();
            w.dbgFeed("ipc-top");
        }

        function unstick(index: int, offset: real): void {
            w.dbgFeed("unstick-before");
            feedScroll.positionViewAtBeginning();
            feedScroll.positionViewAtIndex(index, ListView.Beginning);
            feedScroll.contentY = Math.max(0, feedScroll.contentY + offset);
            w.dbgFeed("unstick-after-a");
            Qt.callLater(function () {
                feedScroll.positionViewAtIndex(index, ListView.Beginning);
                feedScroll.contentY = Math.max(0, feedScroll.contentY + offset);
                w.dbgFeed("unstick-after-b");
            });
        }

        function reorigin(y: real): void {
            feedScroll.positionViewAtBeginning();
            Qt.callLater(function () {
                feedScroll.contentY = y;
                w.dbgFeed("ipc-reorigin-a " + y);
                Qt.callLater(function () { w.dbgFeed("ipc-reorigin-b " + y); });
            });
        }
    }


    Timer {
        interval: 60000
        repeat: true
        running: w.live && !w.preview
        onTriggered: {
            w.lastFeedRefresh = Date.now();
            if (w.detailOpen) {
                if (w.detailPost !== null && w.detailPost.source === "discord") {
                    w.lastThreadRefresh = Date.now();
                    w.loadThread(w.detailId, w.threadLimit, true);
                }
            } else {
                w.loadFeed(true);
            }
        }
    }

    Timer {
        id: hiddenRefresh

        interval: 400
        onTriggered: w.loadFeed(false)
    }

    // The Discord gateway writes this on each MESSAGE_CREATE/UPDATE/DELETE.
    // A debounced refresh makes a new message appear without waiting for the
    // minute timer.
    Timer {
        id: discordDebounce

        interval: 220
        onTriggered: {
            var now = Date.now();
            if (w.detailOpen) {
                var ref = w.detailPost !== null ? (w.detailPost.ref || ({})) : ({});
                var channel = String(ref.channel_id || "");
                var account = String(ref.account || "");
                var channelMatch = w.discordEventChannel === "" || channel === "" || channel === w.discordEventChannel;
                var accountMatch = w.discordEventSlug === "" || account === "" || account === w.discordEventSlug;
                // Only the conversation on screen updates immediately, and at
                // most every few seconds; everything else waits for the minute.
                if (w.detailPost !== null && w.detailPost.source === "discord" && channelMatch && accountMatch
                    && now - w.lastThreadRefresh >= 5000) {
                    w.lastThreadRefresh = now;
                    w.loadThread(w.detailId, w.threadLimit, true);
                }
                return ;
            }
            if (now - w.lastFeedRefresh < w.discordFeedInterval) {
                // The event is real; do not drop it just because a refresh
                // finished a moment ago. Retry when the interval is over.
                discordDebounce.interval = Math.max(80, w.discordFeedInterval - (now - w.lastFeedRefresh));
                discordDebounce.restart();
                return ;
            }
            discordDebounce.interval = 220;

            if (w.discordEventRelevant(w.discordEventSlug, w.discordEventChannel))
                w.loadFeed(true);

        }
    }

    FileView {
        id: discordEvents

        path: w.home + "/.cache/lucid-social/discord/events.json"
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            if (!w.discordEventsReady) {
                w.discordEventsReady = true;
                return ;
            }
            try {
                var event = JSON.parse(text() || "{}");
                w.noteDiscordEvent(event.slug || "", event.channel_id || "");
            } catch (error) {
                w.noteDiscordEvent("", "");
            }

        }
        onLoadFailed: w.discordEventsReady = true
    }

    // Notifications write the post id here after choosing a workspace; this is
    // the hand-off from the shell's notification server to the widget.
    FileView {
        id: openThreadCommand

        path: w.home + "/.cache/lucid-social/open-thread"
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            if (!w.openThreadReady) {
                w.openThreadReady = true;
                return ;
            }
            var raw = String(text() || "").trim();
            var id = raw.split("|")[0].trim();
            if (id !== "")
                w.openThreadById(id);
        }
        onLoadFailed: w.openThreadReady = true
    }

    // --------------------------------------------------------------- network
    function loadStreams() {
        if (w.streamsLoading || w.preview || !w.live || w.service === "")
            return ;

        w.streamsLoading = true;
        streamsProc.command = [w.service, "streams", "--json"];
        streamsProc.running = true;
    }

    function consumeStreams(text) {
        w.streamsLoading = false;
        try {
            var value = JSON.parse(text);
            if (value.schema !== "lucid.social/streams" || value.schema_version !== w.schemaVersion)
                throw new Error("unexpected streams schema");

            w.sources = value.sources || [];
            w.pruneSelection();
            // Preload the channel picker in the background so the new-post
            // panel is instantly searchable when it opens.
            Qt.callLater(w.loadSendTargets);
            if ((value.errors || []).length > 0)
                w.actionError = value.errors[0].message || "a source could not be listed";

        } catch (error) {
            w.fatal = "Could not read the source list from " + w.service + ".";
        }
    }

    function pruneSelection() {
        var sourceIds = ({});
        var streamIds = ({});
        for (var i = 0; i < w.sources.length; i++) {
            sourceIds[w.sources[i].id] = true;
            var streams = w.sources[i].streams || [];
            for (var j = 0; j < streams.length; j++)
                streamIds[streams[j].id] = true;
        }
        var offS = w.offSources.filter((id) => sourceIds[id] === true);
        var offSt = w.offStreams.filter((id) => streamIds[id] === true);
        var onSt = w.onStreams.filter((id) => streamIds[id] === true);
        if (offS.length !== w.offSources.length || offSt.length !== w.offStreams.length || onSt.length !== w.onStreams.length)
            w.setOpts({
                "socialSourcesOff": offS,
                "socialStreamsOff": offSt,
                "socialStreamsOn": onSt
            });

    }

    function feedArgs(limit, before, beforeId, refresh, force) {
        var args = [w.service, "feed", "--json", "--limit", String(limit), "--widget", w.uid];
        if (before !== "") {
            args.push("--before", before);
            if (beforeId !== "")
                args.push("--before-id", beforeId);
        }
        if (force === true)
            args.push("--force");
        else if (refresh)
            args.push("--refresh");
        for (var i = 0; i < w.offSources.length; i++)
            args.push("--exclude-source", w.offSources[i]);
        for (var j = 0; j < w.offStreams.length; j++)
            args.push("--exclude-stream", w.offStreams[j]);
        for (var k = 0; k < w.onStreams.length; k++)
            args.push("--include-stream", w.onStreams[k]);
        return args;
    }

    function resetFeedHistory() {
        w.items = [];
        w.feedAppend = false;
        w.feedLoadingMore = false;
        w.feedAtEnd = false;
        w.feedMorePending = false;
        w.phase = "loading";
    }

    function loadFeed(refresh, force) {
        if (w.preview || !w.live || w.service === "")
            return ;

        if (feedProc.running) {
            w.feedDirty = true;
            if (refresh === true || force === true)
                w.feedDirtyRefresh = true;
            return ;
        }

        // Hidden posts still count against the service page. Ask for enough
        // extra to fill the card after they are filtered out again.
        var want = Math.min(500, w.feedLimit + w.hiddenItems.length);
        w.feedAppend = false;
        w.feedAtEnd = false;
        w.feedLoadingMore = false;
        w.feedMorePending = false;
        w.feedRequestLimit = want;
        w.refreshing = true;
        w.phase = w.items.length > 0 ? w.phase : "loading";
        w.dbgFeed("loadFeed refresh=" + refresh + " force=" + force);
        feedProc.command = w.feedArgs(want, "", "", refresh, force);
        feedProc.running = true;
    }

    function loadMoreFeed() {
        if (w.preview || !w.live || w.service === "" || w.detailOpen)
            return ;
        if (w.feedAtEnd || w.feedLoadingMore)
            return ;
        if (feedProc.running) {
            w.feedMorePending = true;
            return ;
        }

        var oldest = "";
        var oldestId = "";
        for (var i = w.items.length - 1; i >= 0; i--) {
            if (w.items[i] && w.items[i].created_at) {
                oldest = String(w.items[i].created_at);
                oldestId = String(w.items[i].id || "");
                break;
            }
        }
        if (oldest === "")
            return ;

        var want = Math.min(500, w.feedLimit + Math.min(w.hiddenItems.length, 20));
        w.feedAppend = true;
        w.feedLoadingMore = true;
        w.feedRequestLimit = want;
        feedProc.command = w.feedArgs(want, oldest, oldestId, false, false);
        feedProc.running = true;
    }

    function clearSearch() {
        w.searchResults = [];
        w.searchChannels = [];
        w.searchScopeStreams = [];
        w.searchResultQuery = "";
        w.searchServed = false;
    }

    function runSearch() {
        var query = w.searchQuery.trim();
        if (w.preview || !w.live || w.service === "" || query === "") {
            w.searchLoading = false;
            return ;
        }
        if (searchProc.running) {
            w.searchDirty = true;
            return ;
        }
        w.searchLoading = true;
        var args = [w.service, "search", "--json", "--query", query, "--limit", "200"];
        for (var i = 0; i < w.offSources.length; i++)
            args.push("--exclude-source", w.offSources[i]);
        for (var j = 0; j < w.offStreams.length; j++)
            args.push("--exclude-stream", w.offStreams[j]);
        for (var k = 0; k < w.onStreams.length; k++)
            args.push("--include-stream", w.onStreams[k]);
        searchProc.command = args;
        searchProc.running = true;
    }

    function consumeSearch(text) {
        w.searchLoading = false;
        try {
            var value = JSON.parse(text);
            if (value.schema !== "lucid.social/search" || value.schema_version !== w.schemaVersion)
                throw new Error("unexpected search schema");
            if (String(value.query || "") !== w.searchQuery.trim())
                return ;
            var channels = value.channels || [];
            var scope = [];
            for (var i = 0; i < channels.length; i++) {
                var streamId = String(channels[i].stream_id || channels[i].id || "");
                if (streamId !== "" && scope.indexOf(streamId) < 0)
                    scope.push(streamId);
            }
            w.searchChannels = channels;
            w.searchScopeStreams = scope;
            w.searchResults = value.items || [];
            w.searchResultQuery = String(value.query || w.searchQuery.trim());
            w.searchServed = true;
        } catch (error) {
            w.searchServed = false;
        }
    }

    function maybeLoadMoreFeed() {
        if (w.searchQuery !== "")
            return ;
        if (!w.live || w.preview || w.detailOpen || w.feedAtEnd || w.feedLoadingMore || feedProc.running)
            return ;
        if (feedScroll.contentHeight <= feedScroll.height + Theme.dp(4)) {
            w.loadMoreFeed();
            return ;
        }
        if (feedScroll.contentY + feedScroll.height < feedScroll.contentHeight - Theme.dp(240))
            return ;
        w.loadMoreFeed();
    }

    // Keep the post under the viewport fixed across a refresh. The feed can
    // gain or lose posts at the top while it is scrolled down; without this,
    // replacing the model leaves the viewport at a stale pixel offset and the
    // list appears to start wherever the user happened to be.
    function captureFeedAnchor() {
        if (!feedScroll || !feedScroll.contentItem || feedScroll.contentY <= 0.5)
            return null;

        var children = feedScroll.contentItem.children;
        var best = null;
        for (var i = 0; i < children.length; i++) {
            var child = children[i];
            if (!child || !child.modelData || !child.modelData.id)
                continue;
            if (child.y + child.height <= feedScroll.contentY + 0.5)
                continue;
            if (best === null || child.y < best.y)
                best = child;
        }
        if (best === null)
            return null;
        if (w.dbgScroll)
            console.log("SCROLLDBG capture", best.modelData.id, "y", best.y.toFixed(1), "cy", feedScroll.contentY.toFixed(1), "offset", (feedScroll.contentY - best.y).toFixed(1));
        return {
            "id": best.modelData.id,
            "offset": feedScroll.contentY - best.y,
            "seq": w.feedAnchorSeq
        };
    }

    function restoreFeedAnchor(anchor) {
        if (!anchor || !anchor.id)
            return;
        w.dbgFeed("restore-enter " + anchor.id + " off=" + anchor.offset + " seq=" + anchor.seq);
        // A refresh must not fight a scroll the reader has already started.
        if (feedScroll.moving || feedScroll.flicking || feedWheel.running)
            return;

        var seq = anchor.seq !== undefined ? Number(anchor.seq) : w.feedAnchorSeq;
        if (seq !== w.feedAnchorSeq)
            return ;
        var index = -1;
        for (var i = 0; i < w.shownItems.length; i++) {
            if (w.shownItems[i] && w.shownItems[i].id === anchor.id) {
                index = i;
                break;
            }
        }
        if (index < 0 || index >= feedScroll.count)
            return ;

        var offset = anchor.offset;
        if (w.dbgScroll)
            console.log("SCROLLDBG restore-apply-start", anchor.id, "index", index, "cy", feedScroll.contentY.toFixed(1), "ch", feedScroll.contentHeight.toFixed(1));
        feedWheel.stop();
        // Do not positionViewAtIndex first: that makes the anchor the visual
        // top of the list if the delegate is not ready yet. Wait for the
        // delegate that already exists, then restore the pixel offset. Only
        // force a view position as a last resort.
        var attempt = 0;
        var forced = false;
        var passes = 0;
        function apply() {
            if (seq !== w.feedAnchorSeq)
                return ;
            if (feedScroll.moving || feedScroll.flicking || feedWheel.running)
                return ;
            var item = feedScroll.itemAtIndex(index);
            if (item !== null) {
                if (w.dbgScroll)
                    console.log("SCROLLDBG restore-item", anchor.id, "itemY", item.y.toFixed(1), "target", Math.max(0, item.y + offset).toFixed(1), "pass", passes, "from", feedScroll.contentY.toFixed(1));
                feedScroll.contentY = Math.max(0, item.y + offset);
                // The delegate's y can settle one frame after the model gains
                // items above it; re-apply a couple of times so the offset is
                // measured against the final layout.
                if (passes < 2) {
                    passes++;
                    Qt.callLater(apply);
                }
                return ;
            }
            if (attempt < 10) {
                attempt++;
                Qt.callLater(apply);
                return ;
            }
            if (!forced) {
                forced = true;
                if (w.dbgScroll)
                    console.log("SCROLLDBG restore-forced", anchor.id, "index", index);
                feedScroll.positionViewAtIndex(index, ListView.Beginning);
            }
            if (attempt < 18) {
                attempt++;
                Qt.callLater(apply);
            }
        }
        Qt.callLater(apply);
    }

    function consumeFeed(text) {
        w.refreshing = false;
        w.lastFeedRefresh = Date.now();
        var append = w.feedAppend;
        w.feedAppend = false;
        w.feedLoadingMore = false;
        w.dbgFeed("consume-before anchor=" + (append ? "append" : "refresh"));
        var anchor = (append || !w.feedAnchorOn) ? null : w.captureFeedAnchor();
        try {
            var value = JSON.parse(text);
            if (value.schema !== w.schemaFeed || value.schema_version !== w.schemaVersion)
                throw new Error("unexpected feed schema");

            var incoming = value.items || [];
            // Keep loaded history and previous object identities. A refresh
            // adds/updates the newest posts; a cursor page appends older ones.
            var byId = {};
            for (var p = 0; p < w.items.length; p++) {
                if (w.items[p] && w.items[p].id)
                    byId[w.items[p].id] = w.items[p];
            }
            for (var n = 0; n < incoming.length; n++) {
                var fresh = incoming[n];
                if (!fresh || !fresh.id)
                    continue;
                var old = byId[fresh.id];
                byId[fresh.id] = old && JSON.stringify(old) === JSON.stringify(fresh) ? old : fresh;
            }
            var next = [];
            for (var key in byId)
                next.push(byId[key]);
            next.sort((a, b) => {
                var when = Date.parse(b.created_at) - Date.parse(a.created_at);
                if (when !== 0)
                    return when;
                var aid = String(a.id), bid = String(b.id);
                return bid < aid ? -1 : (bid > aid ? 1 : 0);
            });
            if (next.length > 3000)
                next = next.slice(0, 3000);
            w.items = next;
            w.dbgFeed("consume-after-items");
            if (append) {
                if (incoming.length < w.feedRequestLimit)
                    w.feedAtEnd = true;
            } else {
                w.feedAtEnd = false;
            }
            w.feedErrors = value.errors || [];
            w.fatal = "";
            w.actionError = "";
            w.phase = w.items.length > 0 ? "ready" : "empty";
            if (w.detailOpen)
                w.syncDetail();
            if (anchor !== null)
                Qt.callLater(function () { w.restoreFeedAnchor(anchor); });
            Qt.callLater(function () { w.dbgFeed("consume-callLater"); });
            if (!append)
                Qt.callLater(function () { w.maybeLoadMoreFeed(); });
        } catch (error) {
            if (append)
                w.feedAtEnd = true;
            w.phase = w.items.length > 0 ? "ready" : "failed";
            w.fatal = "lucid-social returned an unexpected payload.";
        }
    }

    function syncDetail() {
        for (var i = 0; i < w.items.length; i++) {
            if (w.items[i].id === w.detailId) {
                w.detailPost = w.items[i];
                return ;
            }
        }
        w.detailPost = null;
    }

    // Turn the flat, parent-linked comment list into a Bluesky/Twitter-style
    // timeline. Replies do not indent; each branch shows its first two
    // messages and then a text "Show N more replies" affordance.
    function buildCommentView() {
        var byId = {};
        var children = {};
        var i;
        for (i = 0; i < w.comments.length; i++) {
            var item = w.comments[i];
            byId[item.id] = item;
        }
        // Discord is a flat channel conversation. A message that references
        // another comment is still shown in the same timeline, not hidden in
        // a nested "Show N replies" branch. Reply trees remain for sources
        // that actually model them (Bluesky, HN, ...).
        var flat = w.detailPost !== null && w.detailPost.source === "discord";
        for (i = 0; i < w.comments.length; i++) {
            var value = w.comments[i];
            var parent = !flat && value.parent_id && byId[value.parent_id] ? value.parent_id : "";
            if (!children[parent])
                children[parent] = [];
            children[parent].push(value);
        }
        for (var key in children) {
            // Local sends are stamped in the order Enter was pressed. The
            // sequence tie-break keeps them ordered even when two rows land in
            // the same millisecond (or a refresh keeps their local time).
            children[key].sort((a, b) => (Date.parse(a.created_at) - Date.parse(b.created_at))
                || ((a._localSeq || 0) - (b._localSeq || 0)));
        }
        var out = [];
        var visited = {};
        function walk(parent, depth) {
            var list = children[parent] || [];
            // The main thread is always fully expanded/auto-loaded. Only a
            // nested comment chain is pruned behind "Show N more replies".
            var expanded = parent === "" || w.expandedBranches[parent] === true;
            var shown = expanded ? list : list.slice(0, Math.max(0, w.branchPreviewLimit));
            for (var j = 0; j < shown.length; j++) {
                var comment = shown[j];
                if (visited[comment.id])
                    continue;
                visited[comment.id] = true;
                out.push({"kind": "comment", "comment": comment, "depth": Math.min(4, depth), "level": depth});
                walk(comment.id, depth + 1);
            }
            if (parent !== "" && !expanded && list.length > shown.length) {
                out.push({
                    "kind": "more",
                    "parentId": parent,
                    "hidden": list.length - shown.length,
                    "depth": depth,
                    "level": depth
                });
            }
        }
        walk("", 0);
        // The rail is continuous through one top-level comment's whole reply
        // tree, including its "Show N replies" rows. Returning to a new
        // top-level comment starts a fresh segment, so separate trees are not
        // drawn as one connected line.
        for (var k = 0; k < out.length; k++) {
            out[k].firstInChain = false;
            out[k].lastInChain = false;
        }
        if (out.length > 0) {
            out[0].firstInChain = true;
            out[out.length - 1].lastInChain = true;
        }
        for (var n = 0; n < out.length - 1; n++) {
            var row = out[n];
            var next = out[n + 1];
            if (Number(row.level || 0) > 0 && Number(next.level || 0) === 0) {
                row.lastInChain = true;
                next.firstInChain = true;
            }
        }
        return out;
    }

    function expandBranch(id) {
        var next = Object.assign({}, w.expandedBranches);
        next[id] = true;
        w.expandedBranches = next;
    }

    function hasNestedComments() {
        if (w.detailPost !== null && w.detailPost.source === "discord")
            return false;
        for (var i = 0; i < w.comments.length; i++) {
            if (Number(w.comments[i].depth || 0) > 0)
                return true;
        }
        return false;
    }

    function maybeAutoLoadComments() {
        if (!w.detailOpen || w.commentsLoading || !w.canLoadMoreComments())
            return;

        w.loadMoreComments();
    }

    function canLoadMoreComments() {
        if (w.threadLimit >= 60)
            return false;

        var total = w.detailPost && w.detailPost.comment_count !== null && w.detailPost.comment_count !== undefined ? Number(w.detailPost.comment_count) : -1;
        if (total >= 0)
            return w.comments.length < total;

        return w.comments.length >= w.threadLimit;
    }

    function loadMoreComments() {
        if (w.commentsLoading || !w.canLoadMoreComments())
            return;

        w.threadLimit = Math.min(60, w.threadLimit + 20);
        w.loadThread(w.detailId, w.threadLimit);
    }

    function loadThread(id, limit, refresh) {
        w.threadSeq++;
        var seq = w.threadSeq;
        w.threadLimit = limit || w.threadLimit || 20;
        w.commentsLoading = true;
        w.commentsError = "";
        var args = [w.service, "thread", "--json", "--item", id, "--limit", String(w.threadLimit)];
        if (refresh === true)
            args.push("--refresh");
        threadProc.command = args;
        threadProc.running = true;
        w.pendingThreadSeq = seq;
    }

    function noteDiscordEvent(slug, channelId) {
        w.discordEventSlug = String(slug || "");
        w.discordEventChannel = String(channelId || "");
        if (w.live && !w.preview)
            discordDebounce.restart();
    }

    function scrollThreadToBottom() {
        if (!w.detailOpen)
            return ;

        // Start on the next layout pass, then follow any later height changes
        // while the animation is running. No fixed 60 ms pause.
        w.threadAutoScrolling = true;
        w.contextAnchorPending = false;
        Qt.callLater(function () { w.threadScrollToBottomNow(); });
    }

    function threadScrollToBottomNow() {
        if (!w.detailOpen || !w.threadAutoScrolling)
            return ;

        var target = Math.max(0, detailScroll.contentHeight - detailScroll.height);
        if (Math.abs(target - detailScroll.contentY) < 1) {
            // A zero height means the detail is still being laid out; wait for
            // onContentHeightChanged instead of abandoning the scroll.
            if (detailScroll.contentHeight > 0)
                w.threadAutoScrolling = false;
            return ;
        }

        detailWheel.stop();
        w.threadScrollRestarting = true;
        threadAutoScroll.stop();
        threadAutoScroll.from = detailScroll.contentY;
        threadAutoScroll.to = target;
        threadAutoScroll.restart();
        w.threadScrollRestarting = false;
    }

    function consumeThread(text) {
        w.commentsLoading = false;
        try {
            var value = JSON.parse(text);
            if (value.schema !== "lucid.social/thread" || value.schema_version !== w.schemaVersion)
                throw new Error("unexpected thread schema");

            if (value.item_id !== w.detailId || w.pendingThreadSeq !== w.threadSeq)
                return ;

            if (value.item)
                w.detailPost = value.item;
            if (value.comment_total !== undefined) {
                w.threadCommentTotal = Number(value.comment_total);
                if (w.detailPost !== null) {
                    var totalStats = Object.assign({}, w.detailPost.stats || {});
                    totalStats.comments = w.threadCommentTotal;
                    w.patchPost(w.detailPost.id, {"comment_count": w.threadCommentTotal, "stats": totalStats});
                }
            }

            var fresh = value.comments || [];
            // Never let an empty refresh wipe a chain already on screen.
            if (fresh.length > 0 || w.comments.length === 0) {
                // A grouped Discord comment can represent several local sends.
                // Match every local row to the same server row, then collapse
                // that group to one row instead of appending duplicates.
                var locals = [];
                for (var i = 0; i < w.comments.length; i++) {
                    var row = w.comments[i];
                    if (!row)
                        continue;
                    var isLocal = (row.ref || {}).local === true
                        || String(row.id || "").indexOf("pending/") === 0;
                    if (isLocal)
                        locals.push(row);
                }

                var groups = [];
                var unmatched = [];
                for (var l = 0; l < locals.length; l++) {
                    var pending = locals[l];
                    var index = -1;
                    var body = String(pending.body || "").trim();
                    for (var m = 0; m < fresh.length; m++) {
                        var candidate = fresh[m];
                        if (!candidate)
                            continue;
                        var candidateRef = candidate.ref || {};
                        if (candidate.id === pending.id) {
                            index = m;
                            break;
                        }
                        if (candidateRef.mine !== true)
                            continue;
                        var ids = candidateRef.message_ids || [];
                        if (ids.indexOf(String(pending.id || "")) >= 0) {
                            index = m;
                            break;
                        }
                        if (body === "")
                            continue;
                        var segments = candidate.body_segments || (candidate.body ? [candidate.body] : []);
                        for (var s = 0; s < segments.length; s++) {
                            if (String(segments[s] || "").trim() === body) {
                                index = m;
                                break;
                            }
                        }
                        if (index >= 0)
                            break;
                    }
                    if (index < 0) {
                        unmatched.push(pending);
                        continue;
                    }
                    var group = null;
                    for (var g = 0; g < groups.length; g++) {
                        if (groups[g].index === index) {
                            group = groups[g];
                            break;
                        }
                    }
                    if (group === null) {
                        group = {"index": index, "rows": []};
                        groups.push(group);
                    }
                    group.rows.push(pending);
                }

                var parentOf = ({});
                for (var po = 0; po < w.comments.length; po++) {
                    var poRow = w.comments[po];
                    if (poRow && poRow.id && poRow.parent_id)
                        parentOf[String(poRow.id)] = String(poRow.parent_id);
                }
                for (var pf = 0; pf < fresh.length; pf++) {
                    var pfRow = fresh[pf];
                    if (pfRow && pfRow.id && pfRow.parent_id)
                        parentOf[String(pfRow.id)] = String(pfRow.parent_id);
                }
                var expandAfterMerge = ({});

                var mergedByIndex = ({});
                for (var e = 0; e < groups.length; e++) {
                    var entry = groups[e];
                    var rows = entry.rows.slice();
                    rows.sort(function (a, b) {
                        var seq = Number(a._localSeq || 0) - Number(b._localSeq || 0);
                        return seq !== 0 ? seq : Date.parse(a.created_at) - Date.parse(b.created_at);
                    });
                    var survivor = rows[0];
                    var server = fresh[entry.index];
                    var merged = Object.assign({}, survivor, server);
                    var stillLocal = String(survivor.id || "").indexOf("pending/") === 0
                        && (survivor.ref || {}).landed !== true;
                    merged.id = stillLocal ? String(survivor.id) : String(server.id || survivor.id);
                    merged.created_at = survivor.created_at;
                    merged._localSeq = survivor._localSeq || 0;
                    if (!merged.body && survivor.body)
                        merged.body = survivor.body;
                    if (!merged.body_segments || merged.body_segments.length === 0)
                        merged.body_segments = survivor.body_segments || (survivor.body ? [survivor.body] : []);
                    if (!merged.media || merged.media.length === 0)
                        merged.media = survivor.media;
                    merged.ref = Object.assign({}, survivor.ref || {}, server.ref || {}, {
                        "mine": true,
                        "local": stillLocal
                    });
                    mergedByIndex[entry.index] = merged;
                    if (entry.rows.length > 0) {
                        // A sent row can be grouped into an existing nested
                        // comment. Keep its whole branch open so it does not
                        // vanish behind "Show N replies" after reconciling.
                        var parent = String(server.parent_id || "");
                        var guard = 0;
                        while (parent !== "" && guard < 100) {
                            expandAfterMerge[parent] = true;
                            parent = parentOf[parent] || "";
                            guard++;
                        }
                    }
                }

                var out = [];
                var usedIds = ({});
                for (var f = 0; f < fresh.length; f++) {
                    var item = mergedByIndex[f] !== undefined ? mergedByIndex[f] : fresh[f];
                    if (!item || !item.id)
                        continue;
                    var key = String(item.id);
                    if (usedIds[key] === true)
                        continue;
                    usedIds[key] = true;
                    out.push(item);
                }
                for (var u = 0; u < unmatched.length; u++) {
                    var pendingRow = unmatched[u];
                    if (!pendingRow || !pendingRow.id)
                        continue;
                    var pendingKey = String(pendingRow.id);
                    if (usedIds[pendingKey] === true)
                        continue;
                    usedIds[pendingKey] = true;
                    out.push(pendingRow);
                }
                // A live refresh can be a newest-only slice. Keep the earlier
                // server comments we already had so sending cannot erase the
                // original conversation.
                var earliestFresh = "";
                for (var ef = 0; ef < fresh.length; ef++) {
                    var freshTime = String((fresh[ef] || {}).created_at || "");
                    if (freshTime !== "" && (earliestFresh === "" || freshTime < earliestFresh))
                        earliestFresh = freshTime;
                }
                if (earliestFresh !== "") {
                    for (var old = 0; old < w.comments.length; old++) {
                        var oldRow = w.comments[old];
                        if (!oldRow || !oldRow.id || usedIds[String(oldRow.id)] === true)
                            continue;
                        if ((oldRow.ref || {}).local === true || String(oldRow.id).indexOf("pending/") === 0)
                            continue;
                        var oldTime = String(oldRow.created_at || "");
                        if (oldTime !== "" && oldTime < earliestFresh) {
                            usedIds[String(oldRow.id)] = true;
                            out.push(oldRow);
                        }
                    }
                }
                w.comments = out;
                var expandKeys = Object.keys(expandAfterMerge);
                if (expandKeys.length > 0) {
                    var expanded = Object.assign({}, w.expandedBranches);
                    for (var ek = 0; ek < expandKeys.length; ek++)
                        expanded[expandKeys[ek]] = true;
                    w.expandedBranches = expanded;
                }
            }
            if ((value.errors || []).length > 0)
                w.commentsError = value.errors[0].message || "comments could not refresh";

            w.threadLoaded = true;
            w.settleThreadOpen();
            // A nested chain is not infinite-scrolled: fill it to the source
            // limit once, then let branch collapse/expand do the controlling.
            if (!w.nestedFilled && w.hasNestedComments() && w.threadLimit < 60 && w.canLoadMoreComments()) {
                w.nestedFilled = true;
                w.loadThread(w.detailId, 60);
                return ;
            }

        } catch (error) {
            w.threadLoaded = true;
            w.settleThreadOpen();
            if (w.pendingThreadSeq === w.threadSeq)
                w.commentsError = "Could not read this thread.";

        }
    }

    property int pendingThreadSeq: 0

    function toggleNewPost() {
        if (w.newPostOpen) {
            w.closeNewPost();
            return ;
        }

        w.newPostOpen = true;
        w.pickerOpen = false;
        w.newPostError = "";
        // The list is preloaded at startup and after every selection change;
        // opening the panel must never wait for it. Only retry when it is
        // genuinely empty (a failed preload, or no Discord source yet).
        if (w.sendTargets.length === 0)
            w.loadSendTargets();
        else if (w.sendTargetId === "")
            w.selectSendTarget(w.sendTargets[0], false);
        // The panel opens on the channel filter; the message field comes
        // only after a channel is chosen.
        Qt.callLater(function () { searchInput.forceActiveFocus(); });
    }

    function closeNewPost() {
        w.newPostOpen = false;
        w.newPostError = "";
        w.channelQuery = "";
        if (newComposer)
            newComposer.clear();
        if (newComposer)
            newComposer.clearAttachments();
    }

    function loadSendTargets() {
        if (w.sendTargetsLoading || w.preview || !w.live || w.service === "")
            return ;

        w.sendTargetsLoading = true;
        var args = [w.service, "channels", "--json"];
        for (var i = 0; i < w.offStreams.length; i++)
            args.push("--exclude-stream", w.offStreams[i]);
        for (var j = 0; j < w.onStreams.length; j++)
            args.push("--include-stream", w.onStreams[j]);
        channelsProc.command = args;
        channelsProc.running = true;
    }

    function consumeChannels(text) {
        w.sendTargetsLoading = false;
        try {
            var value = JSON.parse(text);
            if (value.schema !== "lucid.social/channels" || value.schema_version !== w.schemaVersion)
                throw new Error("unexpected channels schema");

            w.sendTargets = value.channels || [];
            if (w.sendTargets.length === 0) {
                w.sendTargetId = "";
                w.sendTargetAccount = "";
                w.sendTargetTitle = "";
                w.sendTargetGuild = "";
                w.newPostError = "No Discord channels are selected in the source sheet.";
            } else {
                // A selection change can remove the channel picked last time.
                var valid = false;
                for (var i = 0; i < w.sendTargets.length; i++) {
                    if (String(w.sendTargets[i].channel_id || "") === w.sendTargetId
                        && String(w.sendTargets[i].account || "") === w.sendTargetAccount) {
                        valid = true;
                        break;
                    }
                }
                if (!valid) {
                    w.sendTargetId = "";
                    w.sendTargetAccount = "";
                    w.sendTargetTitle = "";
                    w.sendTargetGuild = "";
                    w.selectSendTarget(w.sendTargets[0], false);
                }
            }
        } catch (error) {
            w.newPostError = "Could not read the channel list.";
        }
    }

    function selectSendTarget(target, focusMessage) {
        if (!target)
            return ;

        w.sendTargetId = String(target.channel_id || "");
        w.sendTargetAccount = String(target.account || "");
        w.sendTargetTitle = String(target.title || "");
        w.sendTargetGuild = String(target.guild_id || "");
        w.newPostError = "";
        if (focusMessage !== false)
            Qt.callLater(function () { newComposer.focusInput(); });
    }

    function sendTargetIndex() {
        var targets = w.shownSendTargets;
        for (var i = 0; i < targets.length; i++) {
            if (String(targets[i].channel_id || "") === w.sendTargetId
                && String(targets[i].account || "") === w.sendTargetAccount)
                return i;
        }
        return -1;
    }

    function stepSendTarget(delta) {
        if (!w.newPostOpen)
            return ;

        var targets = w.shownSendTargets;
        if (targets.length === 0)
            return ;

        var index = w.sendTargetIndex();
        if (index < 0)
            index = delta > 0 ? -1 : 0;
        index = (index + delta + targets.length) % targets.length;
        w.selectSendTarget(targets[index], false);
        targetList.positionViewAtIndex(index, ListView.Contain);
    }

    function confirmSendTarget() {
        if (!w.newPostOpen)
            return false;

        var targets = w.shownSendTargets;
        if (targets.length === 0)
            return false;

        var index = Math.max(0, w.sendTargetIndex());
        w.selectSendTarget(targets[index], true);
        return true;
    }

    function isMediaPath(path) {
        return /\.(png|jpe?g|gif|webp|avif|bmp|svg|heic|mp4|webm|mov|mkv|ogv|m4v)$/i.test(String(path || "").split("?")[0]);
    }

    function droppedPaths(urls) {
        var out = [];
        for (var i = 0; i < (urls || []).length; i++) {
            var text = String(urls[i] || "");
            if (text.indexOf("file://") !== 0)
                continue;
            var path = text.slice(7);
            if (path.charAt(0) !== "/") {
                var slash = path.indexOf("/");
                if (slash < 0)
                    continue;
                path = path.slice(slash);
            }
            try {
                path = decodeURIComponent(path);
            } catch (error) {
                continue;
            }
            if (path !== "")
                out.push(path);
        }
        return out;
    }

    function attachDroppedMedia(paths) {
        if (w.preview || !w.live)
            return ;

        var media = [];
        for (var i = 0; i < (paths || []).length; i++) {
            var path = String(paths[i] || "");
            if (path !== "" && w.isMediaPath(path))
                media.push(path);
        }
        if (media.length === 0)
            return ;

        if (w.newPostOpen) {
            newComposer.addDropped(media);
        } else if (w.detailOpen && w.detailReveal > 0.5) {
            composer.addDropped(media);
            composer.focusInput();
        } else {
            // The main feed has no composer: the drop opens the New Post
            // panel, with the files already attached.
            if (!w.newPostOpen)
                w.toggleNewPost();
            newComposer.addDropped(media);
        }
    }

    function sortFeedPosts(list) {
        list.sort((a, b) => {
            var when = Date.parse(b.created_at) - Date.parse(a.created_at);
            if (when !== 0)
                return when;
            var aid = String(a.id), bid = String(b.id);
            return bid < aid ? -1 : (bid > aid ? 1 : 0);
        });
        return list;
    }

    function upsertFeedItem(item, localId) {
        if (!item || !item.id)
            return ;

        var next = [];
        for (var i = 0; i < w.items.length; i++) {
            var post = w.items[i];
            if (!post || !post.id)
                continue;
            if (post.id === item.id)
                continue;
            if (localId !== "" && post.id === localId)
                continue;
            next.push(post);
        }
        next.push(item);
        w.items = w.sortFeedPosts(next);
        if (w.detailPost !== null && (w.detailPost.id === item.id || (localId !== "" && w.detailPost.id === localId)))
            w.detailPost = item;
    }

    function sendStreamIds(channelId, guildId, account) {
        var out = [];
        for (var i = 0; i < w.sources.length; i++) {
            var source = w.sources[i];
            if (!source || source.id !== "discord")
                continue;
            var streams = source.streams || [];
            for (var j = 0; j < streams.length; j++) {
                var extra = streams[j].extra || {};
                if (String(extra.account || "") !== String(account || ""))
                    continue;
                if (extra.channel_id) {
                    if (String(extra.channel_id) === String(channelId))
                        out.push(streams[j].id);
                    continue;
                }
                if (extra.guild_id && String(extra.guild_id) === String(guildId))
                    out.push(streams[j].id);
            }
        }
        return out;
    }

    function localMediaObjects(paths) {
        var out = [];
        for (var i = 0; i < (paths || []).length; i++) {
            var path = String(paths[i] || "");
            if (path === "")
                continue;
            var video = /\.(mp4|webm|mov|mkv|ogv|m4v)$/i.test(path);
            out.push({
                "kind": video ? "video" : "image",
                "url": "file://" + path,
                "thumbnail_url": "file://" + path,
                "width": 0,
                "height": 0
            });
        }
        return out;
    }

    function sendNewPost(body, images) {
        body = String(body || "").trim();
        images = (images || []).slice();
        if (w.sending)
            return ;

        if (w.sendTargetId === "") {
            w.newPostError = "Choose a channel first.";
            return ;
        }
        if (body === "" && images.length === 0)
            return ;

        w.sending = true;
        w.newPostError = "";
        w.newPostBody = body;
        w.newPostImages = images;
        newComposer.clear();
        newComposer.clearAttachments();

        // Put the post in the feed before the service answers; the response is
        // merged into this same row, so it never disappears or jumps.
        var localId = "pending/new/" + Date.now() + "/" + (++w.pendingSeq);
        var optimistic = {
            "id": localId,
            "source": "discord",
            "stream_ids": w.sendStreamIds(w.sendTargetId, w.sendTargetGuild, w.sendTargetAccount),
            "kind": "post",
            "author": {"id": "", "handle": "", "display_name": "You", "avatar_url": "", "profile_url": ""},
            "title": "",
            "body": body,
            "body_format": "plain",
            "body_segments": body !== "" ? [body] : [],
            "created_at": new Date().toISOString(),
            "url": "",
            "media": w.localMediaObjects(images),
            "stats": {"likes": null, "comments": 0, "reposts": null, "score": null},
            "liked": null,
            "capabilities": {"like": false, "comment": true, "share": false, "media": false, "grouping": true},
            "comments_preview": [],
            "comment_count": 0,
            "ref": {
                "mine": true,
                "local": true,
                "channel_id": w.sendTargetId,
                "guild_id": w.sendTargetGuild,
                "account": w.sendTargetAccount
            },
            "extra": {}
        };
        w.newPostLocalId = localId;
        w.upsertFeedItem(optimistic, "");
        w.newPostOpen = false;

        var args = [w.service, "send", "--json", "--channel", w.sendTargetId, "--account", w.sendTargetAccount];
        if (w.sendTargetGuild !== "")
            args.push("--guild", w.sendTargetGuild);
        args.push("--body", body);
        for (var i = 0; i < images.length; i++)
            args.push("--image", images[i]);
        sendProc.command = args;
        sendProc.running = true;
    }

    function rollbackNewPost(message, localId) {
        w.sending = false;
        var targetId = localId !== undefined && localId !== "" ? localId : w.newPostLocalId;
        if (targetId !== "") {
            w.items = w.items.filter((post) => post.id !== targetId);
            if (w.detailId === targetId)
                w.closeDetail();
            if (w.newPostLocalId === targetId)
                w.newPostLocalId = "";
        }
        w.newPostError = message;
        w.newPostOpen = true;
        newComposer.text = w.newPostBody;
        newComposer.setAttachments(w.newPostImages);
        w.newPostBody = "";
        w.newPostImages = [];
        Qt.callLater(function () { newComposer.focusInput(); });
    }

    function consumeSend(text) {
        w.sending = false;
        var localId = w.newPostLocalId;
        try {
            var value = JSON.parse(text);
            if (value.ok !== true) {
                w.rollbackNewPost(value.error || "Message was not accepted.", localId);
                return ;
            }
            w.newPostError = "";
            var item = value.item;
            if (!item || String(item.id || "") === "") {
                w.rollbackNewPost("The message service returned no post.", localId);
                return ;
            }
            w.newPostBody = "";
            w.newPostImages = [];
            w.newPostLocalId = "";
            var row = null;
            for (var i = 0; i < w.items.length; i++) {
                if (w.items[i] && w.items[i].id === localId) {
                    row = w.items[i];
                    break;
                }
            }
            var merged = Object.assign({}, row || {}, item);
            merged.id = String(item.id || (row || {}).id || "");
            if (row)
                merged.created_at = row.created_at;
            merged.stream_ids = (item.stream_ids && item.stream_ids.length > 0)
                ? item.stream_ids
                : ((row && row.stream_ids) || []);
            merged.ref = Object.assign({}, (row || {}).ref || {}, item.ref || {}, {"mine": true, "local": false});
            w.upsertFeedItem(merged, localId);
            if (w.detailId === "" || w.detailId === localId) {
                w.openPost(merged);
                // The message created this thread; put the caret straight
                // into its reply field so the conversation can continue.
                Qt.callLater(function () { composer.focusInput(); });
            }
        } catch (error) {
            w.rollbackNewPost("The message service returned an unexpected payload.", localId);
        }
    }

    // How each source's thread is positioned when it opens. Discord is a live
    // conversation, so it always starts at the newest message. Every other
    // source keeps the reader at the top (the root post) until it is tuned
    // explicitly here. This is intentionally a per-source policy, not a
    // remembered per-thread position.
    readonly property var threadScrollModes: ({
        "discord": "bottom"
    })

    function threadScrollMode(source) {
        return String(w.threadScrollModes[String(source || "")] || "top");
    }

    function threadOpensAtBottom(post) {
        return post !== null && w.threadScrollMode(post.source) === "bottom";
    }

    function settleThreadOpen() {
        // Start as soon as the main thread is here. Older context can keep
        // loading above it; consumeContext preserves the viewport when it
        // inserts messages, so the bottom stays put.
        if (!w.threadOpening || !w.threadLoaded)
            return ;
        w.threadOpening = false;
        // No remembered position and no in-between: bottom sources jump to the
        // newest message, every other source stays at the top.
        if (w.threadOpensAtBottom(w.detailPost))
            w.scrollThreadToBottom();
    }

    function openMediaViewer(value, from, previewSource, previewWidth, previewHeight) {
        if (w.preview || !w.live || !value)
            return ;

        var screenName = w.host && w.host.board ? String(w.host.board.screenName || "") : (w.host ? String(w.host.screenName || "") : "");
        var screen = Widgets.screenNamed(screenName);
        if (!screen && Quickshell.screens.length > 0)
            screen = Quickshell.screens[0];
        w.mediaViewerScreen = screen;
        w.mediaViewerFrom = from;
        w.mediaViewerValue = value;
        w.mediaViewerPreviewSource = String(previewSource || "");
        w.mediaViewerPreviewWidth = Math.max(0, Number(previewWidth || 0));
        w.mediaViewerPreviewHeight = Math.max(0, Number(previewHeight || 0));
        // The feed/thread viewport in the same coordinates as `from`. The
        // lightbox uses it to clip the return once it reaches 20% of its
        // opened size, so an image cut off by the card stays cut off.
        var scroll = w.detailOpen ? detailScroll : feedScroll;
        var board = w.host ? w.host.board : null;
        if (scroll && board && scroll.width > 1 && scroll.height > 1) {
            var origin = scroll.mapToItem(board, 0, 0);
            w.mediaViewerClip = Qt.rect(origin.x, origin.y, scroll.width, scroll.height);
        } else {
            w.mediaViewerClip = Qt.rect(0, 0, 0, 0);
        }
        w.mediaViewerOpen = true;
    }

    function closeMediaViewer() {
        w.mediaViewerOpen = false;
    }

    function openThreadById(id) {
        id = String(id || "");
        if (id === "" || w.preview || !w.live)
            return ;

        var post = null;
        for (var i = 0; i < w.items.length; i++) {
            if (w.items[i] && w.items[i].id === id) {
                post = w.items[i];
                break;
            }
        }
        if (post === null) {
            post = {
                "id": id,
                "source": id.split("/")[0],
                "author": {},
                "body": "",
                "title": "",
                "created_at": "",
                "comments_preview": [],
                "capabilities": {},
                "stats": {}
            };
        }
        w.closeNewPost();
        w.openPost(post);
    }

    readonly property string threadPresence: {
        var post = w.detailPost;
        if (!post || post.source !== "discord")
            return "";
        return String((post.extra || {}).presence || "");
    }

    function presenceColor(status) {
        switch (String(status || "").toLowerCase()) {
        case "online":
            return Theme.success;
        case "idle":
            return Theme.warning;
        case "dnd":
            return Theme.error;
        default:
            return Theme.subtextDim;
        }
    }

    function threadTitle() {
        var post = w.detailPost;
        if (!post)
            return "";

        var source = w.sourceTitle(post.source);
        var channelId = String((post.ref || {}).channel_id || "");
        if (post.source === "discord" && channelId !== "") {
            for (var j = 0; j < w.sendTargets.length; j++) {
                var target = w.sendTargets[j];
                if (String(target.channel_id || "") === channelId) {
                    var targetTitle = String(target.title || "");
                    if (targetTitle !== "")
                        return targetTitle;
                }
            }
        }

        var channel = String((post.extra || {}).channel || "");
        if (channel !== "") {
            if (channel.charAt(0) !== "#")
                channel = "#" + channel;
            return channel;
        }

        var ids = post.stream_ids || [];
        for (var i = 0; i < ids.length; i++) {
            var stream = w.streamById(ids[i]);
            if (!stream)
                continue;
            var name = String(stream.title || "");
            if (name === "")
                continue;
            var generic = ["new", "for you", "following", "front page", "best", "discover", "home", "latest", "hot", "top"];
            if (generic.indexOf(name.toLowerCase()) >= 0)
                return source + " · " + name;
            return name;
        }
        return source;
    }

    function openPost(post, reply) {
        if (!post || !post.id)
            return ;

        w.pickerOpen = false;
        w.detailId = post.id;
        w.detailPost = post;
        w.comments = post.comments_preview || [];
        w.threadLimit = 20;
        w.threadCommentTotal = -1;
        w.nestedFilled = false;
        w.expandedBranches = ({});
        w.replyTo = reply === true ? post.id : "";
        w.replyName = reply === true ? ((post.author || {}).display_name || (post.author || {}).handle || "this post") : "";
        w.composeError = "";
        w.actionError = "";
        w.contextComments = [];
        w.contextCursor = "";
        w.contextLoading = false;
        w.contextHasMore = false;
        w.contextReady = post.source !== "discord";
        w.contextSeq++;
        w.threadOpening = true;
        w.threadLoaded = false;
        w.contextLoaded = post.source !== "discord";
        w.threadAutoScrolling = false;
        w.contextAnchorPending = false;
        threadAutoScroll.stop();
        detailScroll.contentY = 0;
        // Start toward the newest message from the preview already on screen;
        // the thread response can re-target the same animation when it lands.
        if (w.threadOpensAtBottom(post))
            w.scrollThreadToBottom();
        w.loadThread(post.id, 20);
        if (post.source === "discord") {
            if (w.sendTargets.length === 0 && !w.sendTargetsLoading)
                w.loadSendTargets();
            w.loadContext("");
        }
        if (reply === true)
            Qt.callLater(function () { composer.focusInput(); });
    }

    function loadContext(before) {
        if (!w.detailOpen || w.contextLoading || w.detailPost === null || w.detailPost.source !== "discord")
            return ;

        w.contextLoading = true;
        w.contextHeightBefore = detailScroll.contentHeight;
        w.contextYBefore = detailScroll.contentY;
        w.pendingContextSeq = ++w.contextSeq;
        var args = [w.service, "context", "--json", "--item", w.detailId, "--limit", "40"];
        if (String(before || "") !== "")
            args.push("--before", String(before));
        contextProc.command = args;
        contextProc.running = true;
    }

    function consumeContext(text) {
        w.contextLoading = false;
        if (w.pendingContextSeq !== w.contextSeq)
            return ;
        try {
            var value = JSON.parse(text);
            if (value.schema !== "lucid.social/context" || value.schema_version !== w.schemaVersion)
                throw new Error("unexpected context schema");
            if (value.item_id !== w.detailId)
                return ;

            var incoming = value.comments || [];
            if (!w.contextReady) {
                w.contextAnchorY = detailScroll.contentY;
                w.contextAnchorHeight = detailScroll.contentHeight;
                w.contextAnchorPending = !w.threadAutoScrolling;
                w.contextComments = incoming;
                w.contextCursor = value.cursor || "";
                w.contextHasMore = value.has_more === true;
                w.contextReady = true;
                w.contextLoaded = true;
                w.settleThreadOpen();
            } else if (incoming.length > 0) {
                w.contextAnchorY = detailScroll.contentY;
                w.contextAnchorHeight = detailScroll.contentHeight;
                w.contextAnchorPending = !w.threadAutoScrolling;
                w.contextComments = incoming.concat(w.contextComments);
                w.contextCursor = value.cursor || w.contextCursor;
                w.contextHasMore = value.has_more === true;
            } else {
                w.contextHasMore = false;
            }
        } catch (error) {
            if (!w.contextReady) {
                w.contextReady = true;
                w.contextLoaded = true;
                w.settleThreadOpen();
            }
        }
    }

    // The comment icon on the root post only changes the compose target; the
    // thread is already open and should not reload.
    function startPostReply(post) {
        if (!post || !post.id)
            return ;

        w.replyTo = post.id;
        w.replyName = (post.author || {}).display_name || (post.author || {}).handle || "this post";
        composer.focusInput();
    }

    function closeDetail() {
        w.detailId = "";
        w.detailPost = null;
        w.comments = [];
        w.commentsLoading = false;
        w.commentsError = "";
        w.threadCommentTotal = -1;
        w.nestedFilled = false;
        w.expandedBranches = ({});
        w.replyTo = "";
        w.replyName = "";
        w.composeError = "";
        w.threadSeq++;
    }

    function retry() {
        w.fatal = "";
        w.actionError = "";
        w.loadStreams();
        w.loadFeed(true);
    }

    function refresh() {
        w.actionError = "";
        w.loadFeed(true);
    }

    // --------------------------------------------------------------- selection
    function hidePost(id) {
        if (id === "" || w.includes(w.hiddenItems, id))
            return ;

        var next = w.hiddenItems.slice();
        next.push(id);
        // Keep the opt bounded; old ids can never reappear in a fresh page.
        if (next.length > 200)
            next = next.slice(next.length - 200);

        w.setOpt("socialHidden", next);
        var remaining = w.items.filter((item) => item.id !== id);
        w.items = remaining;
        if (w.detailId === id)
            w.closeDetail();
        // Refill the visible page from the stream caches; the page request
        // grows with the hidden list, so this is where an older prefetched
        // article enters the feed.
        hiddenRefresh.restart();
    }

    function toggleSource(id) {
        var next = w.offSources.slice();
        var index = next.indexOf(id);
        if (index >= 0)
            next.splice(index, 1);
        else
            next.push(id);

        w.setOpt("socialSourcesOff", next);
        w.resetFeedHistory();
        Qt.callLater(w.loadFeed, false);
        Qt.callLater(w.loadSendTargets);
        if (w.searchQuery !== "") {
            w.clearSearch();
            searchDebounce.restart();
        }
    }

    function toggleStream(id) {
        var stream = w.streamById(id);
        if (stream === null)
            return ;

        if (stream.default_selected === false) {
            var on = w.onStreams.slice();
            var onIndex = on.indexOf(id);
            if (onIndex >= 0)
                on.splice(onIndex, 1);
            else
                on.push(id);

            w.setOpt("socialStreamsOn", on);
        } else {
            var off = w.offStreams.slice();
            var offIndex = off.indexOf(id);
            if (offIndex >= 0)
                off.splice(offIndex, 1);
            else
                off.push(id);

            w.setOpt("socialStreamsOff", off);
        }
        Qt.callLater(w.loadFeed, false);
        Qt.callLater(w.loadSendTargets);
        if (w.searchQuery !== "") {
            w.clearSearch();
            searchDebounce.restart();
        }
    }

    function togglePicker() {
        w.pickerOpen = !w.pickerOpen;
        if (w.pickerOpen && w.sources.length === 0)
            w.loadStreams();

    }

    // ------------------------------------------------------------------- write
    function patchPost(id, patch) {
        var next = w.items.slice();
        for (var i = 0; i < next.length; i++) {
            if (next[i].id === id)
                next[i] = Object.assign({}, next[i], patch);

        }
        w.items = next;
        if (w.detailPost !== null && w.detailPost.id === id)
            w.detailPost = Object.assign({}, w.detailPost, patch);

    }

    function patchComment(id, patch) {
        var next = w.comments.slice();
        for (var i = 0; i < next.length; i++) {
            if (next[i].id === id)
                next[i] = Object.assign({}, next[i], patch);

        }
        w.comments = next;
    }

    function likedPost(id) {
        for (var i = 0; i < w.items.length; i++) {
            if (w.items[i].id === id)
                return w.items[i];
        }
        if (w.detailPost !== null && w.detailPost.id === id)
            return w.detailPost;
        return null;
    }

    function likedComment(id) {
        for (var i = 0; i < w.comments.length; i++) {
            if (w.comments[i].id === id)
                return w.comments[i];
        }
        return null;
    }

    function queueLike(action) {
        var queue = w.likeQueue.slice();
        queue.push(action);
        w.likeQueue = queue;
        w.runLikeQueue();
    }

    function runLikeQueue() {
        if (likeProc.running || w.likeQueue.length === 0)
            return ;

        var action = w.likeQueue[0];
        likeProc.targetId = action.id;
        likeProc.targetKind = action.kind;
        likeProc.revertTo = action.revertTo;
        likeProc.revertStats = action.revertStats;
        likeProc.resultOk = true;
        likeProc.errorText = "";
        likeProc.command = [w.service, "like", "--json", "--item", action.id, action.on ? "--on" : "--off"];
        likeProc.running = true;
    }

    function finishLike(ok) {
        likeProc.running = false;
        if (!ok)
            w.revertLike();
        var queue = w.likeQueue.slice();
        if (queue.length > 0)
            queue.shift();
        w.likeQueue = queue;
        if (!ok && likeProc.errorText !== "")
            w.actionError = likeProc.errorText;
        Qt.callLater(w.runLikeQueue);
    }

    function toggleLike(post) {
        if (!post || !(post.capabilities || {}).like)
            return ;

        // Read the latest local state, not the delegate's possibly stale copy:
        // a rapid second click must see the optimistic first click.
        var live = w.likedPost(post.id) || post;
        var next = live.liked !== true;
        var stats = Object.assign({}, live.stats || {});
        if (stats.likes !== null && stats.likes !== undefined)
            stats.likes = Math.max(0, Number(stats.likes) + (next ? 1 : -1));

        w.patchPost(post.id, {"liked": next, "stats": stats});
        w.queueLike({
            "id": post.id,
            "kind": "post",
            "on": next,
            "revertTo": live.liked === true,
            "revertStats": live.stats || ({})
        });
    }

    function toggleCommentLike(comment) {
        if (!comment || !(comment.capabilities || {}).like)
            return ;

        var live = w.likedComment(comment.id) || comment;
        var next = live.liked !== true;
        var stats = Object.assign({}, live.stats || {});
        if (stats.likes !== null && stats.likes !== undefined)
            stats.likes = Math.max(0, Number(stats.likes) + (next ? 1 : -1));

        w.patchComment(comment.id, {"liked": next, "stats": stats});
        w.queueLike({
            "id": comment.id,
            "kind": "comment",
            "on": next,
            "revertTo": live.liked === true,
            "revertStats": live.stats || ({})
        });
    }

    function deletePost(post) {
        if (!post || !post.id || deleteProc.running || !(post.ref || {}).mine)
            return ;

        deleteProc.targetId = post.id;
        deleteProc.targetKind = "post";
        deleteProc.command = [w.service, "delete", "--json", "--item", post.id];
        deleteProc.running = true;
    }

    function deleteComment(comment) {
        if (!comment || !comment.id || deleteProc.running)
            return ;

        deleteProc.targetId = comment.id;
        deleteProc.targetKind = "comment";
        deleteProc.command = [w.service, "delete", "--json", "--item", comment.id];
        deleteProc.running = true;
    }

    function consumeDelete(text) {
        try {
            var value = JSON.parse(text);
            if (value.ok !== true) {
                w.actionError = value.error || "Could not delete that message.";
                return ;
            }
            var id = deleteProc.targetId;
            if (deleteProc.targetKind === "post") {
                w.items = w.items.filter((post) => post.id !== id);
                if (w.detailId === id)
                    w.closeDetail();
            } else {
                w.comments = w.comments.filter((comment) => comment.id !== id);
                if (w.detailPost && Number(w.detailPost.comment_count || 0) > 0) {
                    var count = Number(w.detailPost.comment_count || 0) - 1;
                    w.detailPost = Object.assign({}, w.detailPost, {"comment_count": count});
                }
            }
            w.actionError = "";
        } catch (error) {
            w.actionError = "The delete service returned an unexpected payload.";
        }
    }

    function revertLike() {
        if (likeProc.targetKind === "post")
            w.patchPost(likeProc.targetId, {"liked": likeProc.revertTo, "stats": likeProc.revertStats});
        else if (likeProc.targetKind === "comment")
            w.patchComment(likeProc.targetId, {"liked": likeProc.revertTo, "stats": likeProc.revertStats});

    }

    function consumeLike(text) {
        try {
            var value = JSON.parse(text);
            if (value.ok !== true) {
                likeProc.resultOk = false;
                likeProc.errorText = value.error || "";
            }
        } catch (error) {
            likeProc.resultOk = false;
        }
    }

    function startReply(comment) {
        w.replyTo = comment.id || "";
        w.replyName = (comment.author || {}).display_name || (comment.author || {}).handle || "this comment";
        composer.focusInput();
    }

    function cancelReply() {
        w.replyTo = "";
        w.replyName = "";
    }

    function saveCredential(sourceId, key, value) {
        if (w.authBusyKey !== "")
            return ;

        w.authError = "";
        w.authStatus = "";
        w.authBusyKey = sourceId + "/" + key;
        authProc.pending = JSON.stringify({"source": sourceId, "key": key, "value": String(value || "")}) + "\n";
        authProc.command = [w.service, "auth", "--json", "--stdin"];
        authProc.running = true;
    }

    function saveAccount(sourceId, accountId, name, value) {
        if (w.authBusyKey !== "")
            return ;

        w.authError = "";
        w.authStatus = "";
        w.authBusyKey = accountId === "" ? sourceId + "/new" : sourceId + "/account/" + accountId;
        authProc.pending = JSON.stringify({
            "source": sourceId,
            "account": accountId,
            "name": name,
            "key": "user_token",
            "value": String(value || "")
        }) + "\n";
        authProc.command = [w.service, "auth", "--json", "--stdin"];
        authProc.running = true;
    }

    function removeAccount(sourceId, accountId) {
        if (w.authBusyKey !== "")
            return ;

        w.authError = "";
        w.authStatus = "";
        w.authBusyKey = sourceId + "/account/" + accountId;
        authProc.pending = JSON.stringify({"source": sourceId, "remove_account": accountId}) + "\n";
        authProc.command = [w.service, "auth", "--json", "--stdin"];
        authProc.running = true;
    }

    function consumeAuth(text) {
        w.authBusyKey = "";
        try {
            var value = JSON.parse(text);
            if (value.ok !== true) {
                w.authError = value.error || "Could not save that credential.";
                return ;
            }
            w.authStatus = value.cleared === true ? "Cleared" : "Saved";
            w.authError = "";
            sourcePicker.newAccountName = "";
            sourcePicker.newAccountToken = "";
            w.loadStreams();
            w.loadSendTargets();
            w.loadFeed(true);
        } catch (error) {
            w.authError = "The credential service returned an unexpected payload.";
        }
    }

    function postComment(body, images) {
        body = String(body || "").trim();
        images = (images || []).slice();
        if (body === "" && images.length === 0)
            return ;
        var itemId = w.detailId;
        if (itemId === "")
            return ;

        var target = w.replyTo;
        var targetName = w.replyName;
        var seq = ++w.pendingSeq;
        var localId = "pending/" + Date.now() + "/" + seq;
        // This row is shown immediately and stays the same object when the
        // service confirms; it is not a "pending" placeholder.
        var pending = {
            "id": localId,
            "post_id": itemId,
            "parent_id": target !== "" ? target : itemId,
            "depth": target !== "" ? 1 : 0,
            "author": {"id": "", "handle": "", "display_name": "You", "avatar_url": "", "profile_url": ""},
            "body": body,
            "body_segments": body !== "" ? [body] : [],
            "created_at": new Date().toISOString(),
            "media": w.localMediaObjects(images),
            "stats": {"likes": null, "comments": null, "reposts": null, "score": null},
            "capabilities": {"like": false, "comment": true, "share": false, "media": false, "grouping": false},
            "ref": {"mine": true, "local": true},
            "_localSeq": seq,
            "pending": false
        };
        var job = {
            "localId": localId,
            "itemId": itemId,
            "body": body,
            "images": images,
            "replyTo": target,
            "replyName": targetName,
            "wasReply": target !== "",
            "seq": seq
        };
        w.commentJobs = w.commentJobs.concat([job]);
        // Expand the whole branch before inserting the row. Otherwise a reply
        // to a nested comment is briefly hidden behind its parent's "Show N
        // replies" row on the first layout pass.
        if (target !== "") {
            var expanded = Object.assign({}, w.expandedBranches);
            var parents = ({});
            for (var c = 0; c < w.comments.length; c++) {
                var existing = w.comments[c];
                if (existing && existing.id && existing.parent_id)
                    parents[String(existing.id)] = String(existing.parent_id);
            }
            var cursor = String(target);
            var guard = 0;
            while (cursor !== "" && guard < 100) {
                expanded[cursor] = true;
                cursor = parents[cursor] || "";
                guard++;
            }
            w.expandedBranches = expanded;
        }
        w.comments = w.comments.concat([pending]);
        // The sent row is the reason for the action: always reveal it.
        w.scrollThreadToBottom();
        if (w.threadCommentTotal >= 0)
            w.threadCommentTotal += 1;
        if (w.detailPost && w.detailPost.id === itemId) {
            var count = Number(w.detailPost.comment_count || 0) + 1;
            w.detailPost = Object.assign({}, w.detailPost, {"comment_count": count});
        }

        // The composer is local state: clear it now so the next message can be
        // typed and sent while this one is still in flight.
        composer.clear();
        composer.clearAttachments();
        w.replyTo = "";
        w.replyName = "";
        w.composeError = "";
        var args = [w.service, "comment", "--json", "--item", itemId, "--body", body];
        if (target !== "")
            args.push("--reply-to", target);
        for (var j = 0; j < images.length; j++)
            args.push("--image", images[j]);
        w.startCommentJob(job, args);
    }

    function startCommentJob(job, args) {
        var proc = commentJobComponent.createObject(w);
        if (proc === null) {
            w.failCommentJob(job, "Could not start the comment service.");
            return ;
        }
        proc.job = job;
        proc.command = args;
        proc.running = true;
    }

    function removeCommentJob(localId) {
        var next = [];
        for (var i = 0; i < w.commentJobs.length; i++) {
            if (w.commentJobs[i] && w.commentJobs[i].localId !== localId)
                next.push(w.commentJobs[i]);
        }
        w.commentJobs = next;
    }

    function failCommentJob(job, message) {
        w.removeCommentJob(job.localId);
        var rowIndex = -1;
        for (var i = 0; i < w.comments.length; i++) {
            if (w.comments[i] && w.comments[i].id === job.localId) {
                rowIndex = i;
                break;
            }
        }
        if (rowIndex >= 0) {
            var next = w.comments.slice();
            next.splice(rowIndex, 1);
            w.comments = next;
            if (w.threadCommentTotal > 0)
                w.threadCommentTotal -= 1;
            if (w.detailPost && w.detailPost.id === job.itemId && Number(w.detailPost.comment_count || 0) > 0)
                w.detailPost = Object.assign({}, w.detailPost, {"comment_count": Number(w.detailPost.comment_count || 0) - 1});
        }
        if (w.detailId === job.itemId) {
            if (message !== "")
                w.composeError = message;
            if (String(composer.text || "") === "" && (composer.attachments || []).length === 0) {
                composer.text = job.body;
                composer.setAttachments(job.images);
                w.replyTo = job.replyTo;
                w.replyName = job.replyName;
            }
        }
    }

    function completeCommentJob(job, text, code) {
        w.removeCommentJob(job.localId);
        if (code !== 0 && String(text || "").trim() === "") {
            w.failCommentJob(job, "Could not reach the comment service.");
            return ;
        }
        try {
            var value = JSON.parse(text);
            if (value.ok !== true) {
                w.failCommentJob(job, value.error || "Comment was not accepted.");
                return ;
            }
            var comment = value.comment;
            if (comment && w.detailId === job.itemId) {
                var next = w.comments.slice();
                var localIndex = -1;
                var serverIndex = -1;
                for (var i = 0; i < next.length; i++) {
                    if (!next[i])
                        continue;
                    if (next[i].id === job.localId)
                        localIndex = i;
                    if (next[i].id === comment.id)
                        serverIndex = i;
                }
                if (localIndex >= 0) {
                    var row = next[localIndex];
                    var merged = Object.assign({}, row, comment);
                    merged.id = String(comment.id || row.id);
                    merged.created_at = row.created_at;
                    merged.pending = false;
                    if (!String(merged.body || "").trim() && row.body)
                        merged.body = row.body;
                    if (!merged.body_segments || merged.body_segments.length === 0)
                        merged.body_segments = row.body_segments || (merged.body ? [merged.body] : []);
                    if ((!merged.media || merged.media.length === 0) && row.media)
                        merged.media = row.media;
                    merged.ref = Object.assign({}, row.ref || {}, comment.ref || {}, {
                        "mine": true,
                        // Keep the stable row until a thread refresh sees the
                        // server copy and clears this flag in place.
                        "local": true,
                        "landed": value.pending !== true
                    });
                    merged._localSeq = row._localSeq || job.seq;
                    if (serverIndex >= 0 && serverIndex !== localIndex) {
                        next.splice(localIndex, 1);
                        // Removing the local row shifts a later server row.
                        serverIndex = serverIndex > localIndex ? serverIndex - 1 : serverIndex;
                        next[serverIndex] = merged;
                    } else {
                        next[localIndex] = merged;
                    }
                    w.comments = next;
                }
            }
            if (value.pending === true)
                w.actionError = "Queued for the comment relay";
        } catch (error) {
            w.failCommentJob(job, "The comment service returned an unexpected payload.");
        }
    }

    function pendingInFresh(pending, fresh) {
        var body = String((pending || {}).body || "").trim();
        if (body === "")
            return false;
        for (var i = 0; i < fresh.length; i++) {
            var comment = fresh[i];
            if (!comment || comment.id === pending.id)
                return true;
            if (!((comment.ref || {}).mine === true))
                continue;
            var segments = comment.body_segments || (comment.body ? [comment.body] : []);
            for (var j = 0; j < segments.length; j++) {
                if (String(segments[j] || "").trim() === body)
                    return true;
            }
        }
        return false;
    }

    // Wheel and page keys act on whichever scroll area is visible. The wheel
    // is three times the usual notch; page keys move one screenful, Home/End
    // go to the ends.
    function wheelBy(target, event, anim) {
        if (!target || !anim)
            return false;

        if (target === detailScroll)
            threadAutoScroll.stop();

        // Mouse wheels report a 120-unit notch in angleDelta; some Wayland
        // stacks also fill pixelDelta with a smaller value. Prefer the notch so
        // the 3x applies to the real wheel distance; touchpads fall back to
        // their pixel delta.
        var angle = Number(event.angleDelta.y || 0);
        var dy = angle !== 0 ? (angle / 120) * 60 : Number(event.pixelDelta.y || 0);

        var maxY = Math.max(0, target.contentHeight - target.height);
        var from = target.contentY;
        // Accumulate onto a pending animation in the same direction, but if
        // the wheel reverses, start from where the list actually is. Using
        // the old target after a reversal moves the wrong way and makes the
        // list feel like it cannot reach the top (or bottom).
        var pending = anim.running ? Number(anim.to) - from : 0;
        var sameWay = (dy > 0 && pending <= 0) || (dy < 0 && pending >= 0);
        var base = anim.running && sameWay ? Number(anim.to) : from;
        var to = Math.max(0, Math.min(maxY, base - dy * 2.4));
        if (Math.abs(to - from) < 0.5)
            return true;

        anim.stop();
        anim.from = from;
        anim.to = to;
        anim.restart();
        if (w.dbgScroll && target === feedScroll)
            console.log("SCROLLDBG wheel-anim from", from.toFixed(1), "to", to.toFixed(1), "dy", dy, "pending", pending, "max", maxY.toFixed(1));
        return true;
    }

    function handleScrollKey(event) {
        if (w.pickerOpen)
            return sourcePicker.scrollKey(event.key);

        var target = w.detailOpen ? detailScroll : feedScroll;
        if (target === detailScroll && w.threadAutoScrolling)
            return true;

        if (target === feedScroll)
            w.feedAnchorSeq++;
        var maxY = Math.max(0, target.contentHeight - target.height);
        if (event.key === Qt.Key_PageUp)
            target.contentY = Math.max(0, target.contentY - target.height * 0.9);
        else if (event.key === Qt.Key_PageDown)
            target.contentY = Math.min(maxY, target.contentY + target.height * 0.9);
        else if (event.key === Qt.Key_Home)
            target.contentY = 0;
        else if (event.key === Qt.Key_End)
            target.contentY = maxY;
        else
            return false;

        return true;
    }

    function openExternal(post, item) {
        if (!post || !post.url)
            return ;

        if (post.source === "discord") {
            if (openProc.running)
                return ;

            openProc.fallbackUrl = post.url;
            openProc.fallbackItem = item || null;
            openProc.command = [w.service, "open", "--json", "--item", post.id];
            openProc.running = true;
            return ;
        }
        w.openUrl(post.url, item);
    }

    // Hand the URL to the default browser, then raise the browser window that
    // was already open. When none is running, xdg-open starts one normally.
    // The placeholder grows out of `item`, the element that was pressed.
    function openUrl(value, item, opts) {
        var target = String(value || "");
        if (target === "")
            return ;

        opts = opts || {};
        var script = "desktop=$(xdg-settings get default-web-browser 2>/dev/null || true); " + "base=${desktop%.desktop}; wm=''; " + "for d in \"$HOME/.local/share/applications\" /usr/share/applications /var/lib/flatpak/exports/share/applications; do " + "f=\"$d/$desktop\"; [ -f \"$f\" ] || continue; " + "wm=$(sed -n 's/^StartupWMClass=//Ip' \"$f\" | head -1 | tr -d '\\r'); break; " + "done; " + "addr=$(hyprctl -j clients 2>/dev/null | jq -r --arg wm \"$wm\" --arg base \"$base\" '" + "([$wm,$base] + [\"helium\",\"zen\",\"zen-browser\",\"firefox\",\"librewolf\",\"chromium\",\"brave-browser\",\"google-chrome\",\"vivaldi\",\"opera\",\"qutebrowser\",\"floorp\"]) as $candidates " + "| ($candidates | map(select(. != \"\") | ascii_downcase)) as $classes " + "| [.[] | . as $w | ($w.class|ascii_downcase) as $c | ($classes | index($c)) as $i " + "| select($i != null) | {i:$i,f:$w.focusHistoryID,a:$w.address}] " + "| sort_by(.i,.f) | .[0].a // empty'); " + "setsid xdg-open \"$1\" >/dev/null 2>&1 & " + "if [ -n \"$addr\" ]; then sleep 0.15; hyprctl eval \"local w=nil for i,win in pairs(hl.get_windows()) do if win.address==\\\"$addr\\\" then w=win end end if w then hl.dispatch(hl.dsp.focus({window=w})) end\" >/dev/null 2>&1; fi";
        var command = "sh -c " + Launch.shQuote(script) + " sh " + Launch.shQuote(target);
        w.openExternalUrl(target, item, {
            "command": opts.command || command,
            "title": opts.title || "Browser",
            "icon": opts.icon || "web-browser",
            "timeoutMs": opts.timeoutMs > 0 ? opts.timeoutMs : 2500
        });
    }

    function openPostUrl() {
        if (w.detailPost)
            w.openExternal(w.detailPost);

    }

    NumberAnimation {
        id: feedWheel

        target: feedScroll
        property: "contentY"
        duration: Theme.durQuick
        easing.type: Easing.OutCubic
    }

    NumberAnimation {
        id: detailWheel

        target: detailScroll
        property: "contentY"
        duration: Theme.durQuick
        easing.type: Easing.OutCubic
    }

    // -------------------------------------------------------------- processes
    Process {
        id: streamsProc

        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: w.consumeStreams(this.text)
        }

        onExited: (code) => {
            if (code !== 0) {
                w.streamsLoading = false;
                w.fatal = "Could not reach " + w.service + ". Is the lucid-social repo in ~/src?";
            }
        }
    }

    Process {
        id: feedProc

        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: w.consumeFeed(this.text)
        }

        onExited: (code) => {
            w.refreshing = false;
            if (code !== 0 && w.items.length === 0) {
                w.phase = "failed";
                w.fatal = "Could not reach " + w.service + ". Is the lucid-social repo in ~/src?";
            }
            if (code !== 0 && w.feedAppend)
                w.feedAtEnd = true;
            w.feedAppend = false;
            w.feedLoadingMore = false;
            if (w.feedDirty) {
                var refresh = w.feedDirtyRefresh;
                w.feedDirty = false;
                w.feedDirtyRefresh = false;
                w.feedMorePending = false;
                Qt.callLater(function () { w.loadFeed(refresh, false); });
            } else if (w.feedMorePending) {
                w.feedMorePending = false;
                Qt.callLater(w.loadMoreFeed);
            }
        }
    }

    Process {
        id: searchProc

        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: w.consumeSearch(this.text)
        }

        onExited: (code) => {
            w.searchLoading = false;
            if (code !== 0)
                w.searchServed = false;
            if (w.searchDirty) {
                w.searchDirty = false;
                searchDebounce.restart();
            }
        }
    }

    Timer {
        id: searchDebounce

        interval: 260
        onTriggered: w.runSearch()
    }

    Process {
        id: threadProc

        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: w.consumeThread(this.text)
        }

        onExited: (code) => {
            if (code !== 0) {
                w.commentsLoading = false;
                w.commentsError = "Could not load this thread.";
            }
        }
    }

    Process {
        id: contextProc

        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: w.consumeContext(this.text)
        }

        onExited: (code) => {
            if (code !== 0) {
                w.contextLoading = false;
                if (!w.contextReady) {
                    w.contextReady = true;
                    w.contextLoaded = true;
                    w.settleThreadOpen();
                }
            }
        }
    }

    Process {
        id: deleteProc

        property string targetId: ""
        property string targetKind: "post"
        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: w.consumeDelete(this.text)
        }

        onExited: (code) => {
            if (code !== 0)
                w.actionError = "Could not delete that message.";
        }
    }

    Process {
        id: likeProc

        property string targetId: ""
        property string targetKind: "post"
        property bool revertTo: false
        property var revertStats: ({})
        property bool resultOk: true
        property string errorText: ""
        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: w.consumeLike(this.text)
        }

        onExited: (code) => Qt.callLater(function () {
            if (code !== 0 && likeProc.errorText === "")
                likeProc.errorText = "The source refused the like.";
            w.finishLike(code === 0 && likeProc.resultOk);
        })
    }

    Process {
        id: authProc

        property string pending: ""
        running: false
        command: []
        stdinEnabled: true

        onStarted: {
            authProc.write(authProc.pending);
            authProc.pending = "";
            authCloser.start();
        }

        onExited: {
            authProc.stdinEnabled = true;
            if (w.authBusyKey !== "")
                w.authBusyKey = "";

        }

        stdout: StdioCollector {
            onStreamFinished: w.consumeAuth(this.text)
        }
    }

    // Give the child a moment to read the pipe before closing it.
    Timer {
        id: authCloser

        interval: 120
        onTriggered: authProc.stdinEnabled = false
    }

    Process {
        id: openProc

        property string fallbackUrl: ""
        property var fallbackItem: null
        running: false
        command: []

        onExited: (code) => {
            if (code !== 0 && openProc.fallbackUrl !== "")
                w.openUrl(openProc.fallbackUrl, openProc.fallbackItem);

            openProc.fallbackUrl = "";
            openProc.fallbackItem = null;
        }
    }

    // Each comment gets its own process so pressing Enter again does not wait
    // for the previous message. The local rows are inserted in send order and
    // the responses merge into those same rows whenever they arrive.
    Component {
        id: commentJobComponent

        Process {
            id: commentJobProc

            property var job: null
            property string output: ""
            running: false
            command: []

            stdout: StdioCollector {
                onStreamFinished: commentJobProc.output = this.text
            }

            onExited: (code) => {
                var current = commentJobProc.job;
                commentJobProc.job = null;
                if (current)
                    w.completeCommentJob(current, commentJobProc.output, code);
                commentJobProc.destroy();
            }
        }
    }

    Process {
        id: channelsProc

        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: w.consumeChannels(this.text)
        }

        onExited: (code) => {
            if (code !== 0) {
                w.sendTargetsLoading = false;
                w.newPostError = "Could not load the channel list.";
            }
        }
    }

    Process {
        id: emojisProc

        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: w.consumeEmojis(this.text)
        }
    }

    Process {
        id: sendProc

        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: w.consumeSend(this.text)
        }

        onExited: (code) => {
            if (code !== 0 && w.sending)
                w.rollbackNewPost("Could not reach the message service.");
        }
    }

    NumberAnimation {
        id: threadAutoScroll

        target: detailScroll
        property: "contentY"
        duration: Theme.durQuick
        easing.type: Easing.OutCubic
        onFinished: {
            if (!w.threadScrollRestarting)
                w.threadAutoScrolling = false;
        }
    }

    // ------------------------------------------------------------------ header
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.dp(14)
        spacing: Theme.dp(6)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(9)

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: Theme.dp(36)
                Layout.preferredHeight: Theme.dp(36)
                radius: Theme.dp(18)
                color: w.pickerOpen ? Theme.primaryContainer : Theme.surfaceHigh

                Behavior on color {
                    ColorAnimation {
                        duration: Theme.durDefaultEffects
                    }

                }

                IconButton {
                    anchors.centerIn: parent
                    icon: "hub"
                    size: "xs"
                    tintOverride: w.pickerOpen ? Theme.fgPrimaryContainer : w.inkDim
                    onClicked: w.togglePicker()
                }

            }

            Rectangle {
                id: searchBar

                Layout.fillWidth: true
                Layout.preferredHeight: Theme.dp(36)
                Layout.alignment: Qt.AlignVCenter
                radius: Theme.pill(height)
                color: Theme.surfaceHigh
                border.width: searchInput.activeFocus ? 1 : 0
                border.color: Theme.alpha(Theme.primary, 0.55)

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.IBeamCursor
                    onClicked: searchInput.forceActiveFocus()
                }

                Icon {
                    id: searchIcon

                    anchors.left: parent.left
                    anchors.leftMargin: Theme.dp(10)
                    anchors.verticalCenter: parent.verticalCenter
                    name: "search"
                    size: Theme.dp(16)
                    color: searchInput.activeFocus ? Theme.primary : Theme.subtextDim
                }

                TextInput {
                    id: searchInput

                    anchors.left: searchIcon.right
                    anchors.leftMargin: Theme.dp(6)
                    anchors.right: searchClear.visible ? searchClear.left : parent.right
                    anchors.rightMargin: searchClear.visible ? Theme.dp(2) : Theme.dp(10)
                    anchors.verticalCenter: parent.verticalCenter
                    height: Math.max(Theme.dp(18), font.pixelSize * 1.3)
                    clip: true
                    color: Theme.text
                    selectionColor: Theme.alpha(Theme.primary, 0.35)
                    selectedTextColor: Theme.text
                    font.family: inputEmojiFont.status === FontLoader.Ready ? inputEmojiFont.name : Theme.fontFamily
                    font.pixelSize: Theme.typeSize("bodyMedium")
                    font.variableAxes: Theme.axes(Theme.typeSize("bodyMedium"), 420, 0)
                    onTextEdited: {
                        if (w.newPostOpen) {
                            if (w.channelQuery !== text)
                                w.channelQuery = text;
                        } else if (w.searchQuery !== text) {
                            w.searchQuery = text;
                        }
                    }

                    onAccepted: {
                        if (w.newPostOpen)
                            w.confirmSendTarget();
                    }

                    Keys.onDownPressed: (event) => {
                        if (!w.newPostOpen)
                            return ;
                        w.stepSendTarget(1);
                        event.accepted = true;
                    }

                    Keys.onUpPressed: (event) => {
                        if (!w.newPostOpen)
                            return ;
                        w.stepSendTarget(-1);
                        event.accepted = true;
                    }

                    onActiveFocusChanged: {
                        if (activeFocus)
                            w.beginEdit();
                        else
                            w.endEdit();
                    }

                    Keys.onEscapePressed: {
                        if (w.newPostOpen) {
                            text = "";
                            w.endEdit();
                            focus = false;
                            w.closeNewPost();
                        } else {
                            w.searchQuery = "";
                            text = "";
                            w.endEdit();
                            focus = false;
                        }
                    }

                    LText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: searchInput.text === ""
                        role: "bodyMedium"
                        text: w.newPostOpen ? "Search channels…" : "Search…"
                        color: Theme.subtextDim
                        opacity: 0.8
                    }

                }

                IconButton {
                    id: searchClear

                    anchors.right: parent.right
                    anchors.rightMargin: Theme.dp(2)
                    anchors.verticalCenter: parent.verticalCenter
                    visible: searchInput.text !== ""
                    icon: "close"
                    size: "xs"
                    tintOverride: w.inkDim
                    onClicked: {
                        if (w.newPostOpen)
                            w.channelQuery = "";
                        else
                            w.searchQuery = "";

                        searchInput.text = "";
                        searchInput.forceActiveFocus();
                    }
                }

            }

            Item {
                Layout.preferredWidth: Theme.dp(30)
                Layout.preferredHeight: Theme.dp(30)
                Layout.alignment: Qt.AlignVCenter
                visible: w.refreshing

                LoadingIndicator {
                    anchors.fill: parent
                    running: w.refreshing
                    color: Theme.primary
                }

            }

            IconButton {
                Layout.alignment: Qt.AlignVCenter
                icon: w.newPostOpen ? "close" : "send"
                size: "s"
                tooltip: w.newPostOpen ? "Cancel New Post" : "New Post"
                tintOverride: w.newPostOpen ? Theme.fgPrimary : w.inkDim
                onClicked: w.toggleNewPost()
            }

        }

        // Refresh failures stay quiet but available; the header says "stale".
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.dp(30)
            radius: Theme.dp(10)
            color: Theme.surfaceHigh
            visible: w.actionError !== "" || w.feedErrors.length > 0

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.dp(9)
                anchors.rightMargin: Theme.dp(4)
                spacing: Theme.dp(5)

                Icon {
                    name: "warning"
                    size: Theme.dp(14)
                    color: Theme.tertiary
                }

                LText {
                    Layout.fillWidth: true
                    role: "labelSmall"
                    text: w.actionError !== "" ? w.actionError : (w.feedErrors.length > 0 ? (w.feedErrors[0].message || "A stream could not refresh") : "")
                    color: w.inkDim
                    elide: Text.ElideRight
                }

                IconButton {
                    icon: "close"
                    size: "xs"
                    onClicked: {
                        w.actionError = "";
                        w.feedErrors = [];
                    }
                }

            }

        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // ------------------------------------------------------------- feed
            Item {
                id: feedView

                anchors.fill: parent
                visible: w.pickerReveal < 0.01 && w.detailReveal < 0.995
                opacity: 1 - w.detailReveal * 0.35
                scale: 1 - w.detailReveal * 0.02
                transformOrigin: Item.Center

                Behavior on opacity {
                    NumberAnimation {
                        duration: Theme.durEnter
                        easing.type: Easing.Bezier
                        easing.bezierCurve: Theme.curveDefaultSpatial
                    }

                }

                Behavior on scale {
                    NumberAnimation {
                        duration: Theme.durEnter
                        easing.type: Easing.Bezier
                        easing.bezierCurve: Theme.curveDefaultSpatial
                    }

                }

                ListView {
                    id: feedScroll

                    anchors.fill: parent
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentHeight > height
                    flickableDirection: Flickable.VerticalFlick
                    spacing: Theme.dp(8)
                    // Keep a generous band of delegates alive so a fast scroll
                    // never exposes an unbuilt pocket of the list.
                    cacheBuffer: Theme.dp(3000)
                    displayMarginBeginning: Theme.dp(600)
                    displayMarginEnd: Theme.dp(600)
                    model: ScriptModel {
                        id: feedModel

                        values: w.shownItems
                        // Feed objects are stable by id. Structure comparison
                        // is both expensive and needless here, and identity
                        // keeps the anchored delegate alive across refreshes.
                        objectProp: "id"
                        comparisonMode: ObjectComparison.Identity
                    }

                    delegate: SocialPostCard {
                        required property var modelData

                        width: feedScroll.width
                        post: modelData
                        host: w
                        onActivated: w.openPost(modelData)
                        onLikeClicked: w.toggleLike(modelData)
                        onCommentsClicked: w.openPost(modelData)
                        onReplyClicked: w.openPost(modelData, true)
                        onExternalClicked: w.openExternal(modelData)
                        onDeleteClicked: w.deletePost(modelData)
                        onDismissed: w.hidePost(modelData.id)
                    }

                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: (event) => {
                            w.feedAnchorSeq++;
                            if (w.dbgScroll)
                                console.log("SCROLLDBG wheel angle", event.angleDelta.y, "pixel", event.pixelDelta.y, "cy", feedScroll.contentY.toFixed(1), "ch", feedScroll.contentHeight.toFixed(1), "max", Math.max(0, feedScroll.contentHeight - feedScroll.height).toFixed(1));
                            w.wheelBy(feedScroll, event, feedWheel);
                            event.accepted = true;
                        }
                    }

                    // Removing one post slides the rest up instead of
                    // rebuilding (and re-fading) the whole feed.
                    displaced: Transition {
                        NumberAnimation {
                            properties: "y"
                            duration: Theme.durMedium
                            easing.type: Easing.Bezier
                            easing.bezierCurve: Theme.curveDefaultSpatial
                        }

                    }

                    function clampToContent() {
                        var maxY = Math.max(0, contentHeight - height);
                        if (contentY > maxY || contentY < 0) {
                            feedWheel.stop();
                            contentY = Math.max(0, Math.min(maxY, contentY));
                        }
                    }

                    onFlickStarted: w.feedAnchorSeq++
                    onContentYChanged: {
                        w.dbgYCount++;
                        if (w.dbgScroll && Math.abs(contentY - w.dbgLastY) > 80)
                            console.log("SCROLLDBG y-jump", w.dbgLastY.toFixed(1), "->", contentY.toFixed(1), "ch", contentHeight.toFixed(1), "ci", currentIndex, "origin", originY.toFixed(1), "begin", atYBeginning, "end", atYEnd, "wheel", feedWheel.running, "moving", moving, "flicking", flicking);
                        w.dbgLastY = contentY;
                        if (w.dbgScroll && (w.dbgYCount % 12 === 0 || feedWheel.running))
                            console.log("SCROLLDBG y", contentY.toFixed(1), "ch", contentHeight.toFixed(1), "wheel", feedWheel.running, "moving", moving, "flicking", flicking);
                        var limit = Math.max(0, contentHeight - height);
                        if (contentY < 0 || contentY > limit) {
                            if (w.dbgScroll)
                                console.log("SCROLLDBG y-clamp", contentY.toFixed(1), "limit", limit.toFixed(1));
                            feedWheel.stop();
                            contentY = Math.max(0, Math.min(limit, contentY));
                        }
                        w.maybeLoadMoreFeed();
                    }
                    onContentHeightChanged: {
                        if (w.dbgScroll)
                            console.log("SCROLLDBG height-changed", contentHeight.toFixed(1), "cy", contentY.toFixed(1), "count", count);
                        Qt.callLater(clampToContent);
                        Qt.callLater(w.maybeLoadMoreFeed);
                    }
                    onOriginYChanged: {
                        if (w.dbgScroll)
                            console.log("SCROLLDBG origin-changed", originY.toFixed(1), "cy", contentY.toFixed(1), "ch", contentHeight.toFixed(1), "count", count, "ci", currentIndex, "begin", atYBeginning);
                    }
                    onCountChanged: {
                        if (w.dbgScroll)
                            console.log("SCROLLDBG count-changed", count, "cy", contentY.toFixed(1), "ch", contentHeight.toFixed(1), "ci", currentIndex, "origin", originY.toFixed(1));
                        if (w.dbgScroll)
                            console.log("SCROLLDBG count-changed", count, "cy", contentY.toFixed(1), "ch", contentHeight.toFixed(1));
                        feedWheel.stop();
                        Qt.callLater(clampToContent);
                    }
                    onMovementEnded: {
                        w.dbgFeed("movement-ended");
                        clampToContent();
                        w.maybeLoadMoreFeed();
                    }
                    onMovementStarted: w.dbgFeed("movement-started")
                }

                // scroll affordance: a restrained material rail, not a full bar
                Rectangle {
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.dp(1)
                    width: Theme.dp(3)
                    radius: Theme.dp(2)
                    height: Math.max(Theme.dp(22), feedScroll.height * feedScroll.height / Math.max(1, feedScroll.contentHeight))
                    y: (feedScroll.height - height) * Math.max(0, Math.min(1, feedScroll.contentY / Math.max(1, feedScroll.contentHeight - feedScroll.height)))
                    color: Theme.alpha(w.ink, 0.2)
                    visible: feedScroll.contentHeight > feedScroll.height + Theme.dp(4)
                }

                // loading / empty / error
                ColumnLayout {
                    anchors.centerIn: parent
                    width: Math.min(parent.width - Theme.dp(24), Theme.dp(300))
                    spacing: Theme.dp(8)
                    opacity: w.shownItems.length === 0 ? 1 : 0
                    visible: opacity > 0.01

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.durMedium
                            easing.type: Easing.Bezier
                            easing.bezierCurve: Theme.curveDefaultSpatial
                        }

                    }

                    LoadingIndicator {
                        Layout.alignment: Qt.AlignHCenter
                        visible: w.phase === "loading" && !w.preview
                        running: visible
                        color: Theme.primary
                    }

                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        width: Theme.dp(44)
                        height: Theme.dp(44)
                        radius: width / 2
                        color: Theme.surfaceHigh
                        visible: w.phase !== "loading" || w.preview

                        Icon {
                            anchors.centerIn: parent
                            name: w.fatal !== "" ? "warning" : (w.searchQuery !== "" ? "search" : "hub")
                            size: Theme.dp(22)
                            color: w.fatal !== "" ? Theme.error : w.inkDim
                        }

                    }

                    LText {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        role: "titleSmall"
                        text: w.fatal !== "" ? "The feed is not reachable" : (w.phase === "loading" ? "Gathering streams…" : (w.searchQuery !== "" && w.items.length > 0 ? "No matching posts" : (w.items.length > 0 ? "You're all caught up" : "Nothing selected yet")))
                        color: w.ink
                        wrapMode: Text.Wrap
                        visible: w.phase !== "loading" || w.preview || w.fatal !== ""
                    }

                    LText {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        role: "bodySmall"
                        text: w.fatal !== "" ? w.fatal : (w.phase === "loading" ? "The first fetch can take a few seconds." : (w.searchQuery !== "" && w.items.length > 0 ? "Try a shorter or earlier part of the words you remember." : (w.items.length > 0 ? "Swipe left or right on a post to hide it." : "Choose sources from the hub button, or add a source in ~/.config/lucid-social/config.toml.")))
                        color: w.inkFaint
                        wrapMode: Text.Wrap
                        visible: w.phase !== "loading" || w.preview || w.fatal !== ""
                    }

                    Button {
                        Layout.alignment: Qt.AlignHCenter
                        visible: w.phase !== "loading" || w.fatal !== ""
                        variant: "tonal"
                        size: "xs"
                        icon: w.fatal !== "" ? "refresh" : "hub"
                        text: w.fatal !== "" ? "Retry" : "Choose sources"
                        onClicked: {
                            if (w.fatal !== "")
                                w.retry();
                            else
                                w.togglePicker();
                        }
                    }

                }

            }

            // ----------------------------------------------------------- detail
            Item {
                id: detailView

                anchors.fill: parent
                visible: w.pickerReveal < 0.01 && w.detailReveal > 0.01
                opacity: w.detailReveal
                x: (1 - w.detailReveal) * Theme.dp(22)
                scale: 0.97 + w.detailReveal * 0.03
                transformOrigin: Item.Left

                Behavior on opacity {
                    NumberAnimation {
                        duration: w.detailOpen ? Theme.durEnter : Theme.durExit
                        easing.type: Easing.Bezier
                        easing.bezierCurve: Theme.curveDefaultSpatial
                    }

                }

                Behavior on scale {
                    NumberAnimation {
                        duration: w.detailOpen ? Theme.durEnter : Theme.durExit
                        easing.type: Easing.Bezier
                        easing.bezierCurve: Theme.curveDefaultSpatial
                    }

                }

                Behavior on x {
                    NumberAnimation {
                        duration: w.detailOpen ? Theme.durEnter : Theme.durExit
                        easing.type: Easing.Bezier
                        easing.bezierCurve: Theme.curveDefaultSpatial
                    }

                }

                ColumnLayout {
                    anchors.fill: parent
                    spacing: Theme.dp(6)

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.dp(4)

                        IconButton {
                            icon: "arrow_back"
                            size: "xs"
                            onClicked: w.closeDetail()
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.dp(6)

                            LText {
                                Layout.maximumWidth: parent.width - (w.threadPresence !== "" ? Theme.dp(22) : 0)
                                role: "titleMedium"
                                text: w.threadTitle()
                                color: w.ink
                                elide: Text.ElideRight
                            }

                            Rectangle {
                                Layout.alignment: Qt.AlignVCenter
                                width: Theme.dp(9)
                                height: width
                                radius: width / 2
                                color: w.presenceColor(w.threadPresence)
                                visible: w.threadPresence !== ""
                            }

                            Item {
                                Layout.fillWidth: true
                            }

                        }

                    }

                    Flickable {
                        id: detailScroll

                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentWidth: width
                        contentHeight: detailColumn.height
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        interactive: contentHeight > height && !w.threadAutoScrolling
                        onMovementStarted: w.contextAnchorPending = false
                        onContentYChanged: {
                            if (contentY + height >= contentHeight - Theme.dp(80))
                                w.maybeAutoLoadComments();

                            if (contentY <= 2 && w.contextReady && w.contextHasMore
                                && !w.contextLoading && w.detailPost !== null
                                && w.detailPost.source === "discord")
                                w.loadContext(w.contextCursor);

                        }
                        onContentHeightChanged: {
                            w.maybeAutoLoadComments();
                            if (w.contextAnchorPending && !w.threadAutoScrolling) {
                                var delta = contentHeight - w.contextAnchorHeight;
                                if (delta > 0) {
                                    contentY = Math.max(0, w.contextAnchorY + delta);
                                    w.contextAnchorPending = false;
                                }
                            }
                            if (w.threadAutoScrolling && w.detailOpen)
                                Qt.callLater(function () { w.threadScrollToBottomNow(); });
                        }

                        WheelHandler {
                            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                            onWheel: (event) => {
                                if (w.threadAutoScrolling) {
                                    event.accepted = true;
                                    return ;
                                }
                                w.contextAnchorPending = false;
                                w.wheelBy(detailScroll, event, detailWheel);
                                event.accepted = true;
                            }
                        }

                        Column {
                            id: detailColumn

                            width: detailScroll.width
                            spacing: 0

                            Column {
                                width: detailColumn.width
                                spacing: 0

                                LText {
                                    width: parent.width
                                    visible: w.contextLoading
                                    horizontalAlignment: Text.AlignHCenter
                                    role: "labelSmall"
                                    text: "Loading earlier messages…"
                                    color: w.inkFaint
                                    topPadding: Theme.dp(8)
                                    bottomPadding: Theme.dp(4)
                                }

                                Repeater {
                                    model: w.contextView

                                    SocialCommentRow {
                                        required property var modelData
                                        required property int index

                                        comment: modelData
                                        host: w
                                        context: true
                                        firstInChain: index === 0
                                        lastInChain: index === w.contextView.length - 1
                                    }
                                }
                            }

                            SocialPostCard {
                                id: detailRoot

                                width: detailColumn.width
                                post: w.detailPost || ({})
                                host: w
                                detail: true
                                onActivated: {}
                                onLikeClicked: w.toggleLike(w.detailPost)
                                onCommentsClicked: {}
                                onReplyClicked: w.startPostReply(w.detailPost)
                                onExternalClicked: w.openPostUrl()
                                onDeleteClicked: w.deletePost(w.detailPost)
                            }

                            RowLayout {
                                width: detailColumn.width
                                height: Theme.dp(38)
                                spacing: Theme.dp(6)

                                LText {
                                    Layout.leftMargin: Theme.dp(14)
                                    Layout.fillWidth: true
                                    role: "labelLarge"
                                    text: (w.threadCommentTotal >= 0 ? w.threadCommentTotal : (w.detailPost && w.detailPost.comment_count !== null && w.detailPost.comment_count !== undefined ? w.detailPost.comment_count : w.comments.length)) + " comments"
                                    color: w.ink
                                }

                                LoadingIndicator {
                                    Layout.preferredWidth: Theme.dp(20)
                                    Layout.preferredHeight: Theme.dp(20)
                                    visible: w.commentsLoading
                                    running: w.commentsLoading
                                    color: Theme.primary
                                }

                            }

                            Repeater {
                                model: w.commentView

                                Item {
                                    id: commentSlot

                                    required property var modelData

                                    width: detailColumn.width
                                    height: modelData.kind === "more" ? moreText.implicitHeight + Theme.dp(12) : commentRow.height

                                    SocialCommentRow {
                                        id: commentRow

                                        visible: commentSlot.modelData.kind === "comment"
                                        comment: commentSlot.modelData.comment || ({})
                                        host: w
                                        firstInChain: commentSlot.modelData.firstInChain === true
                                        lastInChain: commentSlot.modelData.lastInChain === true
                                        onReplyRequested: w.startReply(commentSlot.modelData.comment)
                                        onLikeClicked: w.toggleCommentLike(commentSlot.modelData.comment)
                                        onDeleteRequested: w.deleteComment(commentSlot.modelData.comment)
                                    }

                                    Item {
                                        width: parent.width
                                        height: parent.height
                                        visible: commentSlot.modelData.kind === "more"

                                        Rectangle {
                                            anchors.left: parent.left
                                            anchors.leftMargin: Theme.dp(27)
                                            anchors.top: parent.top
                                            anchors.bottom: parent.bottom
                                            anchors.bottomMargin: commentSlot.modelData.lastInChain === true ? Math.max(0, parent.height / 2) : 0
                                            width: 1
                                            visible: !(commentSlot.modelData.firstInChain === true && commentSlot.modelData.lastInChain === true)
                                            color: Theme.alpha(w.ink, 0.16)
                                        }

                                        LText {
                                            id: moreText

                                            anchors.left: parent.left
                                            anchors.leftMargin: Theme.dp(47)
                                            anchors.verticalCenter: parent.verticalCenter
                                            role: "labelLarge"
                                            text: "Show " + commentSlot.modelData.hidden + " " + (commentSlot.modelData.hidden === 1 ? "reply" : "replies")
                                            color: Theme.primary
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.leftMargin: Theme.dp(40)
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: w.expandBranch(commentSlot.modelData.parentId)
                                        }

                                    }

                                }

                            }

                            ColumnLayout {
                                width: detailColumn.width
                                spacing: Theme.dp(6)
                                visible: !w.commentsLoading && w.comments.length === 0

                                LText {
                                    Layout.fillWidth: true
                                    Layout.topMargin: Theme.dp(8)
                                    horizontalAlignment: Text.AlignHCenter
                                    role: "bodySmall"
                                    text: w.commentsError !== "" ? w.commentsError : "No comments yet. Start the thread."
                                    color: w.commentsError !== "" ? Theme.error : w.inkFaint
                                    wrapMode: Text.Wrap
                                }

                                Button {
                                    Layout.alignment: Qt.AlignHCenter
                                    visible: w.commentsError !== ""
                                    variant: "text"
                                    size: "xs"
                                    text: "Retry"
                                    onClicked: w.loadThread(w.detailId)
                                }

                            }

                            Item {
                                width: detailColumn.width
                                height: Theme.dp(8)
                            }

                        }

                    }

                    LText {
                        Layout.fillWidth: true
                        visible: w.composeError !== ""
                        role: "labelSmall"
                        text: w.composeError
                        color: Theme.error
                        elide: Text.ElideRight
                    }

                    SocialComposer {
                        id: composer

                        Layout.fillWidth: true
                        host: w
                        ink: w.ink
                        emojiCatalog: w.emojiCatalog
                        emojiUsage: w.emojiUsageCounts
                        replyName: w.replyName
                        busy: false
                        placeholder: "Reply..."
                        onSend: (body, images) => w.postComment(body, images)
                        onCancelReply: w.cancelReply()
                    }

                }

            }

            // ---------------------------------------------------------- New Post
            Item {
                id: newPostView

                anchors.fill: parent
                visible: w.newPostOpen
                z: 15

                SquircleRect {
                    anchors.fill: parent
                    anchors.margins: Theme.dp(4)
                    radius: Theme.rad(16)
                    fillColor: w.fill
                    smoothing: Prefs.squircleF
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Theme.dp(14)
                    spacing: Theme.dp(6)

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.dp(4)

                        IconButton {
                            icon: "close"
                            size: "xs"
                            tooltip: "Cancel New Post"
                            onClicked: w.closeNewPost()
                        }

                        LText {
                            Layout.fillWidth: true
                            role: "titleMedium"
                            text: "New Post"
                            color: w.ink
                        }

                        LText {
                            role: "labelSmall"
                            text: w.sendTargetTitle
                            color: w.inkFaint
                            visible: text !== ""
                            elide: Text.ElideRight
                        }

                    }

                    ListView {
                        id: targetList

                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        spacing: Theme.dp(2)
                        model: ScriptModel {
                            values: w.shownSendTargets
                            comparisonMode: ObjectComparison.Identity
                        }

                        delegate: Rectangle {
                            id: targetRow

                            required property var modelData
                            readonly property bool selected: w.sendTargetId === String(modelData.channel_id || "") && w.sendTargetAccount === String(modelData.account || "")

                            width: targetList.width
                            height: Theme.dp(46)
                            radius: Theme.rad(10)
                            color: selected ? Theme.primaryContainer : (targetArea.containsMouse ? Theme.surfaceHigh : "transparent")

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.dp(10)
                                anchors.rightMargin: Theme.dp(8)
                                spacing: Theme.dp(8)

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0

                                    LText {
                                        Layout.fillWidth: true
                                        role: "labelLarge"
                                        text: String(targetRow.modelData.title || "")
                                        color: targetRow.selected ? Theme.fgPrimaryContainer : w.ink
                                        elide: Text.ElideRight
                                    }

                                    LText {
                                        Layout.fillWidth: true
                                        role: "labelSmall"
                                        text: String(targetRow.modelData.subtitle || "")
                                        color: targetRow.selected ? Theme.fgPrimaryContainer : w.inkFaint
                                        elide: Text.ElideRight
                                    }

                                }

                                Icon {
                                    visible: targetRow.selected
                                    name: "check"
                                    size: Theme.dp(16)
                                    color: Theme.primary
                                }

                            }

                            MouseArea {
                                id: targetArea

                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: w.selectSendTarget(targetRow.modelData)
                            }

                        }

                    }

                    LText {
                        Layout.fillWidth: true
                        visible: w.sendTargetsLoading
                        role: "bodySmall"
                        text: "Loading channels…"
                        color: w.inkFaint
                    }

                    LText {
                        Layout.fillWidth: true
                        visible: w.shownSendTargets.length === 0 && !w.sendTargetsLoading
                        role: "bodySmall"
                        text: w.newPostError !== "" ? w.newPostError : (w.channelQuery !== "" ? "No matching channels." : "No channels available.")
                        color: w.newPostError !== "" ? Theme.error : w.inkFaint
                        wrapMode: Text.Wrap
                    }

                    LText {
                        Layout.fillWidth: true
                        visible: w.shownSendTargets.length > 0 && w.newPostError !== ""
                        role: "labelSmall"
                        text: w.newPostError
                        color: Theme.error
                        elide: Text.ElideRight
                    }

                    SocialComposer {
                        id: newComposer

                        Layout.fillWidth: true
                        host: w
                        ink: w.ink
                        emojiCatalog: w.emojiCatalog
                        emojiUsage: w.emojiUsageCounts
                        busy: w.sending || w.sendTargetId === ""
                        placeholder: "Write a post..."
                        onSend: (body, images) => w.sendNewPost(body, images)
                    }

                }

            }

            // ------------------------------------------------------------ picker
            SocialSourcePicker {
                id: sourcePicker

                anchors.fill: parent
                z: 20
                visible: w.pickerReveal > 0.01
                opacity: w.pickerReveal
                scale: 0.985 + w.pickerReveal * 0.015
                sources: w.sources
                offSources: w.offSources
                offStreams: w.offStreams
                onStreams: w.onStreams
                host: w
                authBusyKey: w.authBusyKey
                authError: w.authError
                authStatus: w.authStatus
                onToggleSource: (id) => w.toggleSource(id)
                onToggleStream: (id) => w.toggleStream(id)
                onSaveCredential: (sourceId, key, value) => w.saveCredential(sourceId, key, value)
                onSaveAccount: (sourceId, accountId, name, value) => w.saveAccount(sourceId, accountId, name, value)
                onRemoveAccount: (sourceId, accountId) => w.removeAccount(sourceId, accountId)
                onCloseRequested: w.pickerOpen = false

                Behavior on opacity {
                    NumberAnimation {
                        duration: w.pickerOpen ? Theme.durEnter : Theme.durExit
                        easing.type: Easing.Bezier
                        easing.bezierCurve: Theme.curveDefaultSpatial
                    }

                }

                Behavior on scale {
                    NumberAnimation {
                        duration: w.pickerOpen ? Theme.durEnter : Theme.durExit
                        easing.type: Easing.Bezier
                        easing.bezierCurve: Theme.curveDefaultSpatial
                    }

                }

            }

        }

    }


    // Files dragged from a file manager or browser land on the active input:
    // the thread composer when a thread is open, otherwise the New Post
    // composer (opening its panel when needed).
    DropArea {
        anchors.fill: parent
        z: 1000
        enabled: w.live && !w.preview
        keys: ["text/uri-list"]

        onEntered: (drag) => {
            drag.accept(Qt.CopyAction);
        }

        onDropped: (drop) => {
            var paths = w.droppedPaths(drop.urls);
            if (paths.length === 0)
                return ;
            drop.accept(Qt.CopyAction);
            w.attachDroppedMedia(paths);
        }
    }

    SocialMediaViewer {
        id: mediaViewer

        open: w.mediaViewerOpen
        value: w.mediaViewerValue
        from: w.mediaViewerFrom
        screenObj: w.mediaViewerScreen
        service: w.service
        previewSource: w.mediaViewerPreviewSource
        previewWidth: w.mediaViewerPreviewWidth
        previewHeight: w.mediaViewerPreviewHeight
        clipRect: w.mediaViewerClip
        onCloseRequested: w.closeMediaViewer()
        onDismissed: {
            w.mediaViewerOpen = false;
            w.mediaViewerValue = null;
            w.mediaViewerPreviewSource = "";
        }
    }

}

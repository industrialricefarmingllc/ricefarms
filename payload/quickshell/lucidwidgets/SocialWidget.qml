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
    readonly property int schemaVersion: 2
    readonly property int feedLimit: 20
    // Search pages stay small so a deep X page only has to collect what the
    // card will show instead of the whole profile tail.
    readonly property int searchPageLimit: 60

    // Per-card selection.  Off-lists rather than on-lists, so a new stream that
    // appears later starts on, while every explicit choice is still remembered.
    readonly property var offSources: w.listOpt("socialSourcesOff")
    readonly property var offStreams: w.listOpt("socialStreamsOff")
    readonly property var onStreams: w.listOpt("socialStreamsOn")
    readonly property var hiddenItems: w.listOpt("socialHidden")

    property var sources: []
    property var streamErrors: []
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
    // A refresh response must not move the model under the reader's wheel.
    // While the feed is being scrolled, the response is parked here and
    // applied once the list has been still for a moment.
    property bool feedScrolling: false
    property string pendingFeedText: ""
    // The main feed keeps refreshing while a thread is open. Remember what
    // the reader was looking at so closing the thread returns there instead
    // of to a position that the background model updates have moved.
    property var feedReturnAnchor: null
    // Bumped when the feed model is replaced underneath an anchor restore
    // (opening/closing a profile), so a stale callLater cannot move the list.
    property int feedScrollEpoch: 0
    property bool pickerOpen: false
    property bool newPostOpen: false
    property var sendTargets: []
    // Channel rows are checkboxes. The first one is also the primary target:
    // it supplies the header label and the post that gets focused after send.
    property var selectedSendTargets: []
    property string sendCursorKey: ""
    property var sendJobs: []
    property var sendFailedTargets: []
    property string sendBatchError: ""
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
    property bool contextGrouped: false
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
    // Discord threads stay pinned to newest while opening (and as context and
    // images arrive) until the reader scrolls or drags the conversation.
    property bool threadBottomFollow: false
    property bool threadUserScrolled: false
    property int threadLimit: 20
    property bool nestedFilled: false
    property bool threadHoldPosition: false
    property var threadAnchor: null
    property real threadReloadOffset: -1
    property real threadReloadUntil: 0
    // The comment a send should reveal. The row can be a group whose height
    // grows after the first layout, so a second alignment runs once it settles.
    property var threadScrollTarget: null
    // Replies to a reply stay hidden until their parent is explicitly expanded.
    property int branchPreviewLimit: 0
    property var expandedBranches: ({})
    readonly property var groupedComments: {
        if (w.detailPost === null || w.detailPost.source !== "discord")
            return w.comments;
        return w.groupComments(w.comments);
    }
    readonly property var commentView: w.buildCommentView(w.groupedComments)
    property string replyTo: ""
    property string replyName: ""
    property string composeError: ""
    // One entry per in-flight comment. Each send owns a row in `comments`
    // from the moment Enter is pressed, so several can be in flight at once.
    property var commentJobs: []
    // Per source/account author cache. A single slot let one Discord account's
    // avatar paint another account's optimistic comment.
    property var cachedOwnAuthors: ({})
    property var optimisticLikes: ({})
    readonly property var cachedOwnAuthor: {
        var context = w.ownAuthorContext();
        var key = w.ownAuthorKey(context.source, context.account);
        return key !== "" ? (w.cachedOwnAuthors[key] || null) : null;
    }

    // Decode the account's avatar at the comment-avatar size in the
    // background, so the optimistic row can paint it from Qt's image cache
    // instead of waiting for a network fetch.
    Image {
        id: ownAvatarPreload

        visible: false
        cache: true
        asynchronous: true
        source: (w.cachedOwnAuthor && String(w.cachedOwnAuthor.avatar_url || "") !== "")
            ? String(w.cachedOwnAuthor.avatar_url)
            : ""
        sourceSize.width: Math.max(1, Math.round(Theme.dp(28) * 3))
        sourceSize.height: Math.max(1, Math.round(Theme.dp(28) * 3))
    }
    property int pendingSeq: 0
    property var likeQueue: []
    property var reactionQueue: []
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
    // events.json is replaced atomically, so the file watcher can stop firing
    // after the first write. Poll it too and dedupe by the gateway timestamp.
    // The file keeps a short list so an unrelated channel cannot overwrite
    // the event that should wake this card.
    property string discordEventStamp: ""
    property double discordLastEventAt: 0
    // TYPING_START from the Discord gateway, keyed by account and channel.
    property var typingState: ({})
    property int typingTick: 0
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
    property int clockTick: 0
    property string searchQuery: ""
    property string threadSearchQuery: ""
    // Profile view: a Twitter-style header over the author's own posts.
    property var profileAuthor: null
    property var profileMeta: ({})
    property var profileTabs: []
    property string profileSource: ""
    property string profileQuery: ""
    property string profileCacheKey: ""
    property string profileTab: ""
    property string profileFilter: ""
    property string profileAccount: ""
    property string profileChannel: ""
    property string profileGuild: ""
    property string profileUserId: ""
    property bool profileBusy: false
    property real profileHeaderHeight: 0
    property bool profileFollowing: false
    property bool profileFollowBusy: false
    property string profileError: ""
    property bool pendingProfileTarget: false
    readonly property bool profileOpen: w.profileAuthor !== null
    readonly property color profileTint: {
        var value = String((w.profileMeta || {}).accent_color || "");
        return value !== "" ? value : w.profileColor(w.profileSource);
    }
    readonly property var profileTabOptions: {
        var out = [];
        for (var i = 0; i < w.profileTabs.length; i++) {
            var tab = w.profileTabs[i] || ({});
            out.push({"key": String(tab.id || ""), "label": Tr.t(String(tab.title || ""))});
        }
        return out;
    }
    property string channelQuery: ""
    // Service-side search: channels first, then a seven-day local index.
    property var searchResults: []
    property var searchChannels: []
    property var searchScopeStreams: []
    property string searchResultQuery: ""
    property bool searchServed: false
    property bool searchLoading: false
    property bool searchDirty: false
    // A cursor page keeps walking the matched channel or user, so scrolling a
    // result list behaves like scrolling the feed.
    property bool searchHasMore: false
    property bool searchMoreLoading: false
    property bool searchMorePending: false
    property bool searchAppend: false
    property bool searchPrefetching: false
    property string searchMode: ""
    property string searchNextBefore: ""
    property string searchNextBeforeId: ""

    readonly property var sample: w.preview ? w.sampleItems() : []
    readonly property bool initialLoading: !w.preview && w.shownItems.length === 0
        && (w.phase === "loading" || w.searchLoading || w.feedLoadingMore)
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
                var inSearchScope = false;
                for (var s = 0; s < streamIds.length; s++) {
                    if (w.streamOn(String(streamIds[s])))
                        streamVisible = true;
                    if (w.searchScopeStreams.indexOf(String(streamIds[s])) >= 0)
                        inSearchScope = true;
                }
                if (!streamVisible) {
                    // A search can name a channel or live user that is not one
                    // of this card's streams; keep those hits on screen.
                    if (!inSearchScope && w.searchQuery === "")
                        continue;
                }
            }
            if (w.sources.length > 0 && w.sourceInfo(String(item.source || "")) === null)
                continue;

            if (w.optimisticLikes[item.id])
                item = Object.assign({}, item, w.optimisticLikes[item.id]);
            seen[item.id] = true;
            out.push(item);
        }
        // The service already merges by time; doing it again here keeps the
        // card correct if a source ever returns streams in a different order.
        out.sort((a, b) => {
            var when = w.feedTime(b) - w.feedTime(a);
            if (when !== 0)
                return when;
            var aid = String(a.id), bid = String(b.id);
            return bid < aid ? -1 : (bid > aid ? 1 : 0);
        });
        var query = w.searchQuery.trim();
        if (query === "")
            return w.filterProfile(out);

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
        matches.sort((a, b) => (b.score - a.score) || (w.feedTime(b.item) - w.feedTime(a.item)));
        var local = [];
        for (var k = 0; k < matches.length; k++)
            local.push(matches[k].item);

        // While the service is still answering, the local page gives instant
        // feedback. Once it replies, combine its older hits with the local
        // ones (new posts may not be indexed yet).
        if (!w.searchServed || w.searchResultQuery !== query)
            return w.filterProfile(local);

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
        for (var id in byId) {
            var combinedItem = byId[id];
            if (w.optimisticLikes[id])
                combinedItem = Object.assign({}, combinedItem, w.optimisticLikes[id]);
            combined.push(combinedItem);
        }
        combined.sort((a, b) => {
            var when = w.feedTime(b) - w.feedTime(a);
            if (when !== 0)
                return when;
            var aid = String(a.id), bid = String(b.id);
            return bid < aid ? -1 : (bid > aid ? 1 : 0);
        });
        return combined;
    }
    readonly property var feedValues: {
        if (!w.profileOpen)
            return w.shownItems;
        return [{"id": "__profile_header__", "kind": "profile_header"}].concat(w.shownItems);
    }
    readonly property var typingEntries: {
        // Reading the tick keeps the label honest as entries expire.
        var tick = w.typingTick;
        var post = w.detailPost;
        if (!w.detailOpen || post === null)
            return [];
        var parts = String(post.id || "").split("/");
        if (parts.length < 3 || parts[0] !== "discord")
            return [];
        var slug = "";
        var ids = post.stream_ids || [];
        for (var s = 0; s < ids.length; s++) {
            var stream = w.streamById(String(ids[s]));
            if (stream !== null) {
                slug = String((stream.extra || {}).account || "");
                break;
            }
        }
        var accounts = (w.typingState || {}).accounts || ({});
        var entries = ((accounts[slug] || ({}))[parts[1]]) || [];
        var now = Date.now() / 1000;
        var out = [];
        for (var i = 0; i < entries.length; i++) {
            var entry = entries[i] || ({});
            if (Number(entry.until || 0) > now)
                out.push(entry);
        }
        return out;
    }
    readonly property string typingLabel: {
        var entries = w.typingEntries;
        if (entries.length === 0)
            return "";
        var names = [];
        for (var i = 0; i < entries.length; i++) {
            var name = String(entries[i].name || "").trim();
            if (name === "")
                name = Tr.t("Someone");
            if (names.indexOf(name) < 0)
                names.push(name);
        }
        if (names.length === 1)
            return Tr.fmt("%1 is typing…", names[0]);
        if (names.length === 2)
            return Tr.fmt("%1 and %2 are typing…", names[0], names[1]);
        return Tr.t("Several people are typing…");
    }
    readonly property var contextView: {
        var source = w.contextComments;
        // The service pre-groups Discord context with the same rules the
        // thread comments use. Do not regroup it in the UI after it lands.
        if (w.contextGrouped) {
            var preGrouped = [];
            for (var p = 0; p < source.length; p++) {
                var grouped = source[p];
                if (!grouped)
                    continue;
                var groupedCopy = Object.assign({}, grouped);
                groupedCopy.body_segments = (grouped.body_segments && grouped.body_segments.length ? grouped.body_segments.slice() : (grouped.body ? [String(grouped.body)] : []));
                groupedCopy.media = (grouped.media || []).slice();
                preGrouped.push(groupedCopy);
            }
            return preGrouped;
        }
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
            var lastMedia = last !== null ? (last.media || []).length : 0;
            var valueMedia = (value.media || []).length;
            if (last !== null && key !== "" && key === lastAuthor && groupStart > 0 && when > 0
                && when - groupStart <= 7200000 && lastMedia === 0 && valueMedia === 0) {
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
            return Tr.t("Feed service unavailable");

        var count = w.activeStreams;
        var label = count + (count === 1 ? Tr.t(" stream") : Tr.t(" streams"));
        if (w.actionError !== "")
            return label + Tr.t(" · action failed");

        if (w.feedErrors.length > 0)
            return label + " · " + w.feedErrors.length + Tr.t(" stale");

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
                    "id": String(entry.id || ""),
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

    // Plain-text labels (author names) use StyledText so an emoji can be an
    // inline SVG with an explicit width; RichText ignores elide.
    function emojiLabel(value, size) {
        return SocialEmoji.emojiHtml(SocialEmoji.escapeHtml(String(value || "")), size, w.emojiBase);
    }

    function cssColor(color, opacity) {
        var alpha = Number(color.a === undefined ? 1 : color.a) * (opacity === undefined ? 1 : opacity);
        return "rgba(" + Math.round(color.r * 255) + "," + Math.round(color.g * 255)
            + "," + Math.round(color.b * 255) + "," + alpha.toFixed(3) + ")";
    }

    // Markdown is rendered with the same palette as the card it sits on.
    // Keeping these as CSS colour strings lets the rich-text HTML use them
    // directly. Quotes reuse the body ink at 60% opacity instead of a block
    // background.
    readonly property var markdownColors: ({
        "quoteBar": Theme.toHex(Theme.primary),
        "quoteText": w.cssColor(w.inkDim, 0.6),
        "codeBg": Theme.toHex(Theme.surfaceContainer),
        "codeText": Theme.toHex(Theme.text),
        "rule": Theme.toHex(Theme.outline)
    })

    function emojiRich(value, size) {
        return SocialEmoji.rich(value, size, w.emojiBase, w.markdownColors, Math.max(1, size - 2));
    }

    // Discord bodies: Twemoji for Unicode, the CDN image for <:name:id> tags,
    // and the CDN image for Vencord/Equicord FakeNitro links. `linkify` also
    // keeps ordinary URLs clickable in the post cards.
    function discordRich(value, size, linkify, linkColor) {
        return SocialEmoji.discord(value, size, w.emojiBase, w.emojiTransparent, linkify, linkColor, true, w.markdownColors, Math.max(1, size - 2));
    }

    // Compact snippet text (comment previews): emoji images, but no jumbo.
    // Animated emoji use their first frame because there is no overlay here.
    function previewRich(value, size) {
        return SocialEmoji.discord(value, size, w.emojiBase, "", false, "#000000", false, w.markdownColors, Math.max(1, size - 2));
    }

    // Like discordRich, but also reports every emitted image in document
    // order so SocialBody can overlay live GIFs on animated custom emoji.
    function discordParts(value, size, linkify, linkColor) {
        return SocialEmoji.discordParts(value, size, w.emojiBase, w.emojiTransparent, linkify, linkColor, true, w.markdownColors, Math.max(1, size - 2));
    }

    // A FakeNitro emoji link is the emoji itself. Media parsers must leave it
    // in the body so the emoji renderer can paint it.
    function isEmojiLink(value) {
        return SocialEmoji.isEmojiCdn(value);
    }

    function emojiIds(value) {
        var ids = [];
        var text = String(value || "");
        var pattern = /\/emojis\/(\d+)\./g;
        var match;
        while ((match = pattern.exec(text)) !== null)
            ids.push(match[1]);
        return ids;
    }

    function commentMessageIds(value) {
        var ref = (value || {}).ref || ({});
        var ids = [];
        var list = ref.message_ids || [];
        for (var i = 0; i < list.length; i++) {
            var id = String(list[i] || "");
            if (id !== "" && ids.indexOf(id) < 0)
                ids.push(id);
        }
        if (ref.message_id) {
            var primary = String(ref.message_id);
            if (ids.indexOf(primary) < 0)
                ids.push(primary);
        }
        return ids;
    }

    function firstMessageId(value) {
        var ref = (value || {}).ref || ({});
        var ids = ref.message_ids || [];
        var first = String(ids.length > 0 ? ids[0] : (ref.message_id || ""));
        var tail = first.split("/").pop();
        return /^\d+$/.test(tail) ? tail : "";
    }

    // The feed decided which Discord messages belong to the post body. A
    // thread response must not paint one of them again as a comment: the
    // opened post keeps exactly the grouping the reader saw in the feed.
    function postCoversComment(post, row) {
        if (!post || post.source !== "discord" || !row)
            return false;
        var ref = post.ref || ({});
        var group = [];
        var list = ref.message_ids || [];
        for (var i = 0; i < list.length; i++) {
            if (String(list[i] || "") !== "")
                group.push(String(list[i]));
        }
        if (ref.message_id && group.indexOf(String(ref.message_id)) < 0)
            group.push(String(ref.message_id));
        if (group.length === 0)
            return false;
        var ids = w.commentMessageIds(row);
        for (var j = 0; j < ids.length; j++) {
            if (group.indexOf(String(ids[j])) >= 0)
                return true;
        }
        return false;
    }

    // A stale preview can hold a group and its own tail as separate rows.
    // Keep the outermost row for each message set.
    function dropCoveredComments(rows) {
        var source = rows || [];
        var out = [];
        for (var i = 0; i < source.length; i++) {
            var row = source[i];
            if (!row)
                continue;
            var own = w.commentMessageIds(row);
            var covered = false;
            if (own.length > 0) {
                for (var j = 0; j < source.length; j++) {
                    if (j === i)
                        continue;
                    var other = w.commentMessageIds(source[j]);
                    if (other.length <= own.length)
                        continue;
                    var all = true;
                    for (var k = 0; k < own.length; k++) {
                        if (other.indexOf(own[k]) < 0) {
                            all = false;
                            break;
                        }
                    }
                    if (all) {
                        covered = true;
                        break;
                    }
                }
            }
            if (!covered)
                out.push(row);
        }
        return out;
    }

    function threadMatches(row) {
        var query = w.threadSearchQuery.trim().toLowerCase();
        if (query === "")
            return true;
        var who = (row || {}).author || ({});
        var text = [w.commentText(row), who.display_name, who.handle, row && row.title]
            .map(function (value) { return String(value || "").toLowerCase(); })
            .join(" ");
        return text.indexOf(query) >= 0;
    }

    function commentText(row) {
        var body = String((row || {}).body || "");
        if (body !== "")
            return body;
        var segments = (row || {}).body_segments || [];
        return segments.length > 0 ? segments.join("\n") : "";
    }

    function commentTextKey(value) {
        var text = w.commentText(value);
        text = text
            .replace(/https?:\/\/(?:cdn\.discordapp\.com|media\.discordapp\.net)\/emojis\/\d+\.(?:png|gif|webp)(?:\?[^\s]*)?/gi, ":emoji:")
            .replace(/<a?:[A-Za-z0-9_]+:\d+>/g, ":emoji:");
        return text.replace(/\s+/g, " ").trim();
    }

    function sameCommentContent(a, b) {
        if (!a || !b)
            return false;
        if (w.commentTextKey(a) !== w.commentTextKey(b))
            return false;
        if (JSON.stringify(a.media || []) !== JSON.stringify(b.media || []))
            return false;
        if (Number(a.comment_count || 0) !== Number(b.comment_count || 0))
            return false;
        return true;
    }

    function emojiOnlyRest(value) {
        return String(value || "")
            .replace(/https?:\/\/(?:cdn\.discordapp\.com|media\.discordapp\.net)\/emojis\/\d+\.(?:png|gif|webp)(?:\?[^\s]*)?/gi, "")
            .replace(/<a?:[A-Za-z0-9_]+:\d+>/g, "")
            .trim();
    }

    // Discord paints a custom emoji by putting its CDN link in a message of
    // its own. If that message and the surrounding text end up as two rows,
    // both carry the emoji. Keep the text row and drop the emoji-only one.
    function dropSplitEmojiComments(rows) {
        var out = [];
        for (var i = 0; i < rows.length; i++) {
            var row = rows[i];
            if (!row)
                continue;
            var text = w.commentText(row);
            var ids = w.emojiIds(text);
            if (ids.length === 0 || w.emojiOnlyRest(text) !== "") {
                out.push(row);
                continue;
            }
            var author = String((row.author || {}).id || (row.author || {}).handle || "");
            var when = Date.parse(row.created_at);
            var duplicate = false;
            for (var j = 0; j < rows.length && !duplicate; j++) {
                if (j === i)
                    continue;
                var other = rows[j];
                if (!other)
                    continue;
                if (String((other.author || {}).id || (other.author || {}).handle || "") !== author)
                    continue;
                var otherText = w.commentText(other);
                if (w.emojiOnlyRest(otherText) === "")
                    continue;
                var away = Math.abs(Date.parse(other.created_at) - when);
                if (!isFinite(away) || away > 120000)
                    continue;
                var otherIds = w.emojiIds(otherText);
                var covered = otherIds.length > 0;
                for (var k = 0; k < ids.length && covered; k++) {
                    if (otherIds.indexOf(ids[k]) < 0)
                        covered = false;
                }
                if (covered)
                    duplicate = true;
            }
            if (!duplicate)
                out.push(row);
        }
        return out;
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

    function commentMessageCount(comment) {
        var ref = (comment || {}).ref || ({});
        var ids = ref.message_ids || [];
        var seen = ({});
        var total = 0;
        for (var i = 0; i < ids.length; i++) {
            var id = String(ids[i] || "");
            if (id !== "" && seen[id] !== true) {
                seen[id] = true;
                total += 1;
            }
        }
        return total > 0 ? total : 1;
    }

    function commentsMessageCount(values) {
        var total = 0;
        for (var i = 0; i < (values || []).length; i++)
            total += w.commentMessageCount(values[i]);
        return total;
    }

    // A Discord conversation is ordered by its newest message. Other sources
    // keep their post time. The service uses the same value for pagination.
    function feedTimeText(item) {
        if (!item)
            return "";
        var extra = item.extra || {};
        var latest = extra.latest || {};
        return String(latest.created_at || item.created_at || "");
    }

    function feedTime(item) {
        var value = Date.parse(w.feedTimeText(item));
        return isFinite(value) ? value : 0;
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
        // The first feed request waits for the stream list. The card's saved
        // stream selection (Discord in particular) is read through the frame
        // and may not be populated at Component.onCompleted; sending the feed
        // before it settles leaves Discord out of the first page.
    }

    Component.onCompleted: w.boot()
    onLiveChanged: {
        if (w.live)
            w.boot();

    }
    // Looking at the card is a request for what is current: refresh on entry
    // and keep a three-second cache-read loop while the pointer is here.
    onHoveredChanged: {
        if (w.hovered && w.live && !w.preview && w.booted && !feedProc.running && !w.feedBusy())
            w.loadFeed(true, false, true);
    }
    onSearchQueryChanged: {
        if (w.detailOpen) {
            // The global feed is behind the thread; typing searches the open
            // thread through threadSearchQuery instead.
            searchInput.text = w.threadSearchQuery;
            return ;
        }
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
    // Once the feed is visible again, return to the post that was under the
    // reader before the thread opened. The feed may have refreshed meanwhile.
    onDetailRevealChanged: {
        if (!w.detailOpen && w.detailReveal <= 0.01 && w.feedReturnAnchor !== null) {
            var anchor = w.feedReturnAnchor;
            w.feedReturnAnchor = null;
            Qt.callLater(function () { w.restoreFeedAnchor(anchor); });
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

    Timer {
        interval: 1000
        repeat: true
        // Only while a thread is open: this is what makes a typing entry
        // disappear when the source never sends a stop event.
        running: w.live && !w.preview && w.detailOpen
        onTriggered: {
            w.typingTick++;
            // A cleaned cache deletes the file. Re-read while quiet so a
            // recreated one is picked up even if the watch missed creation.
            if (w.typingLabel === "")
                discordTyping.reload();
        }
    }

    Timer {
        interval: 3000
        repeat: true
        // Keep what is on screen current. --refresh only touches the network
        // when a source is past its own TTL, so this is a cache read most of
        // the time; the UI still catches every change within three seconds.
        running: w.live && !w.preview && w.booted && w.hovered && w.service !== ""
        onTriggered: {
            if (!feedProc.running && !w.feedBusy())
                w.loadFeed(true, false, true);
        }
    }

    Timer {
        interval: 60000
        repeat: true
        running: w.live && !w.preview
        onTriggered: {
            w.lastFeedRefresh = Date.now();
            // The feed refreshes in the background even while a post is open;
            // closing the thread should not reveal an hour-old page.
            w.loadFeed(true, false, true);
            if (w.detailOpen && w.detailPost !== null && w.detailPost.source === "discord") {
                w.lastThreadRefresh = Date.now();
                w.loadThread(w.detailId, w.threadLimit, true);
            }
        }
    }

    // The wheel animation is short, but the reader is still "scrolling" for
    // a moment after it ends. Hold refresh responses until then so a model
    // update cannot yank the viewport out from under the next notch.
    Timer {
        id: feedScrollQuiet

        interval: 700
        onTriggered: {
            if (feedScroll.moving || feedScroll.flicking || feedWheel.running) {
                restart();
                return ;
            }
            w.feedScrolling = false;
            if (w.pendingFeedText !== "") {
                w.applyPendingFeed();
                return ;
            }
            if (w.feedDirty) {
                var refresh = w.feedDirtyRefresh;
                w.feedDirty = false;
                w.feedDirtyRefresh = false;
                Qt.callLater(function () { w.loadFeed(refresh, false); });
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
            if (!w.discordEventRelevant(w.discordEventSlug, w.discordEventChannel))
                return ;
            if (now - w.lastFeedRefresh < w.discordFeedInterval) {
                // The event is real; do not drop it just because a refresh
                // finished a moment ago. Retry when the interval is over.
                discordDebounce.interval = Math.max(80, w.discordFeedInterval - (now - w.lastFeedRefresh));
                discordDebounce.restart();
                return ;
            }
            discordDebounce.interval = 220;
            // The main feed is kept current even while a thread is open.
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
            var payload = ({});
            try {
                payload = JSON.parse(text() || "{}") || ({});
            } catch (error) {
                payload = ({});
            }
            var list = Array.isArray(payload.events) ? payload.events : [payload];
            var maxAt = 0;
            for (var i = 0; i < list.length; i++) {
                var at = Number((list[i] || {}).at || 0);
                if (at > maxAt)
                    maxAt = at;
            }
            var stamp = String(maxAt) + "|" + String(list.length) + "|"
                + String(payload.message_id || "");
            if (!w.discordEventsReady) {
                w.discordEventsReady = true;
                w.discordEventStamp = stamp;
                w.discordLastEventAt = maxAt;
                return ;
            }
            // Polling reloads unchanged content; only a new gateway write may
            // wake the feed.
            if (stamp === w.discordEventStamp)
                return ;
            w.discordEventStamp = stamp;
            var previousAt = w.discordLastEventAt;
            if (maxAt > previousAt)
                w.discordLastEventAt = maxAt;
            // Pick the newest event that is both new and relevant to this
            // card. The feed refresh covers every new item in one pass.
            var chosen = null;
            for (var j = 0; j < list.length; j++) {
                var event = list[j] || ({});
                var when = Number(event.at || 0);
                if (when > 0 && when <= previousAt)
                    continue;
                if (!w.discordEventRelevant(event.slug || "", event.channel_id || ""))
                    continue;
                if (chosen === null || when >= Number(chosen.at || 0))
                    chosen = event;
            }
            if (chosen !== null)
                w.noteDiscordEvent(chosen.slug || "", chosen.channel_id || "");
        }
        onLoadFailed: w.discordEventsReady = true
    }

    Timer {
        interval: 1200
        repeat: true
        running: w.live && !w.preview
        // Atomic replaces can leave the inotify watch pointing at the old
        // inode. This cheap re-read is what makes a Discord message appear as
        // soon as the gateway signals it.
        onTriggered: discordEvents.reload()
    }

    FileView {
        id: discordTyping

        path: w.home + "/.cache/lucid-social/discord/typing.json"
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                w.typingState = JSON.parse(text() || "{}");
            } catch (error) {
                w.typingState = ({});
            }
        }
        onLoadFailed: w.typingState = ({})
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
            w.streamErrors = value.errors || [];
            w.pruneSelection();
            // Preload the channel picker in the background so the new-post
            // panel is instantly searchable when it opens.
            Qt.callLater(w.loadSendTargets);
            if ((value.errors || []).length > 0)
                w.actionError = value.errors[0].message || "a source could not be listed";

        } catch (error) {
            w.fatal = Tr.fmt("Could not read the source list from %1.", w.service);
        }
        // The saved stream selection is now available. Start the first feed
        // only here, not in boot(), so Discord selections are included in the
        // very first page instead of arriving on a later refresh.
        if (w.booted) {
            var firstFeed = w.items.length === 0;
            Qt.callLater(function () { w.loadFeed(true, firstFeed); });
        }
    }

    function pruneSelection() {
        var sourceIds = ({});
        var streamIds = ({});
        var completeSources = ({});
        var completeStreams = ({});
        var failed = ({});
        for (var e = 0; e < w.streamErrors.length; e++) {
            var errorSource = String((w.streamErrors[e] || {}).source || "");
            if (errorSource !== "")
                failed[errorSource] = true;
        }
        for (var i = 0; i < w.sources.length; i++) {
            var source = w.sources[i];
            var sourceId = String(source.id || "");
            sourceIds[sourceId] = true;
            var streams = source.streams || [];
            var complete = streams.length > 0
                && source.configured !== false
                && failed[sourceId] !== true;
            if (complete)
                completeSources[sourceId] = true;
            for (var j = 0; j < streams.length; j++) {
                streamIds[streams[j].id] = true;
                if (complete)
                    completeStreams[streams[j].id] = true;
            }
        }
        function keepSource(id) {
            return sourceIds[id] === true;
        }
        function keepStream(id) {
            var sourceId = String(id || "").split("/", 1)[0];
            var sourceComplete = completeSources[sourceId] === true;
            if (streamIds[id] === true)
                return !sourceComplete || completeStreams[id] === true;
            return sourceIds[sourceId] === true && !sourceComplete;
        }
        var offS = w.offSources.filter(keepSource);
        var offSt = w.offStreams.filter(keepStream);
        var onSt = w.onStreams.filter(keepStream);
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
        // A response for the old source selection must not leak into the new
        // one while a scroll is being held back.
        w.pendingFeedText = "";
        w.feedScrolling = false;
        w.feedReturnAnchor = null;
        w.feedScrollEpoch++;
        feedScrollQuiet.stop();
        w.phase = "loading";
    }

    function loadFeed(refresh, force, quiet) {
        if (w.preview || !w.live || w.service === "")
            return ;

        // A refresh that would move the model is not allowed while the reader
        // is scrolling. The quiet timer resumes it after the wheel/flick ends.
        if (refresh === true && force !== true && (w.feedBusy() || w.pendingFeedText !== "")) {
            w.feedDirty = true;
            w.feedDirtyRefresh = true;
            feedScrollQuiet.restart();
            return ;
        }

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
        w.refreshing = quiet !== true;
        if (quiet !== true)
            w.phase = w.items.length > 0 ? w.phase : "loading";
        feedProc.command = w.feedArgs(want, "", "", refresh, force);
        feedProc.running = true;
    }

    function loadMoreFeed() {
        if (w.preview || !w.live || w.service === "" || w.detailOpen)
            return ;
        // While a search is open its own cursor walks the list; do not mix in
        // an older feed page that the filter would hide anyway.
        if (w.searchQuery !== "")
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
            if (w.items[i] && w.feedTimeText(w.items[i]) !== "") {
                oldest = w.feedTimeText(w.items[i]);
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

    function filterProfile(list) {
        if (!w.profileOpen)
            return list;
        var id = String((w.profileAuthor || {}).id || "");
        var handle = String((w.profileAuthor || {}).handle || "").replace(/^@/, "").toLowerCase();
        var out = [];
        for (var i = 0; i < list.length; i++) {
            var author = (list[i] || {}).author || ({});
            if ((id !== "" && String(author.id || "") === id)
                || (handle !== "" && String(author.handle || "").toLowerCase().replace(/^@/, "") === handle))
                out.push(list[i]);
        }
        return out;
    }

    function profileColor(source) {
        switch (String(source || "")) {
        case "twitter": return "#1d9bf0";
        case "bluesky": return "#1185fe";
        case "hackernews": return "#ff6600";
        case "youtube": return "#ff0033";
        case "discord": return "#5865f2";
        case "nexusmods": return "#da8e35";
        }
        return Theme.primary;
    }

    function profileQueryFor(source, author, account, guild, channel) {
        var handle = String((author || {}).handle || "").replace(/^@/, "");
        var id = String((author || {}).id || "");
        if (source === "twitter")
            return handle !== "" ? "@" + handle : "";
        if (source === "hackernews")
            return handle !== "" ? "u/" + handle : "";
        if (source === "bluesky")
            return handle !== "" ? "bsky/" + handle : "";
        if (source === "youtube")
            return (id || handle) !== "" ? "yt/" + (id || handle) : "";
        if (source === "discord" && id !== "" && account !== "") {
            if (channel !== "")
                return "dchannel/" + account + "/" + id + "/" + channel;
            if (guild !== "")
                return "dguild/" + account + "/" + id + "/" + guild;
        }
        return "";
    }

    function profileCacheKeyFor(source, author, account, channel, guild) {
        var id = String((author || {}).id || (author || {}).handle || (author || {}).display_name || "");
        return [String(source || ""), id.toLowerCase(), String(account || ""), String(channel || ""), String(guild || "")].join("|");
    }

    function readProfileCache(key) {
        var cache = w.opt("socialProfileCache");
        if (typeof cache === "string" && cache !== "") {
            try {
                cache = JSON.parse(cache);
            } catch (error) {
                cache = ({});
            }
        }
        if (!cache || typeof cache !== "object")
            return null;
        return cache[key] || null;
    }

    function writeProfileCache(key, profile, tabs) {
        if (key === "" || !profile)
            return ;
        var cache = w.opt("socialProfileCache");
        if (typeof cache === "string" && cache !== "") {
            try {
                cache = JSON.parse(cache);
            } catch (error) {
                cache = ({});
            }
        }
        if (!cache || typeof cache !== "object")
            cache = ({});
        var next = {};
        var entries = [];
        for (var oldKey in cache) {
            var value = cache[oldKey];
            if (!value || oldKey === key)
                continue;
            entries.push({"key": oldKey, "value": value, "saved": Number(value.saved_at || 0)});
        }
        entries.sort((a, b) => b.saved - a.saved);
        for (var i = 0; i < entries.length && i < 24; i++)
            next[entries[i].key] = entries[i].value;
        next[key] = {
            "profile": profile,
            "tabs": tabs || [],
            "saved_at": Date.now()
        };
        w.setOpt("socialProfileCache", next);
    }

    function openProfile(author, source, context) {
        if (!author)
            return ;
        if (w.detailOpen)
            w.closeDetail();
        w.pickerOpen = false;
        w.newPostOpen = false;
        w.profileAuthor = author;
        w.profileSource = String(source || "");
        var ref = (context || {}).ref || (w.detailPost || {}).ref || ({});
        w.profileAccount = String(ref.account || "");
        w.profileChannel = String(ref.channel_id || "");
        w.profileGuild = String(ref.guild_id || "");
        w.profileUserId = String(author.id || ref.user_id || "");
        w.profileMeta = {
            "source": w.profileSource,
            "handle": String(author.handle || "").replace(/^@/, ""),
            "display_name": author.display_name || author.handle || "",
            "bio": "",
            "banner_url": "",
            "avatar_url": author.avatar_url || "",
            "accent_color": w.profileColor(w.profileSource),
            "counts": {},
            "can_follow": false,
            "can_message": w.profileSource === "discord" || w.profileSource === "twitter" || w.profileSource === "bluesky",
            "tabs": []
        };
        w.profileFollowing = false;
        w.profileHeaderHeight = 0;
        w.profileError = "";
        w.profileTab = "";
        w.profileFilter = "";
        var query = w.profileQueryFor(w.profileSource, author, w.profileAccount, w.profileGuild, w.profileChannel);
        w.profileTabs = query !== "" ? [{"id": "posts", "title": Tr.t("Posts"), "filter": "", "query": query}] : [];
        w.profileTab = "posts";
        w.profileQuery = query;
        w.profileCacheKey = w.profileCacheKeyFor(w.profileSource, author, w.profileAccount, w.profileChannel, w.profileGuild);
        var cached = w.readProfileCache(w.profileCacheKey);
        if (cached && cached.profile) {
            // Show the previous header immediately. The service request below
            // still runs so an updated bio/banner/counts replaces it.
            w.profileMeta = cached.profile;
            w.profileFollowing = cached.profile.following === true;
            if (Array.isArray(cached.tabs) && cached.tabs.length > 0) {
                w.profileTabs = cached.tabs.slice();
                var cachedTab = w.profileTabs[0];
                for (var ct = 0; ct < w.profileTabs.length; ct++) {
                    if (String(w.profileTabs[ct].id) === w.profileTab) {
                        cachedTab = w.profileTabs[ct];
                        break;
                    }
                }
                w.profileTab = String(cachedTab.id || w.profileTab);
                w.profileFilter = String(cachedTab.filter || "");
                if (String(cachedTab.query || "") !== "")
                    w.profileQuery = String(cachedTab.query);
            }
            if (cached.profile.display_name)
                w.profileAuthor = Object.assign({}, w.profileAuthor || {}, {
                    "display_name": cached.profile.display_name,
                    "handle": String(cached.profile.handle || (w.profileAuthor || {}).handle || ""),
                    "avatar_url": String(cached.profile.avatar_url || (w.profileAuthor || {}).avatar_url || "")
                });
        }
        w.searchQuery = w.profileQuery;
        w.loadProfileMeta();
        // The profile prepends a header row to this same list. Any anchor
        // captured for the previous model is meaningless now.
        w.feedScrollEpoch++;
        w.feedReturnAnchor = null;
        feedWheel.stop();
        feedScroll.contentY = 0;
        Qt.callLater(function () { feedScroll.positionViewAtBeginning(); });
    }

    function loadProfileMeta() {
        if (!w.profileOpen || w.service === "")
            return ;
        w.profileBusy = true;
        var args = [w.service, "profile", "--json", "--source", w.profileSource,
            "--handle", String((w.profileAuthor || {}).handle || "").replace(/^@/, ""),
            "--user-id", w.profileUserId,
            "--account", w.profileAccount,
            "--guild", w.profileGuild,
            "--channel", w.profileChannel,
            "--display-name", String((w.profileAuthor || {}).display_name || "")];
        profileProc.command = args;
        profileProc.running = true;
    }

    function consumeProfile(text) {
        w.profileBusy = false;
        try {
            var value = JSON.parse(text);
            var profile = value.profile || ({});
            w.profileMeta = profile;
            w.profileFollowing = profile.following === true;
            w.profileTabs = (profile.tabs || []).slice();
            w.profileError = (value.errors || []).length > 0 ? Tr.t(value.errors[0].message || "") : "";
            if (w.profileTabs.length > 0) {
                var found = null;
                for (var i = 0; i < w.profileTabs.length; i++) {
                    if (String(w.profileTabs[i].id) === w.profileTab) {
                        found = w.profileTabs[i];
                        break;
                    }
                }
                if (!found)
                    found = w.profileTabs[0];
                w.profileTab = String(found.id);
                w.profileFilter = String(found.filter || "");
                if (String(found.query || "") !== "" && String(found.query) !== w.profileQuery) {
                    w.profileQuery = String(found.query);
                    w.searchQuery = w.profileQuery;
                }
            }
            if (profile.display_name)
                w.profileAuthor = Object.assign({}, w.profileAuthor || {}, {
                    "display_name": profile.display_name,
                    "handle": String(profile.handle || (w.profileAuthor || {}).handle || ""),
                    "avatar_url": String(profile.avatar_url || (w.profileAuthor || {}).avatar_url || "")
                });
            w.writeProfileCache(w.profileCacheKey, profile, w.profileTabs);
        } catch (error) {
            w.profileError = Tr.t("Could not load this profile.");
        }
    }

    function selectProfileTab(id) {
        var tab = null;
        for (var i = 0; i < w.profileTabs.length; i++) {
            if (String(w.profileTabs[i].id) === String(id)) {
                tab = w.profileTabs[i];
                break;
            }
        }
        if (!tab)
            return ;
        w.profileTab = String(tab.id);
        w.profileFilter = String(tab.filter || "");
        var query = String(tab.query || w.profileQuery);
        feedScroll.contentY = 0;
        if (query !== w.profileQuery) {
            w.profileQuery = query;
            w.searchQuery = query;
        } else {
            w.clearSearch();
            searchDebounce.restart();
        }
    }

    function toggleProfileFollow() {
        if (w.profileFollowBusy || !w.profileOpen)
            return ;
        if (!(w.profileMeta || {}).can_follow)
            return ;
        w.profileFollowBusy = true;
        var handle = String((w.profileMeta || {}).handle || (w.profileAuthor || {}).handle || "").replace(/^@/, "");
        followProc.command = [w.service, "follow", "--json", "--source", w.profileSource,
            "--handle", handle, w.profileFollowing ? "--off" : "--on"];
        followProc.running = true;
    }

    function consumeFollow(text) {
        w.profileFollowBusy = false;
        try {
            var value = JSON.parse(text);
            if (value.ok !== true) {
                w.profileError = Tr.t(value.error || "Could not update the follow state.");
                return ;
            }
            w.profileFollowing = value.following === true;
            var meta = Object.assign({}, w.profileMeta || {});
            meta.following = w.profileFollowing;
            meta.follow_label = w.profileFollowing ? Tr.t("Following") : Tr.t("Follow");
            w.profileMeta = meta;
        } catch (error) {
            w.profileError = Tr.t("The follow service returned an unexpected payload.");
        }
    }

    function startProfileMessage() {
        if (!w.profileOpen)
            return ;
        if (w.profileSource === "discord" && (w.profileChannel !== "" || w.profileGuild !== "")) {
            w.pendingProfileTarget = true;
            if (!w.newPostOpen)
                w.toggleNewPost();
            w.selectProfileSendTarget();
            return ;
        }
        if (w.profileSource === "twitter") {
            var id = String(w.profileUserId || (w.profileAuthor || {}).id || "");
            var handle = String((w.profileAuthor || {}).handle || "").replace(/^@/, "");
            w.openUrl(/^\d+$/.test(id) ? "https://x.com/messages/compose?recipient_id=" + id
                : "https://x.com/" + handle, null, {});
            return ;
        }
        if (w.profileSource === "bluesky")
            w.openUrl("https://bsky.app/messages", null, {});
    }

    function selectProfileSendTarget() {
        if (!w.pendingProfileTarget || !w.newPostOpen)
            return ;
        for (var i = 0; i < w.sendTargets.length; i++) {
            var target = w.sendTargets[i];
            if (w.profileChannel !== "" && String(target.channel_id || "") !== w.profileChannel)
                continue;
            if (w.profileChannel === "" && w.profileGuild !== "" && String(target.guild_id || "") !== w.profileGuild)
                continue;
            if (w.profileAccount !== "" && String(target.account || "") !== w.profileAccount)
                continue;
            w.resetSendSelection([target]);
            w.sendCursorKey = w.sendTargetKey(target);
            w.pendingProfileTarget = false;
            return ;
        }
        if (!w.sendTargetsLoading)
            w.pendingProfileTarget = false;
    }

    function compactCount(value) {
        var number = Number(value);
        if (!isFinite(number) || value === null || value === undefined)
            return "";
        if (number >= 1000000000)
            return (number / 1000000000).toFixed(number >= 10000000000 ? 0 : 1) + "B";
        if (number >= 1000000)
            return (number / 1000000).toFixed(number >= 10000000 ? 0 : 1) + "M";
        if (number >= 1000)
            return (number / 1000).toFixed(number >= 10000 ? 0 : 1) + "K";
        return String(number);
    }

    function closeProfile() {
        var wasProfileSearch = w.profileQuery !== "" && w.searchQuery === w.profileQuery;
        w.profileAuthor = null;
        w.profileMeta = ({});
        w.profileTabs = [];
        w.profileSource = "";
        w.profileQuery = "";
        w.profileCacheKey = "";
        w.profileTab = "";
        w.profileFilter = "";
        w.profileAccount = "";
        w.profileChannel = "";
        w.profileGuild = "";
        w.profileUserId = "";
        w.profileError = "";
        w.profileFollowing = false;
        w.profileHeaderHeight = 0;
        w.pendingProfileTarget = false;
        if (wasProfileSearch)
            w.searchQuery = "";
        // Removing the header row changes every delegate's y. Invalidate any
        // pending anchor restore from the profile model and land on the first
        // post once the list has rebuilt without the header.
        w.feedScrollEpoch++;
        w.feedReturnAnchor = null;
        feedWheel.stop();
        feedScroll.contentY = 0;
        Qt.callLater(function () { feedScroll.positionViewAtBeginning(); });
    }

    function clearSearch() {
        w.searchResults = [];
        w.searchChannels = [];
        w.searchScopeStreams = [];
        w.searchResultQuery = "";
        w.searchServed = false;
        w.searchHasMore = false;
        w.searchMoreLoading = false;
        w.searchMorePending = false;
        w.searchAppend = false;
        w.searchPrefetching = false;
        w.searchMode = "";
        w.searchNextBefore = "";
        w.searchNextBeforeId = "";
    }

    function searchArgs(limit, before, beforeId, mode) {
        var args = [w.service, "search", "--json", "--query", w.searchQuery.trim(), "--limit", String(limit)];
        if (before !== "") {
            args.push("--before", before);
            if (beforeId !== "")
                args.push("--before-id", beforeId);
            if (mode !== "")
                args.push("--mode", mode);
        }
        for (var i = 0; i < w.offSources.length; i++)
            args.push("--exclude-source", w.offSources[i]);
        for (var j = 0; j < w.offStreams.length; j++)
            args.push("--exclude-stream", w.offStreams[j]);
        for (var k = 0; k < w.onStreams.length; k++)
            args.push("--include-stream", w.onStreams[k]);
        if (w.profileOpen && w.profileFilter !== "")
            args.push("--profile-filter", w.profileFilter);
        return args;
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
        w.searchAppend = false;
        w.searchMoreLoading = false;
        searchProc.command = w.searchArgs(w.searchPageLimit, "", "", "");
        searchProc.running = true;
    }

    // Scroll to the bottom of a search result list and the next page walks
    // further back through the matched channel, or through the index.
    function loadMoreSearch() {
        if (w.preview || !w.live || w.service === "" || w.detailOpen)
            return ;
        if (w.searchQuery.trim() === "" || !w.searchHasMore || w.searchMoreLoading)
            return ;
        if (searchProc.running) {
            w.searchMorePending = true;
            return ;
        }
        if (w.searchNextBefore === "")
            return ;
        w.searchMoreLoading = true;
        w.searchPrefetching = false;
        w.searchAppend = true;
        searchProc.command = w.searchArgs(w.searchPageLimit, w.searchNextBefore, w.searchNextBeforeId, w.searchMode);
        searchProc.running = true;
    }

    function searchBufferBelow() {
        return feedScroll.contentHeight - (feedScroll.contentY + feedScroll.height);
    }

    // Keep a couple of screens buffered. The X profile scrape takes several
    // seconds, so fetching only when the reader hits the bottom still feels
    // delayed; fetch while the buffer is short instead.
    function maybePrefetchSearch() {
        if (w.preview || !w.live || w.detailOpen)
            return ;
        if (w.searchQuery === "" || !w.searchHasMore || w.searchMoreLoading)
            return ;
        if (searchProc.running || w.searchNextBefore === "")
            return ;
        if (w.searchBufferBelow() > Theme.dp(2400))
            return ;
        w.prefetchSearch();
    }

    function prefetchSearch() {
        if (w.preview || !w.live || w.service === "" || w.detailOpen)
            return ;
        if (w.searchQuery.trim() === "" || !w.searchHasMore || w.searchMoreLoading || w.searchPrefetching)
            return ;
        if (searchProc.running || w.searchNextBefore === "")
            return ;
        w.searchMoreLoading = true;
        w.searchPrefetching = true;
        w.searchAppend = true;
        searchProc.command = w.searchArgs(w.searchPageLimit, w.searchNextBefore, w.searchNextBeforeId, w.searchMode);
        searchProc.running = true;
    }

    function consumeSearch(text) {
        w.searchLoading = false;
        w.searchMoreLoading = false;
        var appending = w.searchAppend;
        w.searchAppend = false;
        w.searchPrefetching = false;
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
            var incoming = value.items || [];
            if (appending && w.searchResultQuery === String(value.query || w.searchQuery.trim())) {
                var seen = ({});
                var merged = [];
                for (var m = 0; m < w.searchResults.length; m++) {
                    var prior = w.searchResults[m];
                    if (prior && prior.id && seen[prior.id] !== true) {
                        seen[prior.id] = true;
                        merged.push(prior);
                    }
                }
                for (var q = 0; q < incoming.length; q++) {
                    var hit = incoming[q];
                    if (hit && hit.id && seen[hit.id] !== true) {
                        seen[hit.id] = true;
                        merged.push(hit);
                    }
                }
                w.searchResults = merged;
                // If the cursor did not move the next page would be this same
                // page again; stop even if the source still claims more.
                var nextBefore = String(value.next_before || "");
                var nextId = String(value.next_before_id || "");
                var advanced = nextBefore !== "" && (nextBefore !== w.searchNextBefore || nextId !== w.searchNextBeforeId);
                w.searchHasMore = value.has_more === true && advanced;
            } else {
                // A late/empty profile page must not wipe cards already shown.
                // Profile pages can be slow and can return an empty cursor page
                // while the source catches up.
                var keepProfileRows = w.profileOpen && incoming.length === 0
                    && w.searchResults.length > 0
                    && w.searchResultQuery === String(value.query || w.searchQuery.trim());
                w.searchChannels = channels;
                w.searchScopeStreams = scope;
                if (!keepProfileRows)
                    w.searchResults = incoming;
                w.searchHasMore = value.has_more === true;
            }
            w.searchMode = String(value.mode || w.searchMode || "");
            w.searchNextBefore = String(value.next_before || "");
            w.searchNextBeforeId = String(value.next_before_id || "");
            w.searchResultQuery = String(value.query || w.searchQuery.trim());
            w.searchServed = true;
            // Fill the buffer below the viewport, but never chain pages while
            // the reader is still far from the end of the list.
            if (w.searchHasMore)
                Qt.callLater(w.maybePrefetchSearch);
        } catch (error) {
            w.searchServed = false;
        }
    }

    function feedBusy() {
        return w.feedScrolling || feedScroll.moving || feedScroll.flicking || feedWheel.running;
    }

    function markFeedScrolling() {
        w.feedScrolling = true;
        feedScrollQuiet.restart();
    }

    function maybeLoadMoreFeed() {
        if (w.searchQuery !== "") {
            // Searching is still a list the reader scrolls; keep walking the
            // matched channel or the index instead of stopping at page one.
            if (!w.searchHasMore || w.searchMoreLoading || searchProc.running)
                return ;
            if (feedScroll.contentHeight <= feedScroll.height + Theme.dp(4)) {
                w.loadMoreSearch();
                return ;
            }
            // X takes several seconds to scrape, so start while the reader is
            // still a couple of screens away rather than at the last pixel.
            if (w.searchBufferBelow() > Theme.dp(2400))
                return ;
            w.loadMoreSearch();
            return ;
        }
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
        return {
            "id": best.modelData.id,
            "offset": feedScroll.contentY - best.y,
            // Remember the old y so a restore shifts by the height inserted
            // above the anchor instead of forcing an absolute position from a
            // delegate whose layout may not have settled yet.
            "y": best.y
        };
    }

    // Restore the reading position once, after the model has settled. We do
    // not force a view position: if the delegate is not instantiated yet, the
    // list keeps its current paint position and the next refresh will pick it
    // up. This avoids the old behaviour where a late restore could drag the
    // viewport back down after the reader had already scrolled up.
    function restoreFeedAnchor(anchor) {
        if (!anchor || !anchor.id || w.detailOpen || w.profileOpen || w.feedBusy())
            return;
        var epoch = w.feedScrollEpoch;
        var index = -1;
        // Index into the exact model the list is showing. Using shownItems
        // while the profile header row is prepended selected the wrong
        // delegate and shifted the feed by the header's height.
        for (var i = 0; i < w.feedValues.length; i++) {
            if (w.feedValues[i] && w.feedValues[i].id === anchor.id) {
                index = i;
                break;
            }
        }
        if (index < 0 || index >= feedScroll.count)
            return;
        var offset = anchor.offset;
        var attempt = 0;
        function apply() {
            if (w.feedBusy() || w.feedScrollEpoch !== epoch || w.profileOpen)
                return;
            var item = feedScroll.itemAtIndex(index);
            if (item === null) {
                if (attempt < 6) {
                    attempt++;
                    Qt.callLater(apply);
                }
                return;
            }
            // Shift by the difference, never jump to an absolute position.
            // A stale absolute y (delegate laid out before the insertion) was
            // what pinned the feed down and made scrolling back up impossible.
            var delta = item.y - Number(anchor.y || 0);
            if (Math.abs(delta) >= 0.5) {
                var limit = Math.max(0, feedScroll.contentHeight - feedScroll.height);
                feedScroll.contentY = Math.max(0, Math.min(limit, feedScroll.contentY + delta));
            }
        }
        Qt.callLater(apply);
    }

    function consumeFeed(text) {
        var append = w.feedAppend;
        if (!append && w.feedBusy()) {
            // Keep the newest response and apply it after the scroll settles.
            w.pendingFeedText = text;
            w.feedAppend = false;
            w.feedLoadingMore = false;
            w.refreshing = false;
            w.lastFeedRefresh = Date.now();
            feedScrollQuiet.restart();
            return;
        }
        w.applyFeed(text, append);
    }

    function applyPendingFeed() {
        if (w.pendingFeedText === "" || w.feedBusy()) {
            if (w.pendingFeedText !== "")
                feedScrollQuiet.restart();
            return;
        }
        var text = w.pendingFeedText;
        w.pendingFeedText = "";
        w.applyFeed(text, false);
        if (w.feedDirty) {
            var refresh = w.feedDirtyRefresh;
            w.feedDirty = false;
            w.feedDirtyRefresh = false;
            Qt.callLater(function () { w.loadFeed(refresh, false); });
        }
    }

    function applyFeed(text, append) {
        w.refreshing = false;
        w.lastFeedRefresh = Date.now();
        w.feedAppend = false;
        w.feedLoadingMore = false;
        var anchor = (append || w.detailOpen || w.profileOpen || w.feedReturnAnchor !== null)
            ? null
            : w.captureFeedAnchor();
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
                var when = w.feedTime(b) - w.feedTime(a);
                if (when !== 0)
                    return when;
                var aid = String(a.id), bid = String(b.id);
                return bid < aid ? -1 : (bid > aid ? 1 : 0);
            });
            if (next.length > 3000)
                next = next.slice(0, 3000);
            var samePosts = next.length === w.items.length;
            if (samePosts) {
                for (var sp = 0; sp < next.length; sp++) {
                    if (next[sp] !== w.items[sp]) {
                        samePosts = false;
                        break;
                    }
                }
            }
            if (!samePosts)
                w.items = next;
            else
                // Nothing moved, so there is no anchor to restore. Touching
                // contentY on an unchanged model is what made a silent
                // refresh fight the reader.
                anchor = null;
            w.currentUserAuthor();
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
            if (!append)
                Qt.callLater(function () { w.maybeLoadMoreFeed(); });
        } catch (error) {
            if (append)
                w.feedAtEnd = true;
            w.phase = w.items.length > 0 ? "ready" : "failed";
            w.fatal = Tr.t("lucid-social returned an unexpected payload.");
        }
    }

    function syncDetail() {
        for (var i = 0; i < w.items.length; i++) {
            if (w.items[i].id === w.detailId) {
                w.detailPost = w.items[i];
                return ;
            }
        }
        // A background feed page may no longer contain an old thread's root.
        // Keep the thread's own copy rather than blanking the open view.
        if (w.detailOpen)
            return ;
        w.detailPost = null;
    }

    // Older feed/thread caches can contain one row per Discord message.
    // Group them before the first commentView layout so a thread never opens
    // flat and then rearranges itself after a refresh.
    function groupComments(values) {
        var source = values || [];
        var out = [];
        var window = 7200000;

        function messageIds(value) {
            var ref = value.ref || ({});
            var ids = (ref.message_ids || []).slice();
            if (ids.length === 0 && ref.message_id)
                ids = [String(ref.message_id)];
            return ids;
        }
        function segments(value) {
            var list = value.body_segments || [];
            var ref = value.ref || ({});
            if (Array.isArray(ref.segment_ids) && list.length > 0) {
                // Media-only slots are empty strings. They must stay so the
                // segment id/media arrays remain aligned and the thread can
                // place each attachment between its surrounding messages.
                return list.map(function (item) { return String(item || ""); });
            }
            var clean = [];
            for (var i = 0; i < list.length; i++) {
                if (String(list[i] || "").trim() !== "")
                    clean.push(String(list[i]));
            }
            if (clean.length > 0)
                return clean;
            var body = String(value.body || "");
            return body.trim() !== "" ? [body] : [];
        }

        for (var i = 0; i < source.length; i++) {
            var raw = source[i];
            if (!raw)
                continue;
            var value = Object.assign({}, raw);
            var valueRef = Object.assign({}, raw.ref || ({}));
            valueRef.message_ids = messageIds(raw);
            value.ref = valueRef;
            value.body_segments = segments(raw);
            value.media = (raw.media || []).slice();
            var last = out.length > 0 ? out[out.length - 1] : null;
            var lastRef = last !== null ? (last.ref || ({})) : ({});
            var lastAuthor = last !== null ? (last.author || ({})) : ({});
            var valueAuthor = value.author || ({});
            var lastKey = String(lastAuthor.id || lastAuthor.handle || lastAuthor.display_name || "");
            var valueKey = String(valueAuthor.id || valueAuthor.handle || valueAuthor.display_name || "");
            var started = last !== null ? Date.parse(last.created_at) : NaN;
            var when = Date.parse(value.created_at);
            // A newly sent comment has to join the latest author group even
            // though that group was already folded by the service. Only an
            // incoming grouped row is held back, so two existing groups are
            // never merged by this second pass.
            var canGroup = last !== null
                && value.grouped !== true
                && last.pending !== true && value.pending !== true
                && String(last.parent_id || "") === String(value.parent_id || "")
                && lastKey !== "" && lastKey === valueKey
                && isFinite(started) && isFinite(when)
                && when - started <= window;
            if (!canGroup) {
                out.push(value);
                continue;
            }
            var lastBody = String(last.body || "");
            var valueBody = String(value.body || "");
            if (valueBody)
                last.body = lastBody + (lastBody ? "\n" : "") + valueBody;
            last.body_segments = segments(last).concat(value.body_segments);
            last.media = (last.media || []).concat(value.media || []);
            var ids = messageIds(last);
            for (var idIndex = 0; idIndex < valueRef.message_ids.length; idIndex++) {
                var messageId = String(valueRef.message_ids[idIndex] || "");
                if (messageId !== "" && ids.indexOf(messageId) < 0)
                    ids.push(messageId);
            }
            last.ref = Object.assign({}, lastRef, {
                "message_id": lastRef.message_id || (ids.length > 0 ? ids[0] : ""),
                "message_ids": ids
            });
            // Keep the newest local sequence on the folded group so the send
            // that just happened can still find its row.
            if (value._localSeq !== undefined)
                last._localSeq = value._localSeq;
            last.grouped = true;
        }
        return w.dropCoveredComments(out);
    }

    // Discord author groups are convenient in the feed, but reactions, media
    // and the emoji button belong to individual messages. Expand a grouped
    // comment into one row per message for the thread view.
    function expandDiscordMessages(values) {
        if (!w.detailPost || w.detailPost.source !== "discord")
            return values;
        var out = [];
        for (var i = 0; i < values.length; i++) {
            var comment = values[i];
            var ref = comment.ref || ({});
            var ids = ref.segment_ids;
            var texts = comment.body_segments || [];
            if (!Array.isArray(ids) || ids.length < 2 || ids.length !== texts.length) {
                out.push(comment);
                continue;
            }
            // Keep a normal Discord author group as one block. Only break it
            // into individual messages when a message actually carries its
            // own reactions (or the segment row would hide them).
            var segmentReactions = ref.segment_reactions || [];
            var hasReactions = false;
            for (var ri = 0; ri < segmentReactions.length; ri++) {
                var group = segmentReactions[ri] || [];
                for (var rj = 0; rj < group.length; rj++) {
                    if (Number(group[rj].count || 0) > 0) {
                        hasReactions = true;
                        break;
                    }
                }
                if (hasReactions)
                    break;
            }
            if (!hasReactions) {
                out.push(comment);
                continue;
            }
            var channel = String(ref.channel_id || (String(comment.id || "").split("/")[1] || ""));
            var order = [];
            var rows = ({});
            for (var s = 0; s < ids.length; s++) {
                var mid = String(ids[s] || "");
                if (mid === "")
                    continue;
                var row = rows[mid];
                if (row === undefined) {
                    row = Object.assign({}, comment);
                    row.id = channel !== "" ? "discord/" + channel + "/" + mid : comment.id + "#" + s;
                    row.body = "";
                    row.body_segments = [];
                    row.media = [];
                    row.reactions = [];
                    row.created_at = (ref.segment_times && ref.segment_times[s]) || comment.created_at;
                    row.ref = Object.assign({}, ref, {
                        "message_id": mid,
                        "message_ids": [mid],
                        "reaction_users": ({}),
                        // Keep the author grouping visible even though each
                        // message owns its own row and reactions.
                        "_group_index": order.length,
                        "segment_ids": undefined,
                        "segment_times": undefined,
                        "segment_media": undefined,
                        "segment_reactions": undefined,
                        "segment_reaction_users": undefined
                    });
                    row.comment_count = 0;
                    rows[mid] = row;
                    order.push(mid);
                }
                var text = String(texts[s] || "");
                if (text !== "") {
                    row.body = row.body === "" ? text : row.body + "\n" + text;
                    row.body_segments = row.body_segments.concat([text]);
                }
                var media = (ref.segment_media || [])[s];
                if (Array.isArray(media) && media.length > 0)
                    row.media = row.media.concat(media);
                var reactions = (ref.segment_reactions || [])[s];
                if (Array.isArray(reactions) && reactions.length > 0)
                    row.reactions = row.reactions.concat(reactions);
                var reactionUsers = (ref.segment_reaction_users || [])[s];
                if (reactionUsers && typeof reactionUsers === "object") {
                    var mergedUsers = Object.assign({}, row.ref.reaction_users || {});
                    for (var uk in reactionUsers)
                        mergedUsers[uk] = reactionUsers[uk];
                    row.ref.reaction_users = mergedUsers;
                }
            }
            for (var o = 0; o < order.length; o++)
                out.push(rows[order[o]]);
        }
        return out;
    }

    // Turn the flat, parent-linked comment list into a Bluesky/Twitter-style
    // timeline. Replies do not indent; each branch shows its first two
    // messages and then a text "Show N more replies" affordance.
    function buildCommentView(source) {
        source = w.expandDiscordMessages(source);
        if (w.detailPost !== null && w.detailPost.source === "discord") {
            // The expansion carries an explicit index, but preview rows and
            // older caches may not. Derive the same author-run grouping here
            // so a rebuild never shows every burst message as standalone.
            var previousAuthor = "";
            var previousTime = NaN;
            var groupIndex = 0;
            for (var gi = 0; gi < source.length; gi++) {
                var entry = source[gi];
                if (!entry)
                    continue;
                var who = String(((entry.author || {}).id || (entry.author || {}).handle || ""));
                var when = Date.parse(entry.created_at);
                if (who !== "" && who === previousAuthor && isFinite(when) && isFinite(previousTime) && when - previousTime <= 7200000)
                    groupIndex++;
                else
                    groupIndex = 0;
                if ((entry.ref || {})._group_index === undefined)
                    entry._group_index = groupIndex;
                previousAuthor = who;
                previousTime = when;
            }
        }
        if (w.threadSearchQuery.trim() !== "")
            source = source.filter((row) => w.threadMatches(row));
        var byId = {};
        var children = {};
        var i;
        for (i = 0; i < source.length; i++) {
            var item = source[i];
            byId[item.id] = item;
        }
        // Discord is a flat channel conversation. A message that references
        // another comment is still shown in the same timeline, not hidden in
        // a nested "Show N replies" branch. Reply trees remain for sources
        // that actually model them (Bluesky, HN, ...).
        var flat = w.detailPost !== null && w.detailPost.source === "discord";
        for (i = 0; i < source.length; i++) {
            var value = source[i];
            var parent = !flat && value.parent_id && byId[value.parent_id] ? value.parent_id : "";
            if (!children[parent])
                children[parent] = [];
            children[parent].push(value);
        }
        for (var key in children) {
            // Local sends are stamped in the order Enter was pressed. The
            // sequence tie-break keeps them ordered even when two rows land in
            // the same millisecond (or a refresh keeps their local time).
            children[key].sort((a, b) => {
                var at = Date.parse(a.created_at);
                var bt = Date.parse(b.created_at);
                if (isFinite(at) && isFinite(bt) && at !== bt)
                    return at - bt;
                // Cached timestamps are second precision, so equal values are
                // common. Snowflakes are monotonic and break the tie exactly.
                var aid = w.firstMessageId(a);
                var bid = w.firstMessageId(b);
                if (aid !== "" && bid !== "" && aid !== bid)
                    return aid < bid ? -1 : 1;
                return (a._localSeq || 0) - (b._localSeq || 0);
            });
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

    function captureThreadAnchor() {
        if (!w.detailOpen || w.comments.length === 0 || w.threadBottomFollow || w.threadAutoScrolling)
            return null;
        var view = w.commentView || [];
        for (var i = 0; i < view.length; i++) {
            var entry = view[i];
            if (!entry || entry.kind !== "comment" || !entry.comment)
                continue;
            var slot = commentRepeater.itemAt(i);
            if (slot === null || slot.y + slot.height <= detailScroll.contentY)
                continue;
            return {"id": String(entry.comment.id), "y": slot.y, "offset": detailScroll.contentY - slot.y};
        }
        return null;
    }

    function restoreThreadAnchor(anchor, attempt) {
        if (!anchor || !w.detailOpen || anchor.id === "")
            return ;
        attempt = Number(attempt || 0);
        var view = w.commentView || [];
        for (var i = 0; i < view.length; i++) {
            var entry = view[i];
            if (!entry || entry.kind !== "comment" || !entry.comment)
                continue;
            if (String(entry.comment.id) !== anchor.id)
                continue;
            var slot = commentRepeater.itemAt(i);
            if (slot === null) {
                if (attempt < 8)
                    Qt.callLater(function () { w.restoreThreadAnchor(anchor, attempt + 1); });
                return ;
            }
            var delta = slot.y - Number(anchor.y || 0);
            if (Math.abs(delta) >= 0.5) {
                var limit = Math.max(0, detailScroll.contentHeight - detailScroll.height);
                detailScroll.contentY = Math.max(0, Math.min(limit, detailScroll.contentY + delta));
            }
            return ;
        }
    }

    function scrollThreadToComment(id, attempt, fallback, bottom, settle) {
        if (!w.detailOpen || id === "")
            return ;
        attempt = Number(attempt || 0);
        // Own the viewport before anything moves. If the bottom-follow or a
        // pending refresh stays armed, appending the row re-anchors to the
        // bottom before the retry can find the comment.
        w.threadBottomFollow = false;
        w.threadAutoScrolling = false;
        w.threadUserScrolled = true;
        w.threadReloadOffset = -1;
        w.threadReloadUntil = 0;
        detailWheel.stop();
        // A locally sent row can be folded into the latest same-author group.
        // The group keeps the sequence number, so the row is still findable
        // even though its id is not the pending one.
        var localSeq = String(id).indexOf("pending/") === 0 ? String(id).split("/").pop() : "";
        var view = w.commentView || [];
        for (var i = 0; i < view.length; i++) {
            var entry = view[i];
            if (!entry || entry.kind !== "comment" || !entry.comment)
                continue;
            var comment = entry.comment;
            var ref = comment.ref || ({});
            var ids = ref.message_ids || [];
            var match = String(comment.id) === String(id)
                || ids.indexOf(String(id).split("/").pop()) >= 0
                || String(id).indexOf(String(comment.id)) === 0
                || (localSeq !== "" && String(comment._localSeq || "") === localSeq);
            if (!match)
                continue;
            var slot = commentRepeater.itemAt(i);
            if (slot === null || slot.height <= 0) {
                if (attempt < 20)
                    Qt.callLater(function () { w.scrollThreadToComment(id, attempt + 1, fallback, bottom, settle); });
                return ;
            }
            var point = slot.mapToItem(detailColumn, 0, 0);
            var limit = Math.max(0, detailScroll.contentHeight - detailScroll.height);
            var target = point.y - Theme.dp(18);
            if (bottom === true) {
                // The new message is the tail of its group. If the group is
                // taller than the viewport, align its end; otherwise the top
                // already shows the whole block.
                var room = detailScroll.height - Theme.dp(36);
                if (slot.height > room)
                    target = point.y + slot.height - detailScroll.height + Theme.dp(18);
            }
            target = Math.max(0, Math.min(limit, target));
            detailScroll.contentY = target;
            if (settle !== true) {
                w.threadScrollTarget = {"id": id, "fallback": fallback, "bottom": bottom};
                threadScrollSettle.restart();
            }
            return ;
        }
        if (attempt < 20) {
            Qt.callLater(function () { w.scrollThreadToComment(id, attempt + 1, fallback, bottom, settle); });
        } else if (fallback && String(fallback) !== String(id) && settle !== true) {
            // The row itself is not on screen (for example, a source folded it
            // into an existing group). Land on the comment we replied to.
            Qt.callLater(function () { w.scrollThreadToComment(fallback, 0, "", false); });
        }
    }

    function expandBranch(id) {
        // Expanding replies inserts content in place. Keep the current paint
        // position instead of re-anchoring to the bottom while the new rows
        // are laid out.
        w.threadHoldPosition = true;
        threadHoldRelease.restart();
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
        // Discord returns the whole grouped chain in one response, regardless
        // of the requested limit. Asking again only replaced the visible rows
        // a second later with the same data.
        if (w.detailPost !== null && w.detailPost.source === "discord")
            return false;
        if (w.threadLimit >= 60)
            return false;

        var total = w.detailPost && w.detailPost.comment_count !== null && w.detailPost.comment_count !== undefined ? Number(w.detailPost.comment_count) : -1;
        var shown = w.detailPost && w.detailPost.source === "discord" ? w.commentsMessageCount(w.comments) : w.comments.length;
        if (total >= 0)
            return shown < total;

        return w.comments.length >= w.threadLimit;
    }

    function loadMoreComments() {
        if (w.commentsLoading || !w.canLoadMoreComments())
            return;

        w.threadLimit = Math.min(60, w.threadLimit + 20);
        w.loadThread(w.detailId, w.threadLimit);
    }

    function loadThread(id, limit, refresh) {
        if (w.detailOpen && w.comments.length > 0 && !w.threadOpening) {
            w.threadAnchor = null;
            w.threadReloadOffset = Math.max(0, detailScroll.contentHeight - detailScroll.height - detailScroll.contentY);
            w.threadReloadUntil = Date.now() + 2000;
        }
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
        if (!w.live || w.preview)
            return ;
        // events.json keeps a short list and the feed throttle can keep restarting
        // the debounce. Start the open thread's refresh here so a newer event
        // cannot strand it until the minute timer.
        if (w.detailOpen && w.detailPost !== null && w.detailPost.source === "discord"
            && Date.now() - w.lastThreadRefresh >= 5000) {
            w.lastThreadRefresh = Date.now();
            w.loadThread(w.detailId, w.threadLimit, true);
        }
        discordDebounce.restart();
    }

    function scrollThreadToBottom() {
        if (!w.detailOpen)
            return ;

        // Keep following the bottom until the reader takes over. Context,
        // comments and images all arrive asynchronously and each one changes
        // the content height; a single animation would stop short.
        w.threadAutoScrolling = true;
        w.threadBottomFollow = true;
        w.contextAnchorPending = false;
        detailWheel.stop();
        // Land on the newest message in the same layout pass instead of
        // animating down after the view is already visible.
        detailScroll.contentY = Math.max(0, detailScroll.contentHeight - detailScroll.height);
        Qt.callLater(function () { w.threadScrollToBottomNow(); });
    }

    function threadScrollToBottomNow() {
        if (!w.detailOpen || !w.threadBottomFollow)
            return ;

        var target = Math.max(0, detailScroll.contentHeight - detailScroll.height);
        // Jump, don't animate. Opening a Discord thread should already be at
        // the newest message, and each later height change snaps to the new
        // bottom while the follow is active.
        if (Math.abs(target - detailScroll.contentY) >= 1)
            detailScroll.contentY = target;
        w.threadAutoScrolling = false;
    }

    function stopThreadBottomFollow() {
        w.threadUserScrolled = true;
        w.threadBottomFollow = false;
        w.threadAutoScrolling = false;
        w.contextAnchorPending = false;
        // A manual scroll cancels the post-send settle alignment.
        w.threadScrollTarget = null;
        threadScrollSettle.stop();
        detailWheel.stop();
    }

    function consumeThread(text) {
        try {
            var value = JSON.parse(text);
            if (value.schema !== "lucid.social/thread" || value.schema_version !== w.schemaVersion)
                throw new Error("unexpected thread schema");

            // A stale response must not clear the loading flag for the newer
            // request; doing so flashed the empty state and moved the scroll.
            if (value.item_id !== w.detailId || w.pendingThreadSeq !== w.threadSeq)
                return ;
            w.commentsLoading = false;

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
            if (w.detailPost && w.detailPost.source === "discord")
                fresh = fresh.filter(function (row) { return !w.postCoversComment(w.detailPost, row); });
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
                        // message_ids are bare snowflakes; the local row id is
                        // discord/<channel>/<message>. Compare the suffix, or
                        // a grouped reply rooted on an earlier message never
                        // matches and is appended as a second comment.
                        var ids = (candidateRef.message_ids || []).map(String);
                        var pendingRef = pending.ref || ({});
                        var pendingIds = [String(pending.id || "").split("/").pop()];
                        if (pendingRef.message_id)
                            pendingIds.push(String(pendingRef.message_id));
                        var nativeMatch = false;
                        for (var pn = 0; pn < pendingIds.length; pn++) {
                            if (pendingIds[pn] !== "" && ids.indexOf(pendingIds[pn]) >= 0) {
                                nativeMatch = true;
                                break;
                            }
                        }
                        if (nativeMatch) {
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
                    if (survivor.body && w.commentTextKey(survivor) === w.commentTextKey(server)) {
                        // The local echo already renders exactly what the
                        // server grouped. Keep its strings so the rich text
                        // (and any animated emoji) is not rebuilt.
                        merged.body = survivor.body;
                        merged.body_segments = survivor.body_segments || (survivor.body ? [survivor.body] : []);
                        merged.media = survivor.media;
                    } else {
                        if (!merged.body && survivor.body)
                            merged.body = survivor.body;
                        if (!merged.body_segments || merged.body_segments.length === 0)
                            merged.body_segments = survivor.body_segments || (survivor.body ? [survivor.body] : []);
                        if (!merged.media || merged.media.length === 0)
                            merged.media = survivor.media;
                    }
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
                var representedIds = ({});
                for (var ef = 0; ef < fresh.length; ef++) {
                    var freshRow = fresh[ef] || ({});
                    var freshRef = freshRow.ref || ({});
                    if (freshRef.message_id)
                        representedIds[String(freshRef.message_id)] = true;
                    var freshIds = freshRef.message_ids || [];
                    for (var fi = 0; fi < freshIds.length; fi++)
                        representedIds[String(freshIds[fi])] = true;
                    var freshTime = String(freshRow.created_at || "");
                    if (freshTime !== "" && (earliestFresh === "" || freshTime < earliestFresh))
                        earliestFresh = freshTime;
                }
                if (fresh.length > 0) {
                    for (var old = 0; old < w.comments.length; old++) {
                        var oldRow = w.comments[old];
                        if (!oldRow || !oldRow.id || usedIds[String(oldRow.id)] === true)
                            continue;
                        if (w.postCoversComment(w.detailPost, oldRow))
                            continue;
                        var oldRef = oldRow.ref || ({});
                        if (oldRef.local === true || String(oldRow.id).indexOf("pending/") === 0)
                            continue;
                        // A refresh may regroup the same messages under a
                        // different row id. The message ids are what prove the
                        // row is already on screen.
                        if (representedIds[String(oldRow.id)] === true)
                            continue;
                        var oldIds = oldRef.message_ids || [];
                        var alreadyShown = false;
                        for (var oi = 0; oi < oldIds.length; oi++) {
                            if (representedIds[String(oldIds[oi])] === true) {
                                alreadyShown = true;
                                break;
                            }
                        }
                        if (alreadyShown)
                            continue;
                        // Keep every server row this response did not
                        // mention, not just older ones. A refresh after a
                        // regroup can return a different slice; replacing the
                        // chain with it made existing comments vanish.
                        usedIds[String(oldRow.id)] = true;
                        out.push(oldRow);
                    }
                }
                out = w.dropSplitEmojiComments(out);
                // Reuse the rows already on screen when their content did not
                // change. A new object would rebuild every delegate, which is
                // visible as animated emoji restarting.
                var previousById = ({});
                for (var pb = 0; pb < w.comments.length; pb++) {
                    if (w.comments[pb] && w.comments[pb].id)
                        previousById[String(w.comments[pb].id)] = w.comments[pb];
                }
                var sameRows = out.length === w.comments.length;
                for (var ob = 0; ob < out.length; ob++) {
                    var priorRow = previousById[String(out[ob].id)];
                    if (priorRow && w.sameCommentContent(priorRow, out[ob]))
                        out[ob] = priorRow;
                    if (!sameRows || out[ob] !== w.comments[ob])
                        sameRows = false;
                }
                if (!sameRows)
                    w.comments = out;
                w.currentUserAuthor();
                var expandKeys = Object.keys(expandAfterMerge);
                if (expandKeys.length > 0) {
                    var expanded = Object.assign({}, w.expandedBranches);
                    for (var ek = 0; ek < expandKeys.length; ek++)
                        expanded[expandKeys[ek]] = true;
                    w.expandedBranches = expanded;
                }
            }
            if ((value.errors || []).length > 0)
                w.commentsError = Tr.t(value.errors[0].message || "comments could not refresh");

            var openedAtTop = w.threadOpening && !w.threadOpensAtBottom(w.detailPost);
            w.threadLoaded = true;
            w.settleThreadOpen();
            if (openedAtTop && !w.threadUserScrolled) {
                w.threadBottomFollow = false;
                w.threadAutoScrolling = false;
                Qt.callLater(function () {
                    if (w.detailOpen && !w.threadUserScrolled)
                        detailScroll.contentY = 0;
                });
            }
            if (w.threadAnchor !== null) {
                var anchor = w.threadAnchor;
                w.threadAnchor = null;
                Qt.callLater(function () { w.restoreThreadAnchor(anchor); });
            }
            // A nested chain is not infinite-scrolled: fill it to the source
            // limit once, then let branch collapse/expand do the controlling.
            if (!w.nestedFilled && w.hasNestedComments() && w.threadLimit < 60 && w.canLoadMoreComments()) {
                w.nestedFilled = true;
                w.loadThread(w.detailId, 60);
                return ;
            }

        } catch (error) {
            w.commentsLoading = false;
            w.threadLoaded = true;
            w.settleThreadOpen();
            if (w.pendingThreadSeq === w.threadSeq)
                w.commentsError = Tr.t("Could not read this thread.");

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
        if (w.sendTargets.length === 0) {
            w.loadSendTargets();
        } else {
            w.resetSendSelection(w.sendTargets);
            if (w.sendTargetIndex() < 0)
                w.sendCursorKey = w.sendTargetKey(w.sendTargets[0]);
        }
        // The panel opens on the channel filter; click rows to build a
        // multi-channel selection, then click the message field to write.
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
                w.selectedSendTargets = [];
                w.sendCursorKey = "";
                w.applyPrimarySendTarget();
                w.newPostError = Tr.t("No Discord channels are selected in the source sheet.");
            } else {
                // A selection change can remove channels picked earlier. Keep
                // every surviving selection and the first one as primary.
                w.resetSendSelection(w.sendTargets);
                if (w.sendTargetIndex() < 0)
                    w.sendCursorKey = w.sendTargetKey(w.sendTargets[0]);
                w.selectProfileSendTarget();
            }
        } catch (error) {
            w.newPostError = Tr.t("Could not read the channel list.");
        }
    }

    function sendTargetKey(target) {
        return String((target || {}).account || "") + "\n" + String((target || {}).channel_id || "");
    }

    function sendTargetSelected(target) {
        var key = w.sendTargetKey(target);
        for (var i = 0; i < w.selectedSendTargets.length; i++) {
            if (w.sendTargetKey(w.selectedSendTargets[i]) === key)
                return true;
        }
        return false;
    }

    function applyPrimarySendTarget() {
        var target = w.selectedSendTargets.length > 0 ? w.selectedSendTargets[0] : null;
        if (!target) {
            w.sendTargetId = "";
            w.sendTargetAccount = "";
            w.sendTargetTitle = "";
            w.sendTargetGuild = "";
            return ;
        }
        w.sendTargetId = String(target.channel_id || "");
        w.sendTargetAccount = String(target.account || "");
        w.sendTargetTitle = String(target.title || "");
        w.sendTargetGuild = String(target.guild_id || "");
    }

    // Kept for the callers that only need to establish the primary target.
    function selectSendTarget(target, focusMessage) {
        if (!target)
            return ;
        w.toggleSendTarget(target, focusMessage);
    }

    function toggleSendTarget(target, focusMessage) {
        if (!target)
            return ;
        var key = w.sendTargetKey(target);
        var next = [];
        var found = false;
        for (var i = 0; i < w.selectedSendTargets.length; i++) {
            var current = w.selectedSendTargets[i];
            if (w.sendTargetKey(current) === key)
                found = true;
            else
                next.push(current);
        }
        if (!found)
            next.push(target);
        w.selectedSendTargets = next;
        w.sendCursorKey = key;
        w.applyPrimarySendTarget();
        w.newPostError = "";
        if (focusMessage === true)
            Qt.callLater(function () { newComposer.focusInput(); });
    }

    function sendTargetIndex() {
        var targets = w.shownSendTargets;
        for (var i = 0; i < targets.length; i++) {
            if (w.sendTargetKey(targets[i]) === w.sendCursorKey)
                return i;
        }
        // The cursor can point at a filtered-out target; fall back to the
        // first selected row, then the first visible row.
        for (var s = 0; s < targets.length; s++) {
            if (w.sendTargetSelected(targets[s]))
                return s;
        }
        return targets.length > 0 ? 0 : -1;
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
        w.sendCursorKey = w.sendTargetKey(targets[index]);
        targetList.positionViewAtIndex(index, ListView.Contain);
    }

    function confirmSendTarget() {
        if (!w.newPostOpen)
            return false;

        var targets = w.shownSendTargets;
        if (targets.length === 0)
            return false;

        var index = Math.max(0, w.sendTargetIndex());
        var target = targets[index];
        if (!w.sendTargetSelected(target))
            w.toggleSendTarget(target, false);
        w.sendCursorKey = w.sendTargetKey(target);
        Qt.callLater(function () { newComposer.focusInput(); });
        return true;
    }

    function resetSendSelection(targets) {
        var source = targets || w.sendTargets || [];
        var kept = [];
        for (var i = 0; i < w.selectedSendTargets.length; i++) {
            var key = w.sendTargetKey(w.selectedSendTargets[i]);
            for (var j = 0; j < source.length; j++) {
                if (w.sendTargetKey(source[j]) === key) {
                    kept.push(source[j]);
                    break;
                }
            }
        }
        w.selectedSendTargets = kept;
        w.applyPrimarySendTarget();
        if (w.sendTargetIndex() < 0 && w.shownSendTargets.length > 0)
            w.sendCursorKey = w.sendTargetKey(w.shownSendTargets[0]);
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
            var when = w.feedTime(b) - w.feedTime(a);
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

        var targets = w.selectedSendTargets.slice();
        if (targets.length === 0) {
            w.newPostError = Tr.t("Choose at least one channel first.");
            return ;
        }
        if (body === "" && images.length === 0)
            return ;

        w.sending = true;
        w.newPostError = "";
        w.sendBatchError = "";
        w.sendFailedTargets = [];
        w.newPostBody = body;
        w.newPostImages = images;
        newComposer.clear();
        newComposer.clearAttachments();
        w.newPostOpen = false;

        var firstLocalId = "";
        for (var t = 0; t < targets.length; t++) {
            var target = targets[t];
            var localId = "pending/new/" + Date.now() + "/" + (++w.pendingSeq);
            if (t === 0)
                firstLocalId = localId;

            // Put every target in the feed before the service answers; each
            // response is merged into its own row.
            var optimistic = {
                "id": localId,
                "source": "discord",
                "stream_ids": w.sendStreamIds(
                    String(target.channel_id || ""),
                    String(target.guild_id || ""),
                    String(target.account || "")),
                "kind": "post",
                "author": w.currentUserAuthor() || {"id": "", "handle": "", "display_name": Tr.t("You"), "avatar_url": "", "profile_url": ""},
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
                    "channel_id": String(target.channel_id || ""),
                    "guild_id": String(target.guild_id || ""),
                    "account": String(target.account || "")
                },
                "extra": {}
            };
            w.upsertFeedItem(optimistic, "");

            var job = {
                "localId": localId,
                "target": target,
                "primary": t === 0,
                "body": body,
                "images": images
            };
            w.sendJobs = w.sendJobs.concat([job]);

            var args = [w.service, "send", "--json",
                "--channel", String(target.channel_id || ""),
                "--account", String(target.account || "")];
            if (String(target.guild_id || "") !== "")
                args.push("--guild", String(target.guild_id || ""));
            args.push("--body", body);
            for (var i = 0; i < images.length; i++)
                args.push("--image", images[i]);
            w.startSendJob(job, args);
        }
        w.newPostLocalId = firstLocalId;
    }

    function startSendJob(job, args) {
        var proc = sendJobComponent.createObject(w);
        if (proc === null) {
            w.completeSendJob(job, "", 1);
            return ;
        }
        proc.job = job;
        proc.command = args;
        proc.running = true;
    }

    function removeSendJob(job) {
        var next = [];
        for (var i = 0; i < w.sendJobs.length; i++) {
            if (w.sendJobs[i] && w.sendJobs[i].localId !== job.localId)
                next.push(w.sendJobs[i]);
        }
        w.sendJobs = next;
    }

    function failSendJob(job, message) {
        w.removeSendJob(job);
        w.items = w.items.filter((post) => post.id !== job.localId);
        if (w.detailId === job.localId)
            w.closeDetail();
        w.sendFailedTargets = w.sendFailedTargets.concat([job.target]);
        if (w.sendBatchError === "")
            w.sendBatchError = String(message || "Message was not accepted.");
    }

    function finishSendBatch() {
        if (w.sendJobs.length > 0)
            return ;
        w.sending = false;
        if (w.sendFailedTargets.length > 0) {
            // Retrying should target only the channels that failed.
            w.selectedSendTargets = w.sendFailedTargets.slice();
            w.sendFailedTargets = [];
            w.applyPrimarySendTarget();
            w.newPostError = w.sendBatchError !== ""
                ? w.sendBatchError
                : Tr.t("Some channels were not sent.");
            w.sendBatchError = "";
            w.newPostOpen = true;
            newComposer.setText(w.newPostBody);
            newComposer.setAttachments(w.newPostImages);
            Qt.callLater(function () { newComposer.focusInput(); });
            return ;
        }
        w.newPostError = "";
        w.newPostBody = "";
        w.newPostImages = [];
        w.newPostLocalId = "";
        w.sendBatchError = "";
        w.sendFailedTargets = [];
    }

    function completeSendJob(job, text, code) {
        w.removeSendJob(job);
        if (code !== 0 && String(text || "").trim() === "") {
            w.failSendJob(job, Tr.t("Could not reach the message service."));
            w.finishSendBatch();
            return ;
        }
        try {
            var value = JSON.parse(text);
            if (value.ok !== true) {
                w.failSendJob(job, value.error || "Message was not accepted.");
                w.finishSendBatch();
                return ;
            }
            var item = value.item;
            if (!item || String(item.id || "") === "") {
                w.failSendJob(job, Tr.t("The message service returned no post."));
                w.finishSendBatch();
                return ;
            }
            var row = null;
            for (var i = 0; i < w.items.length; i++) {
                if (w.items[i] && w.items[i].id === job.localId) {
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
            w.upsertFeedItem(merged, job.localId);
            if (job.primary) {
                // The first selected channel is the one the writer lands on.
                w.openPost(merged);
                Qt.callLater(function () { composer.focusInput(); });
            }
        } catch (error) {
            w.failSendJob(job, Tr.t("The message service returned an unexpected payload."));
        }
        w.finishSendBatch();
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
        if (w.threadOpensAtBottom(w.detailPost) && !w.threadUserScrolled) {
            w.scrollThreadToBottom();
        } else if (!w.threadUserScrolled) {
            w.threadBottomFollow = false;
            w.threadAutoScrolling = false;
            w.threadReloadOffset = -1;
            detailScroll.contentY = 0;
        }
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

    readonly property bool threadPresenceOffline: String(w.threadPresence).toLowerCase() === "offline"

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

    function postContainsAudio(post, url) {
        var media = (post || {}).media || [];
        for (var i = 0; i < media.length; i++) {
            var item = media[i] || {};
            if (String(item.kind || "") !== "audio")
                continue;
            if (String(item.url || "") === url || String(item.external_url || "") === url
                || SocialAudio.sameMedia(item.url) || SocialAudio.sameMedia(item.external_url))
                return true;
        }
        return false;
    }

    function openPost(post, reply) {
        if (!post || !post.id)
            return ;

        // Audio belongs to the open post, not to whatever card was clicked in
        // the feed. Keep it only when the detail view shows the same file.
        var playingAudio = String(SocialAudio.url || "");
        if (playingAudio !== "" && !w.postContainsAudio(post, playingAudio))
            SocialAudio.stop();

        w.pickerOpen = false;
        // A settle alignment from the previous thread must not fire here.
        w.threadScrollTarget = null;
        threadScrollSettle.stop();
        if (w.detailId === "")
            w.feedReturnAnchor = w.captureFeedAnchor();
        w.detailId = post.id;
        w.detailPost = post;
        // Discord previews are author-grouped before the full thread arrives,
        // so the first frame is already in its final shape.
        var previewRows = [];
        var previewSeeds = post.comments_preview || [];
        for (var pi = 0; pi < previewSeeds.length; pi++) {
            var previewRow = Object.assign({}, previewSeeds[pi]);
            previewRow.ref = Object.assign({}, previewRow.ref || {}, {"preview": true});
            if (w.postCoversComment(post, previewRow))
                continue;
            previewRows.push(previewRow);
        }
        w.comments = post.source === "discord"
            ? w.dropSplitEmojiComments(w.groupComments(previewRows))
            : previewRows;
        w.threadLimit = 20;
        w.threadCommentTotal = -1;
        w.threadSearchQuery = "";
        searchInput.text = "";
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
        w.contextGrouped = false;
        w.contextSeq++;
        w.threadOpening = true;
        w.threadLoaded = false;
        w.contextLoaded = post.source !== "discord";
        w.threadAutoScrolling = false;
        w.threadBottomFollow = false;
        w.threadUserScrolled = false;
        w.contextAnchorPending = false;
        detailWheel.stop();
        if (w.threadOpensAtBottom(post)) {
            // Discord opens at the newest message with no scroll animation.
            w.scrollThreadToBottom();
        } else {
            detailScroll.contentY = 0;
        }
        w.loadThread(post.id, 20);
        if (post.source === "discord") {
            if (w.sendTargets.length === 0 && !w.sendTargetsLoading)
                w.loadSendTargets();
            w.loadContext("");
        }
        // Warm the avatar cache for the optimistic comment row while the
        // reader is still looking at the post.
        w.currentUserAuthor();
        // Opening a post is an invitation to write: focus the composer after
        // the detail view becomes visible, whether this was a plain open or a
        // reply.
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
            w.contextGrouped = value.grouped === true;

            var incoming = value.comments || [];
            var keepBottom = w.threadOpensAtBottom(w.detailPost) && !w.threadUserScrolled;
            if (!w.contextReady) {
                if (keepBottom) {
                    w.threadBottomFollow = true;
                    w.contextAnchorPending = false;
                    w.contextComments = incoming;
                    w.contextCursor = value.cursor || "";
                    w.contextHasMore = value.has_more === true;
                    w.contextReady = true;
                    w.contextLoaded = true;
                    w.settleThreadOpen();
                    Qt.callLater(function () { w.threadScrollToBottomNow(); });
                } else {
                    w.contextAnchorY = detailScroll.contentY;
                    w.contextAnchorHeight = detailScroll.contentHeight;
                    w.contextAnchorPending = !w.threadAutoScrolling;
                    w.contextComments = incoming;
                    w.contextCursor = value.cursor || "";
                    w.contextHasMore = value.has_more === true;
                    w.contextReady = true;
                    w.contextLoaded = true;
                    w.settleThreadOpen();
                }
            } else if (incoming.length > 0) {
                if (keepBottom) {
                    w.threadBottomFollow = true;
                    w.contextAnchorPending = false;
                    w.contextComments = incoming.concat(w.contextComments);
                    w.contextCursor = value.cursor || w.contextCursor;
                    w.contextHasMore = value.has_more === true;
                    Qt.callLater(function () { w.threadScrollToBottomNow(); });
                } else {
                    w.contextAnchorY = detailScroll.contentY;
                    w.contextAnchorHeight = detailScroll.contentHeight;
                    w.contextAnchorPending = !w.threadAutoScrolling;
                    w.contextComments = incoming.concat(w.contextComments);
                    w.contextCursor = value.cursor || w.contextCursor;
                    w.contextHasMore = value.has_more === true;
                }
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
        // Audio that belongs to the post still visible in the feed keeps
        // playing when the thread closes; detail-only comment recordings stop
        // with the card that owned them.
        var playingAudio = String(SocialAudio.url || "");
        var keepAudio = false;
        if (playingAudio !== "" && w.detailPost !== null) {
            for (var i = 0; i < w.items.length; i++) {
                if (w.items[i].id === w.detailPost.id && w.postContainsAudio(w.items[i], playingAudio)) {
                    keepAudio = true;
                    break;
                }
            }
        }
        if (playingAudio !== "" && !keepAudio)
            SocialAudio.stop();
        w.threadBottomFollow = false;
        w.threadUserScrolled = false;
        w.threadAutoScrolling = false;
        w.threadScrollTarget = null;
        threadScrollSettle.stop();
        w.detailId = "";
        w.detailPost = null;
        w.comments = [];
        w.commentsLoading = false;
        w.commentsError = "";
        w.threadCommentTotal = -1;
        w.threadSearchQuery = "";
        searchInput.text = w.searchQuery;
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
        if (w.searchResults.length > 0) {
            var hits = w.searchResults.slice();
            for (var s = 0; s < hits.length; s++) {
                if (hits[s] && hits[s].id === id)
                    hits[s] = Object.assign({}, hits[s], patch);
            }
            w.searchResults = hits;
        }
        if (w.detailPost !== null && w.detailPost.id === id)
            w.detailPost = Object.assign({}, w.detailPost, patch);

    }

    // The thread view expands a Discord author group into one row per
    // message, so a reaction or delete targets a synthetic id like
    // discord/<channel>/<message> that is not a comment id. Find the group
    // (and the segment) that owns the message.
    function commentSegmentIndex(comment, id) {
        var ref = (comment || {}).ref || ({});
        var ids = ref.segment_ids;
        if (!Array.isArray(ids))
            return -1;
        var mid = String(id || "");
        var slash = mid.lastIndexOf("/");
        if (slash >= 0)
            mid = mid.slice(slash + 1);
        for (var i = 0; i < ids.length; i++) {
            if (String(ids[i] || "") === mid)
                return i;
        }
        return -1;
    }

    function patchCommentSegment(comment, index, patch) {
        var ref = Object.assign({}, comment.ref || ({}));
        if (patch.reactions !== undefined) {
            var segmentReactions = Array.isArray(ref.segment_reactions) ? ref.segment_reactions.slice() : [];
            while (segmentReactions.length <= index)
                segmentReactions.push([]);
            segmentReactions[index] = patch.reactions;
            ref.segment_reactions = segmentReactions;
        }
        if (patch.liked !== undefined) {
            var segmentLiked = Array.isArray(ref.segment_liked) ? ref.segment_liked.slice() : [];
            while (segmentLiked.length <= index)
                segmentLiked.push(false);
            segmentLiked[index] = patch.liked === true;
            ref.segment_liked = segmentLiked;
        }
        return Object.assign({}, comment, {"ref": ref});
    }

    function patchComment(id, patch) {
        var next = w.comments.slice();
        for (var i = 0; i < next.length; i++) {
            if (next[i].id === id) {
                next[i] = Object.assign({}, next[i], patch);
                continue;
            }
            var index = w.commentSegmentIndex(next[i], id);
            if (index >= 0)
                next[i] = w.patchCommentSegment(next[i], index, patch);
        }
        w.comments = next;
        var context = w.contextComments.slice();
        for (var c = 0; c < context.length; c++) {
            if (context[c].id === id) {
                context[c] = Object.assign({}, context[c], patch);
                continue;
            }
            var contextIndex = w.commentSegmentIndex(context[c], id);
            if (contextIndex >= 0)
                context[c] = w.patchCommentSegment(context[c], contextIndex, patch);
        }
        w.contextComments = context;
    }

    // Drop one message out of a grouped comment, keeping the remaining
    // segments (text, media, reactions, ids, times) aligned.
    function removeCommentSegment(comment, index) {
        var ref = Object.assign({}, comment.ref || ({}));
        var texts = Array.isArray(comment.body_segments) ? comment.body_segments.slice() : [];
        if (index < texts.length)
            texts.splice(index, 1);
        var keys = ["segment_ids", "segment_times", "segment_media", "segment_reactions",
            "segment_reaction_users", "segment_liked"];
        for (var k = 0; k < keys.length; k++) {
            var key = keys[k];
            var values = ref[key];
            if (Array.isArray(values) && index < values.length) {
                values = values.slice();
                values.splice(index, 1);
                ref[key] = values;
            }
        }
        if (Array.isArray(ref.segment_media)) {
            var media = [];
            for (var m = 0; m < ref.segment_media.length; m++) {
                if (Array.isArray(ref.segment_media[m]))
                    media = media.concat(ref.segment_media[m]);
            }
            comment = Object.assign({}, comment, {"media": media});
        }
        var body = "";
        for (var t = 0; t < texts.length; t++) {
            var text = String(texts[t] || "");
            if (text === "")
                continue;
            body = body === "" ? text : body + "\n" + text;
        }
        return Object.assign({}, comment, {"body": body, "body_segments": texts, "ref": ref});
    }

    function removeCommentById(id, context) {
        var source = context ? w.contextComments : w.comments;
        var next = [];
        var removed = 0;
        for (var i = 0; i < source.length; i++) {
            var comment = source[i];
            if (comment.id === id) {
                removed += w.commentMessageCount(comment);
                continue;
            }
            var index = w.commentSegmentIndex(comment, id);
            if (index >= 0) {
                var ids = ((comment.ref || {}).segment_ids || []);
                var remaining = Array.isArray(ids) ? ids.length - 1 : 0;
                removed += 1;
                if (remaining > 0)
                    next.push(w.removeCommentSegment(comment, index));
                continue;
            }
            next.push(comment);
        }
        if (context)
            w.contextComments = next;
        else
            w.comments = next;
        return removed;
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
        for (var c = 0; c < w.contextComments.length; c++) {
            if (w.contextComments[c].id === id)
                return w.contextComments[c];
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
        var pending = Object.assign({}, w.optimisticLikes);
        if (pending[likeProc.targetId] !== undefined) {
            delete pending[likeProc.targetId];
            w.optimisticLikes = pending;
        }
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
        var pendingLikes = Object.assign({}, w.optimisticLikes);
        pendingLikes[post.id] = {"liked": next, "stats": stats};
        w.optimisticLikes = pendingLikes;
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
        var pendingCommentLikes = Object.assign({}, w.optimisticLikes);
        pendingCommentLikes[comment.id] = {"liked": next, "stats": stats};
        w.optimisticLikes = pendingCommentLikes;
        w.queueLike({
            "id": comment.id,
            "kind": "comment",
            "on": next,
            "revertTo": live.liked === true,
            "revertStats": live.stats || ({})
        });
    }

    function reactionTarget(target) {
        if (!target || !target.id)
            return null;
        if (target.post_id !== undefined && target.post_id !== "") {
            for (var i = 0; i < w.comments.length; i++) {
                if (w.comments[i] && w.comments[i].id === target.id)
                    return w.comments[i];
            }
            for (var c = 0; c < w.contextComments.length; c++) {
                if (w.contextComments[c] && w.contextComments[c].id === target.id)
                    return w.contextComments[c];
            }
            return target;
        }
        for (var j = 0; j < w.items.length; j++) {
            if (w.items[j] && w.items[j].id === target.id)
                return w.items[j];
        }
        return target;
    }

    function reactionKey(reaction) {
        if (!reaction)
            return "";
        return String(reaction.id || reaction.emoji || reaction.name || "");
    }

    function reactionRequest(reaction) {
        if (!reaction)
            return "";
        var id = String(reaction.id || "");
        if (id !== "")
            return String(reaction.name || "") + ":" + id;
        return String(reaction.emoji || reaction.name || "");
    }

    function reactionsAfter(list, reaction, on) {
        var key = w.reactionKey(reaction);
        var out = [];
        var found = false;
        for (var i = 0; i < (list || []).length; i++) {
            var current = Object.assign({}, list[i] || {});
            if (w.reactionKey(current) === key) {
                found = true;
                if (on) {
                    if (current.me !== true)
                        current.count = Number(current.count || 0) + 1;
                    current.me = true;
                } else {
                    if (current.me === true)
                        current.count = Math.max(0, Number(current.count || 0) - 1);
                    current.me = false;
                }
                if (Number(current.count || 0) > 0)
                    out.push(current);
            } else {
                out.push(current);
            }
        }
        if (on && !found) {
            var added = Object.assign({}, reaction || {});
            added.count = 1;
            added.me = true;
            out.push(added);
        }
        return out;
    }

    function patchReactionTarget(target, reactions) {
        if (!target || !target.id)
            return ;
        if (target.post_id !== undefined && target.post_id !== "")
            w.patchComment(target.id, {"reactions": reactions});
        else
            w.patchPost(target.id, {"reactions": reactions});
    }

    function toggleReaction(target, reaction) {
        if (!target || !reaction || !(target.capabilities || {}).react)
            return ;
        var live = w.reactionTarget(target) || target;
        var on = reaction.me !== true;
        var previous = (live.reactions || []).slice();
        w.patchReactionTarget(live, w.reactionsAfter(previous, reaction, on));
        w.queueReaction({
            "id": live.id,
            "kind": live.post_id !== undefined && live.post_id !== "" ? "comment" : "post",
            "account": String((live.ref || {}).account || ""),
            "emoji": w.reactionRequest(reaction),
            "on": on,
            "revert": previous
        });
    }

    function addReaction(target, entry) {
        if (!target || !entry)
            return ;
        var live = w.reactionTarget(target) || target;
        var key = entry.custom === true ? String(entry.id || "") : String(entry.e || "");
        var list = live.reactions || [];
        for (var i = 0; i < list.length; i++) {
            var current = list[i];
            if (w.reactionKey(current) === key) {
                w.toggleReaction(live, current);
                return ;
            }
        }
        var reaction = entry.custom === true
            ? {
                "emoji": "",
                "name": String(entry.n || ""),
                "id": String(entry.id || ""),
                "image": String(entry.image || ""),
                "animated": entry.animated === true,
                "count": 0,
                "me": false
            }
            : {
                "emoji": String(entry.e || ""),
                "name": String(entry.n || entry.e || ""),
                "id": "",
                "image": "",
                "animated": false,
                "count": 0,
                "me": false
            };
        w.toggleReaction(live, reaction);
    }

    function queueReaction(action) {
        w.reactionQueue = w.reactionQueue.concat([action]);
        w.runReactionQueue();
    }

    function runReactionQueue() {
        if (reactionProc.running || w.reactionQueue.length === 0)
            return ;
        var action = w.reactionQueue[0];
        reactionProc.targetId = action.id;
        reactionProc.targetKind = action.kind;
        reactionProc.revertReactions = action.revert || [];
        reactionProc.resultOk = true;
        reactionProc.errorText = "";
        reactionProc.command = [
            w.service, "react", "--json", "--item", action.id,
            "--emoji", action.emoji, action.on ? "--on" : "--off"
        ];
        if (String(action.account || "") !== "") {
            reactionProc.command.push("--account");
            reactionProc.command.push(String(action.account));
        }
        reactionProc.running = true;
    }

    function consumeReaction(text) {
        try {
            var value = JSON.parse(text);
            if (value.ok === true) {
                w.patchReactionsById(reactionProc.targetId, reactionProc.targetKind, value.reactions || []);
            } else {
                reactionProc.errorText = Tr.t(value.error || "The source refused the reaction.");
                reactionProc.resultOk = false;
            }
        } catch (error) {
            reactionProc.errorText = Tr.t("The reaction service returned an unexpected payload.");
            reactionProc.resultOk = false;
        }
    }

    function patchReactionsById(id, kind, reactions) {
        if (id === "")
            return ;
        if (kind === "comment")
            w.patchComment(id, {"reactions": reactions});
        else
            w.patchPost(id, {"reactions": reactions});
    }

    function finishReaction(ok) {
        reactionProc.running = false;
        if (!ok) {
            w.patchReactionsById(reactionProc.targetId, reactionProc.targetKind, reactionProc.revertReactions || []);
            if (reactionProc.errorText !== "")
                w.actionError = reactionProc.errorText;
        }
        var queue = w.reactionQueue.slice();
        if (queue.length > 0)
            queue.shift();
        w.reactionQueue = queue;
        Qt.callLater(w.runReactionQueue);
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
        if (String((comment.ref || {}).account || "") !== "") {
            deleteProc.command.push("--account");
            deleteProc.command.push(String((comment.ref || {}).account || ""));
        }
        deleteProc.running = true;
    }

    function consumeDelete(text) {
        try {
            var value = JSON.parse(text);
            if (value.ok !== true) {
                w.actionError = Tr.t(value.error || "Could not delete that message.");
                return ;
            }
            var id = deleteProc.targetId;
            if (deleteProc.targetKind === "post") {
                w.items = w.items.filter((post) => post.id !== id);
                if (w.detailId === id)
                    w.closeDetail();
            } else {
                var inContext = false;
                for (var xi = 0; xi < w.contextComments.length; xi++) {
                    if (w.contextComments[xi] && w.contextComments[xi].id === id) {
                        inContext = true;
                        break;
                    }
                }
                if (inContext) {
                    // Messages above the root are channel context, not part of
                    // the reply count.
                    w.removeCommentById(id, true);
                } else {
                    var removed = w.removeCommentById(id, false);
                    if (removed < 1)
                        removed = 1;
                    if (w.threadCommentTotal >= 0)
                        w.threadCommentTotal = Math.max(0, w.threadCommentTotal - removed);
                    if (w.detailPost && w.detailPost.id === w.detailId) {
                        var count = Math.max(0, Number(w.detailPost.comment_count || 0) - removed);
                        var stats = Object.assign({}, w.detailPost.stats || {});
                        stats.comments = count;
                        w.patchPost(w.detailPost.id, {"comment_count": count, "stats": stats});
                    }
                }
            }
            w.actionError = "";
        } catch (error) {
            w.actionError = Tr.t("The delete service returned an unexpected payload.");
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
                return ;
            }
            var returned = value.item || ({});
            var patch = {"liked": value.liked === true};
            if (returned.stats)
                patch.stats = returned.stats;
            if (likeProc.targetKind === "comment")
                w.patchComment(likeProc.targetId, patch);
            else
                w.patchPost(likeProc.targetId, patch);
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

    function startOAuth(sourceId) {
        if (w.authBusyKey !== "")
            return ;

        w.authError = "";
        w.authStatus = "Waiting for browser sign-in…";
        w.authBusyKey = sourceId + "/oauth";
        authProc.pending = "";
        authProc.command = [w.service, "auth", "--json", "--oauth", "--source", sourceId];
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
                w.authError = Tr.t(value.error || "Could not save that credential.");
                return ;
            }
            w.authStatus = value.cleared === true
                ? Tr.t("Cleared")
                : (value.oauth === true ? Tr.t(value.message || "Signed in") : Tr.t("Saved"));
            w.authError = "";
            sourcePicker.newAccountName = "";
            sourcePicker.newAccountToken = "";
            w.loadStreams();
            w.loadSendTargets();
            w.loadFeed(true);
        } catch (error) {
            w.authError = Tr.t("The credential service returned an unexpected payload.");
        }
    }

    function ownAuthorKey(source, account) {
        source = String(source || "");
        account = String(account || "");
        if (source === "" && account === "")
            return "";
        return source + "|" + account;
    }

    function ownAuthorContext() {
        // The new-post sheet owns its target account; a detail thread owns the
        // account that posted it. Do not let either borrow the other's avatar.
        if (w.newPostOpen)
            return {"source": "discord", "account": String(w.sendTargetAccount || "")};
        var post = w.detailPost;
        if (post !== null) {
            var source = String(post.source || "");
            if (source !== "") {
                return {
                    "source": source,
                    "account": String((post.ref || {}).account || "")
                };
            }
        }
        return {"source": "discord", "account": String(w.sendTargetAccount || "")};
    }

    function authorForAccount(value, account, source) {
        var ref = (value || {}).ref || {};
        if (ref.mine !== true)
            return null;
        var valueAccount = String(ref.account || "");
        if (String(account || "") !== "" && valueAccount !== "" && valueAccount !== String(account))
            return null;
        var valueSource = String((value || {}).source || source || "");
        if (String(source || "") !== "" && valueSource !== "" && valueSource !== String(source))
            return null;
        var author = (value || {}).author || {};
        if (String(author.id || author.handle || author.display_name || "") === "")
            return null;
        return Object.assign({}, author);
    }

    function rememberOwnAuthor(author, account, source) {
        if (!author || String(author.avatar_url || "") === "")
            return ;
        if (String(author.id || author.handle || author.display_name || "") === "")
            return ;
        var key = w.ownAuthorKey(source, account);
        if (key === "")
            return ;
        var cached = w.cachedOwnAuthors[key];
        if (cached && String(cached.avatar_url || "") === String(author.avatar_url)
            && String(cached.id || "") === String(author.id || ""))
            return ;
        var next = Object.assign({}, w.cachedOwnAuthors);
        next[key] = Object.assign({}, author);
        w.cachedOwnAuthors = next;
    }

    function currentUserAuthor() {
        var context = w.ownAuthorContext();
        var account = context.account;
        var source = context.source;
        var fallback = null;
        var found = null;

        function consider(value) {
            var author = w.authorForAccount(value, account, source);
            if (!author)
                return false;
            if (String(author.avatar_url || "") !== "") {
                var ref = (value || {}).ref || {};
                w.rememberOwnAuthor(
                    author,
                    String(ref.account || account || ""),
                    String((value || {}).source || source || ""));
                found = author;
                return true;
            }
            if (fallback === null)
                fallback = author;
            return false;
        }

        // The newest own message in the open thread is the best match. Fall
        // back to context, the root post, then anything already in the feed;
        // the same avatar URL is reused from the QML image cache.
        for (var i = w.comments.length - 1; i >= 0; i--) {
            if (consider(w.comments[i]))
                return Object.assign({}, found);
        }
        for (var c = w.contextComments.length - 1; c >= 0; c--) {
            if (consider(w.contextComments[c]))
                return Object.assign({}, found);
        }
        if (consider(w.detailPost))
            return Object.assign({}, found);
        for (var itemIndex = 0; itemIndex < w.items.length; itemIndex++) {
            var item = w.items[itemIndex];
            if (consider(item))
                return Object.assign({}, found);
            var preview = (item || {}).comments_preview || [];
            for (var p = preview.length - 1; p >= 0; p--) {
                if (consider(preview[p]))
                    return Object.assign({}, found);
            }
        }
        var cached = w.cachedOwnAuthors[w.ownAuthorKey(source, account)];
        if (cached)
            return Object.assign({}, cached);
        return fallback;
    }

    function replyQuote(id, name) {
        var found = null;
        for (var i = 0; i < w.comments.length; i++) {
            if (w.comments[i] && w.comments[i].id === id) {
                found = w.comments[i];
                break;
            }
        }
        if (found === null) {
            for (var c = 0; c < w.contextComments.length; c++) {
                if (w.contextComments[c] && w.contextComments[c].id === id) {
                    found = w.contextComments[c];
                    break;
                }
            }
        }
        if (found === null)
            return "";
        var author = (found.author || {}).display_name || (found.author || {}).handle || name || "message";
        var text = String(found.body || "").replace(/\s+/g, " ").trim();
        if (text.length > 220)
            text = text.slice(0, 217).replace(/\s+$/, "") + "…";
        if (text === "")
            text = (found.media || []).length > 0 ? Tr.t("Attachment") : Tr.t("Replying to an earlier message");
        var quote = "> **" + author + "** · " + text;
        var media = found.media || [];
        for (var m = 0; m < media.length; m++) {
            var entry = media[m] || {};
            var image = String(entry.thumbnail_url || "");
            if (image === "" && String(entry.kind || "") === "image")
                image = String(entry.url || "");
            if (/^(https?|file):\/\//.test(image)) {
                quote += "\n> ![media](" + image + ")";
                break;
            }
        }
        return quote;
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
        // Reuse the account's own author so the row can join the latest
        // author group and paint its avatar on the first frame, before the
        // service round-trip replaces it with the server copy.
        var ownAuthor = w.currentUserAuthor();
        var ownContext = w.ownAuthorContext();
        var quoteSource = w.detailPost ? String(w.detailPost.source || "") : "";
        var quote = target !== "" && target !== itemId && quoteSource === "discord"
            ? w.replyQuote(target, targetName) : "";
        // This row is shown immediately and stays the same object when the
        // service confirms; it is not a "pending" placeholder.
        var pending = {
            "id": localId,
            "post_id": itemId,
            "parent_id": target !== "" ? target : itemId,
            "depth": target !== "" ? 1 : 0,
            "author": ownAuthor || {"id": "", "handle": "", "display_name": Tr.t("You"), "avatar_url": "", "profile_url": ""},
            "body": body,
            "body_segments": quote !== ""
                ? (body !== "" ? [quote, body] : [quote])
                : (body !== "" ? [body] : []),
            "created_at": new Date().toISOString(),
            "media": w.localMediaObjects(images),
            "stats": {"likes": null, "comments": null, "reposts": null, "score": null},
            "capabilities": {"like": false, "comment": true, "share": false, "media": false, "grouping": false},
            "ref": {
                "mine": true,
                "local": true,
                "account": String(ownContext.account || ""),
                "source": String(ownContext.source || "")
            },
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
        // Reveal the row we just sent, including when it is a reply deep in
        // an already-open chain. bottom=true aligns the tail of the group the
        // new message may have joined.
        w.scrollThreadToComment(localId, 0, target !== "" ? target : itemId, true);
        if (w.threadCommentTotal >= 0)
            w.threadCommentTotal += 1;
        if (w.detailPost && w.detailPost.id === itemId) {
            var count = Number(w.detailPost.comment_count || 0) + 1;
            var stats = Object.assign({}, w.detailPost.stats || {});
            stats.comments = count;
            var rootExtra = Object.assign({}, w.detailPost.extra || {});
            rootExtra.latest = {
                "id": pending.id,
                "author": pending.author,
                "body": String(pending.body || "").slice(0, 240),
                "created_at": pending.created_at
            };
            w.patchPost(itemId, {"comment_count": count, "stats": stats, "extra": rootExtra});
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
            w.failCommentJob(job, Tr.t("Could not start the comment service."));
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
            if (w.detailPost && w.detailPost.id === job.itemId && Number(w.detailPost.comment_count || 0) > 0) {
                var count = Number(w.detailPost.comment_count || 0) - 1;
                var stats = Object.assign({}, w.detailPost.stats || {});
                stats.comments = count;
                w.patchPost(job.itemId, {"comment_count": count, "stats": stats});
            }
        }
        if (w.detailId === job.itemId) {
            if (message !== "")
                w.composeError = message;
            if (String(composer.text || "") === "" && (composer.attachments || []).length === 0) {
                composer.setText(job.body);
                composer.setAttachments(job.images);
                w.replyTo = job.replyTo;
                w.replyName = job.replyName;
            }
        }
    }

    function completeCommentJob(job, text, code) {
        w.removeCommentJob(job.localId);
        if (code !== 0 && String(text || "").trim() === "") {
            w.failCommentJob(job, Tr.t("Could not reach the comment service."));
            return ;
        }
        try {
            var value = JSON.parse(text);
            if (value.ok !== true) {
                w.failCommentJob(job, Tr.t(value.error || "Comment was not accepted."));
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
                    // The browser reply response may only know the handle; keep
                    // the avatar/display name already shown on the optimistic row.
                    var mergedAuthor = Object.assign({}, (comment.author || {}));
                    var rowAuthor = row.author || {};
                    for (var authorKey in rowAuthor) {
                        if (!mergedAuthor[authorKey])
                            mergedAuthor[authorKey] = rowAuthor[authorKey];
                    }
                    merged.author = mergedAuthor;
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
                    var fallbackContext = w.ownAuthorContext();
                    var mergedRef = merged.ref || {};
                    w.rememberOwnAuthor(
                        merged.author,
                        String(mergedRef.account || fallbackContext.account || ""),
                        String(mergedRef.source || fallbackContext.source || ""));
                    if (serverIndex >= 0 && serverIndex !== localIndex) {
                        next.splice(localIndex, 1);
                        // Removing the local row shifts a later server row.
                        serverIndex = serverIndex > localIndex ? serverIndex - 1 : serverIndex;
                        next[serverIndex] = merged;
                    } else {
                        next[localIndex] = merged;
                    }
                    w.comments = next;
                    // The server copy can move into a group or change the row
                    // id. Keep the viewport on the message that was sent.
                    w.scrollThreadToComment(merged.id, 0, "", true);
                }
            }
            if (value.pending === true)
                w.actionError = Tr.t("Queued for the comment relay");
        } catch (error) {
            w.failCommentJob(job, Tr.t("The comment service returned an unexpected payload."));
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

        // Mouse wheels report a 120-unit notch in angleDelta; some Wayland
        // stacks also fill pixelDelta with a smaller value. Prefer the notch so
        // the 3x applies to the real wheel distance; touchpads fall back to
        // their pixel delta.
        var angle = Number(event.angleDelta.y || 0);
        var dy = angle !== 0 ? (angle / 120) * 60 : Number(event.pixelDelta.y || 0);

        var maxY = Math.max(0, target.contentHeight - target.height);
        var from = target.contentY;
        if (dy > 0 && from <= 0.5) {
            anim.stop();
            target.contentY = 0;
            return true;
        }
        if (dy < 0 && from >= maxY - 0.5) {
            anim.stop();
            target.contentY = maxY;
            return true;
        }
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
        return true;
    }

    function handleScrollKey(event) {
        if (w.pickerOpen)
            return sourcePicker.scrollKey(event.key);

        var target = w.detailOpen ? detailScroll : feedScroll;
        if (target === detailScroll && (w.threadBottomFollow || w.threadAutoScrolling))
            w.stopThreadBottomFollow();

        if (target === feedScroll)
            w.markFeedScrolling();
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
    function openContentLink(value, source, item) {
        var target = String(value || "");
        if (target.indexOf("profile:") === 0) {
            var handle = target.slice(8).replace(/^@/, "");
            w.openProfile({"handle": handle, "display_name": "@" + handle}, String(source || ""), item);
            return ;
        }
        w.openUrl(target, null, {});
    }

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
                w.fatal = Tr.fmt("Could not reach %1. Is the lucid-social repo in ~/src?", w.service);
                // Do not leave the card empty if stream discovery fails; the
                // feed request can still use the service-side defaults.
                if (w.booted && w.items.length === 0 && !w.preview && w.live)
                    Qt.callLater(function () { w.loadFeed(true, true); });
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
                w.fatal = Tr.fmt("Could not reach %1. Is the lucid-social repo in ~/src?", w.service);
            }
            if (code !== 0 && w.feedAppend)
                w.feedAtEnd = true;
            w.feedAppend = false;
            w.feedLoadingMore = false;
            if (w.pendingFeedText !== "") {
                // The deferred response will be applied when the scroll stops;
                // do not start another request on top of it.
                w.feedMorePending = false;
            } else if (w.feedDirty) {
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
            w.searchMoreLoading = false;
            w.searchPrefetching = false;
            if (code !== 0)
                w.searchServed = false;
            if (w.searchDirty) {
                w.searchDirty = false;
                w.searchMorePending = false;
                searchDebounce.restart();
            } else if (w.searchMorePending) {
                w.searchMorePending = false;
                Qt.callLater(w.loadMoreSearch);
            }
        }
    }

    Process {
        id: profileProc

        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: w.consumeProfile(this.text)
        }

        onExited: (code) => {
            w.profileBusy = false;
        }
    }

    Process {
        id: followProc

        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: w.consumeFollow(this.text)
        }

        onExited: (code) => {
            if (code !== 0)
                w.profileFollowBusy = false;
        }
    }

    Timer {
        id: threadRefreshTimer

        // Discord threads are live; other sources are polled more gently.
        interval: w.detailPost === null ? 30000
            : (w.detailPost.source === "discord" ? 9000
            : (w.detailPost.source === "twitter" ? 10000 : 30000))
        repeat: true
        running: w.detailOpen && w.live && !w.preview && !w.commentsLoading && !w.threadOpening
        onTriggered: {
            if (w.detailOpen && w.detailId !== "" && !w.commentsLoading && !w.threadOpening)
                w.loadThread(w.detailId, w.threadLimit, true);
        }
    }

    Timer {
        id: threadHoldRelease

        interval: 120
        onTriggered: w.threadHoldPosition = false
    }

    Timer {
        id: threadScrollSettle

        // The optimistic row (or the group it joins) can grow after the first
        // layout pass. Re-align once it has settled, unless the reader has
        // taken the viewport back in the meantime.
        interval: 80
        onTriggered: {
            var target = w.threadScrollTarget;
            w.threadScrollTarget = null;
            if (target && w.detailOpen && !detailScroll.moving && !detailScroll.flicking
                    && !detailWheel.running)
                w.scrollThreadToComment(target.id, 10, target.fallback, target.bottom, true);
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
                w.commentsError = Tr.t("Could not load this thread.");
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
                w.actionError = Tr.t("Could not delete that message.");
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
                likeProc.errorText = Tr.t("The source refused the like.");
            w.finishLike(code === 0 && likeProc.resultOk);
        })
    }

    Process {
        id: reactionProc

        property string targetId: ""
        property string targetKind: "post"
        property var revertReactions: []
        property bool resultOk: true
        property string errorText: ""
        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: w.consumeReaction(this.text)
        }

        onExited: (code) => Qt.callLater(function () {
            if (code !== 0 && reactionProc.errorText === "")
                reactionProc.errorText = Tr.t("The source refused the reaction.");
            w.finishReaction(code === 0 && reactionProc.resultOk);
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

    // One process per selected channel: multi-channel posts go out together
    // and each response merges into its own optimistic feed row.
    Component {
        id: sendJobComponent

        Process {
            id: sendJobProc

            property var job: null
            property string output: ""
            running: false
            command: []

            stdout: StdioCollector {
                onStreamFinished: sendJobProc.output = this.text
            }

            onExited: (code) => {
                var current = sendJobProc.job;
                sendJobProc.job = null;
                if (current)
                    w.completeSendJob(current, sendJobProc.output, code);
                sendJobProc.destroy();
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
                w.newPostError = Tr.t("Could not load the channel list.");
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


    Component {
        id: profileHeaderComponent

                Item {
                    id: profileHeader

                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: w.profileOpen ? Math.max(Theme.dp(260), profileTabsBar.y + profileTabsBar.height) : 0
                    visible: w.profileOpen
                    clip: true
                    z: 2

                    Rectangle {
                        id: profileBanner

                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: Theme.dp(136)
                        color: w.profileTint
                        clip: true

                        Image {
                            anchors.fill: parent
                            source: String((w.profileMeta || {}).banner_url || "")
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: true
                            visible: source !== ""
                        }

                        Rectangle {
                            anchors.fill: parent
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.18) }
                                GradientStop { position: 0.45; color: Qt.rgba(0, 0, 0, 0.0) }
                                GradientStop { position: 1.0; color: Theme.bgOpaque }
                            }
                        }

                    }



                    SocialAvatar {
                        id: profileAvatarFrame

                        anchors.left: parent.left
                        anchors.leftMargin: Theme.dp(16)
                        anchors.top: profileBanner.bottom
                        anchors.topMargin: -Theme.dp(38)
                        author: w.profileAuthor || ({})
                        source: w.profileSource
                        size: Theme.dp(78)
                        z: 3
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.dp(16)
                        anchors.top: profileBanner.bottom
                        anchors.topMargin: Theme.dp(12)
                        spacing: Theme.dp(8)
                        z: 3

                        Button {
                            visible: (w.profileMeta || {}).can_follow === true
                            enabled: !w.profileFollowBusy
                            variant: w.profileFollowing ? "outlined" : "filled"
                            size: "s"
                            text: w.profileFollowing ? Tr.t("Following") : Tr.t("Follow")
                            onClicked: w.toggleProfileFollow()
                        }

                        Button {
                            visible: (w.profileMeta || {}).can_message !== false
                            variant: "filled"
                            size: "s"
                            text: Tr.t("Message")
                            onClicked: w.startProfileMessage()
                        }

                    }

                    ColumnLayout {
                        id: profileInfo

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: profileAvatarFrame.bottom
                        anchors.leftMargin: Theme.dp(16)
                        anchors.rightMargin: Theme.dp(16)
                        anchors.topMargin: Theme.dp(7)
                        spacing: Theme.dp(1)

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.dp(7)

                            LText {
                                Layout.fillWidth: true
                                role: "titleLarge"
                                text: (w.profileMeta || {}).display_name || (w.profileAuthor || {}).display_name || (w.profileAuthor || {}).handle || Tr.t("Someone")
                                color: w.ink
                                elide: Text.ElideRight
                            }

                        }

                        LText {
                            Layout.fillWidth: true
                            role: "labelMedium"
                            text: {
                                var handle = String((w.profileMeta || {}).handle || (w.profileAuthor || {}).handle || "").replace(/^@/, "");
                                if (w.profileSource === "hackernews")
                                    return handle !== "" ? "u/" + handle : "";
                                if (w.profileSource === "youtube")
                                    return "youtube.com";
                                return handle !== "" ? "@" + handle : "";
                            }
                            color: w.inkDim
                            elide: Text.ElideRight
                        }

                        LText {
                            Layout.fillWidth: true
                            Layout.topMargin: Theme.dp(3)
                            visible: text !== ""
                            role: "bodyMedium"
                            text: String((w.profileMeta || {}).bio || "")
                            color: w.inkDim
                            wrapMode: Text.Wrap
                            maximumLineCount: 3
                            elide: Text.ElideRight
                        }

                        LText {
                            Layout.fillWidth: true
                            Layout.topMargin: Theme.dp(3)
                            visible: text !== ""
                            role: "labelSmall"
                            textFormat: Text.StyledText
                            text: {
                                var meta = w.profileMeta || {};
                                var parts = [];
                                if (meta.location)
                                    parts.push(String(meta.location));
                                if (meta.website) {
                                    var site = String(meta.website).replace(/^https?:\/\//, "").replace(/\/$/, "");
                                    parts.push('<a href="' + meta.website + '" style="color:' + Theme.primary + '">' + site + '</a>');
                                }
                                if (meta.joined)
                                    parts.push(String(meta.joined));
                                if (meta.pronouns)
                                    parts.push(String(meta.pronouns));
                                return parts.join(" · ");
                            }
                            color: w.inkFaint
                            onLinkActivated: (link) => w.openUrl(link, null, {})
                        }

                        Row {
                            Layout.topMargin: Theme.dp(5)
                            spacing: Theme.dp(14)

                            Row {
                                spacing: Theme.dp(4)
                                visible: w.compactCount(((w.profileMeta || {}).counts || {}).posts) !== ""

                                LText {
                                    role: "labelLarge"
                                    text: w.compactCount(((w.profileMeta || {}).counts || {}).posts)
                                    color: w.ink
                                }

                                LText {
                                    role: "labelSmall"
                                    text: Tr.t("posts")
                                    color: w.inkFaint
                                }

                            }

                            Row {
                                spacing: Theme.dp(4)
                                visible: w.compactCount(((w.profileMeta || {}).counts || {}).followers) !== ""

                                LText {
                                    role: "labelLarge"
                                    text: w.compactCount(((w.profileMeta || {}).counts || {}).followers)
                                    color: w.ink
                                }

                                LText {
                                    role: "labelSmall"
                                    text: Tr.t("followers")
                                    color: w.inkFaint
                                }

                            }

                            Row {
                                spacing: Theme.dp(4)
                                visible: w.compactCount(((w.profileMeta || {}).counts || {}).following) !== ""

                                LText {
                                    role: "labelLarge"
                                    text: w.compactCount(((w.profileMeta || {}).counts || {}).following)
                                    color: w.ink
                                }

                                LText {
                                    role: "labelSmall"
                                    text: Tr.t("following")
                                    color: w.inkFaint
                                }

                            }

                            Row {
                                spacing: Theme.dp(4)
                                visible: w.compactCount(((w.profileMeta || {}).counts || {}).karma) !== ""

                                LText {
                                    role: "labelLarge"
                                    text: w.compactCount(((w.profileMeta || {}).counts || {}).karma)
                                    color: w.ink
                                }

                                LText {
                                    role: "labelSmall"
                                    text: Tr.t("karma")
                                    color: w.inkFaint
                                }

                            }

                        }

                    }

                    Tabs {
                        id: profileTabsBar

                        focus: false
                        activeFocusOnTab: false
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: profileInfo.bottom
                        anchors.topMargin: Theme.dp(6)
                        height: w.profileTabOptions.length > 0 ? Theme.dp(46) : 0
                        visible: w.profileTabOptions.length > 0
                        options: w.profileTabOptions
                        current: w.profileTab
                        onPicked: (key) => w.selectProfileTab(key)
                    }

                }

    }

    // ------------------------------------------------------------------ header
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.dp(7)
        spacing: w.profileOpen ? 0 : Theme.dp(6)

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: w.profileOpen ? 0 : Theme.dp(36)
            visible: !w.profileOpen
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
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.typeSize("bodyMedium")
                    font.variableAxes: Theme.axes(Theme.typeSize("bodyMedium"), 420, 0)
                    verticalAlignment: TextInput.AlignVCenter
                    onTextEdited: {
                        if (w.newPostOpen) {
                            if (w.channelQuery !== text)
                                w.channelQuery = text;
                        } else if (w.detailOpen) {
                            if (w.threadSearchQuery !== text)
                                w.threadSearchQuery = text;
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
                        } else if (w.detailOpen) {
                            w.threadSearchQuery = "";
                            text = "";
                            w.endEdit();
                            focus = false;
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
                        text: w.newPostOpen ? Tr.t("Search channels…") : (w.detailOpen ? Tr.t("Search this thread…") : Tr.t("Search…"))
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
                        else if (w.detailOpen)
                            w.threadSearchQuery = "";
                        else
                            w.searchQuery = "";

                        searchInput.text = "";
                        searchInput.forceActiveFocus();
                    }
                }

            }

            IconButton {
                Layout.alignment: Qt.AlignVCenter
                icon: w.newPostOpen ? "close" : "send"
                size: "s"
                tooltip: w.newPostOpen ? Tr.t("Cancel New Post") : Tr.t("New Post")
                tintOverride: w.newPostOpen ? Theme.fgPrimary : w.inkDim
                onClicked: w.toggleNewPost()
            }

        }

        // Refresh failures stay quiet but available; the header says "stale".
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? Theme.dp(30) : 0
            radius: Theme.dp(10)
            color: Theme.surfaceHigh
            visible: !w.profileOpen && (w.actionError !== "" || w.feedErrors.length > 0)

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
                    text: w.actionError !== "" ? w.actionError : (w.feedErrors.length > 0 ? Tr.t(w.feedErrors[0].message || "A stream could not refresh") : "")
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

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.top: parent.top
                    anchors.topMargin: w.profileOpen ? -Theme.dp(7) : 0
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
                    anchors.leftMargin: w.profileOpen ? -Theme.dp(7) : 0
                    anchors.rightMargin: w.profileOpen ? -Theme.dp(7) : 0


                    model: ScriptModel {
                        id: feedModel

                        values: w.feedValues
                        // Feed objects are stable by id. Structure comparison
                        // is both expensive and needless here, and identity
                        // keeps the anchored delegate alive across refreshes.
                        objectProp: "id"
                        comparisonMode: ObjectComparison.Identity
                    }

                    footer: Item {
                        width: feedScroll.width
                        height: (w.feedLoadingMore || w.searchMoreLoading || w.searchPrefetching || w.searchMorePending) ? Theme.dp(44) : 0

                        LoadingIndicator {
                            anchors.centerIn: parent
                            width: Theme.dp(28)
                            height: width
                            visible: running
                            running: w.feedLoadingMore || w.searchMoreLoading || w.searchPrefetching || w.searchMorePending
                            color: Theme.primary
                        }

                    }

                    delegate: Item {
                        id: feedSlot

                        required property var modelData
                        readonly property bool profileHeaderRow: modelData.kind === "profile_header"

                        width: feedScroll.width
                        height: profileHeaderRow ? headerLoader.height : postCard.height

                        Loader {
                            id: headerLoader

                            active: feedSlot.profileHeaderRow
                            width: parent.width
                            height: item ? item.height : 0
                            sourceComponent: profileHeaderComponent
                            onHeightChanged: {
                                if (feedSlot.profileHeaderRow)
                                    w.profileHeaderHeight = height;
                            }
                        }

                        SocialPostCard {
                            id: postCard

                            visible: !feedSlot.profileHeaderRow
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: w.profileOpen ? Theme.dp(7) : 0
                            anchors.rightMargin: w.profileOpen ? Theme.dp(7) : 0
                            post: feedSlot.modelData
                            host: w
                            onActivated: w.openPost(feedSlot.modelData)
                            onLikeClicked: w.toggleLike(feedSlot.modelData)
                            onCommentsClicked: w.openPost(feedSlot.modelData)
                            onReplyClicked: w.openPost(feedSlot.modelData, true)
                            onExternalClicked: w.openExternal(feedSlot.modelData)
                            onDeleteClicked: w.deletePost(feedSlot.modelData)
                            onDismissed: w.hidePost(feedSlot.modelData.id)
                        }

                    }

                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: (event) => {
                            w.markFeedScrolling();
                            w.wheelBy(feedScroll, event, feedWheel);
                            event.accepted = true;
                        }
                    }

                    // Only a removed post gets a slide. Animated reordering
                    // made live feed bumps look like cards were pushed down
                    // under one another and left temporary holes.
                    removeDisplaced: Transition {
                        NumberAnimation {
                            properties: "y"
                            duration: Theme.durMedium
                            easing.type: Easing.Bezier
                            easing.bezierCurve: Theme.curveDefaultSpatial
                        }

                    }

                    // Never clamp contentY from a contentHeight change: the
                    // ListView revises its height estimate while delegates
                    // load, and clamping during a wheel gesture was what made
                    // the feed stop following the wheel.
                    onFlickStarted: w.markFeedScrolling()
                    onContentYChanged: w.maybeLoadMoreFeed()
                    onContentHeightChanged: Qt.callLater(w.maybeLoadMoreFeed)
                    onMovementEnded: w.maybeLoadMoreFeed()
                    onMovementStarted: w.markFeedScrolling()
                }

                LoadingIndicator {
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.dp(14)
                    anchors.top: parent.top
                    anchors.topMargin: Math.max(Theme.dp(8), w.profileHeaderHeight + Theme.dp(6))
                    width: Theme.dp(16)
                    height: width
                    z: 6
                    visible: running
                    running: w.profileOpen
                        && (w.searchLoading || w.searchMoreLoading || w.searchPrefetching || w.searchMorePending)
                    color: Theme.primary
                }

                Rectangle {
                    id: profileBack

                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.margins: Theme.dp(12)
                    width: Theme.dp(34)
                    height: width
                    radius: width / 2
                    color: Theme.alpha(Theme.scrim, 0.55)
                    visible: w.profileOpen
                    z: 20

                    Icon {
                        anchors.centerIn: parent
                        name: "arrow_back"
                        size: Theme.dp(18)
                        color: "#ffffff"
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: w.closeProfile()
                    }

                }

                // scroll affordance: a restrained material rail, not a full bar
                Rectangle {
                    anchors.right: parent.right
                    anchors.rightMargin: -Theme.dp(5)
                    width: Theme.dp(3)
                    radius: Theme.dp(2)
                    height: Math.max(Theme.dp(22), feedScroll.height * feedScroll.height / Math.max(1, feedScroll.contentHeight))
                    y: (feedScroll.height - height) * Math.max(0, Math.min(1, feedScroll.contentY / Math.max(1, feedScroll.contentHeight - feedScroll.height)))
                    color: w.ink
                    z: 5
                    visible: feedScroll.contentHeight > feedScroll.height + Theme.dp(4)
                }

                // loading / empty / error
                ColumnLayout {
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: w.profileOpen ? Math.min(w.profileHeaderHeight, parent.height) / 2 : 0
                    width: Math.min(parent.width - Theme.dp(24), Theme.dp(300))
                    spacing: Theme.dp(8)
                    opacity: w.shownItems.length === 0 ? 1 : 0
                    visible: opacity > 0.01

                    LoadingIndicator {
                        Layout.alignment: Qt.AlignHCenter
                        width: Theme.dp(40)
                        height: width
                        visible: running
                        running: w.initialLoading
                        color: Theme.primary
                    }

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.durMedium
                            easing.type: Easing.Bezier
                            easing.bezierCurve: Theme.curveDefaultSpatial
                        }

                    }

                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        width: Theme.dp(44)
                        height: Theme.dp(44)
                        radius: width / 2
                        color: Theme.surfaceHigh
                        visible: !w.initialLoading

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
                        text: w.fatal !== "" ? Tr.t("The feed is not reachable") : (w.phase === "loading" ? Tr.t("Gathering streams…") : (w.searchQuery !== "" && w.items.length > 0 ? Tr.t("No matching posts") : (w.items.length > 0 ? Tr.t("You're all caught up") : Tr.t("Nothing selected yet"))))
                        color: w.ink
                        wrapMode: Text.Wrap
                        visible: !w.initialLoading || w.fatal !== ""
                    }

                    LText {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        role: "bodySmall"
                        text: w.fatal !== "" ? w.fatal : (w.phase === "loading" ? Tr.t("The first fetch can take a few seconds.") : (w.searchQuery !== "" && w.items.length > 0 ? Tr.t("Try a shorter or earlier part of the words you remember.") : (w.items.length > 0 ? Tr.t("Swipe left or right on a post to hide it.") : Tr.t("Choose sources from the hub button, or add a source in ~/.config/lucid-social/config.toml."))))
                        color: w.inkFaint
                        wrapMode: Text.Wrap
                        visible: !w.initialLoading || w.fatal !== ""
                    }

                    Button {
                        Layout.alignment: Qt.AlignHCenter
                        visible: !w.initialLoading || w.fatal !== ""
                        variant: "tonal"
                        size: "xs"
                        icon: w.fatal !== "" ? "refresh" : "hub"
                        text: w.fatal !== "" ? Tr.t("Retry") : Tr.t("Choose sources")
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
                                antialiasing: true
                                // Offline is a hollow ring, so it reads as an
                                // absence rather than a dim "online" dot.
                                color: w.threadPresenceOffline
                                    ? "transparent"
                                    : w.presenceColor(w.threadPresence)
                                border.width: w.threadPresenceOffline ? Math.max(2, Theme.dp(2)) : 0
                                border.color: w.presenceColor(w.threadPresence)
                                visible: w.threadPresence !== ""
                            }

                            Item {
                                Layout.fillWidth: true
                            }

                        }

                    }

                    Flickable {
                        id: detailScroll

                        // Height before the latest content change, so the
                        // viewport can keep its distance from the bottom.
                        property real lastContentHeight: 0

                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentWidth: width
                        contentHeight: detailColumn.height
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        interactive: contentHeight > height
                        // Only an actual drag/flick takes the thread away from
                        // the bottom. movementStarted also fires for the
                        // programmatic bottom animation in this view.
                        onDragStarted: {
                            w.threadReloadOffset = -1;
                            w.threadReloadUntil = 0;
                            w.stopThreadBottomFollow();
                        }
                        onFlickStarted: {
                            w.threadReloadOffset = -1;
                            w.threadReloadUntil = 0;
                            w.stopThreadBottomFollow();
                        }
                        onContentYChanged: {
                            if (contentY + height >= contentHeight - Theme.dp(80))
                                w.maybeAutoLoadComments();

                            if (contentY <= 2 && w.contextReady && w.contextHasMore
                                && !w.contextLoading && w.detailPost !== null
                                && w.detailPost.source === "discord")
                                w.loadContext(w.contextCursor);

                        }
                        onContentHeightChanged: {
                            var previous = lastContentHeight;
                            var nextHeight = contentHeight;
                            lastContentHeight = nextHeight;
                            if (w.threadHoldPosition)
                                return ;
                            // At the top, never translate with a content-height
                            // change. Background refreshes and late image loads
                            // used to nudge an idle reader downward here.
                            if (!w.threadBottomFollow && contentY <= 1) {
                                if (contentY !== 0)
                                    contentY = 0;
                                w.maybeAutoLoadComments();
                                return ;
                            }
                            if (w.threadReloadOffset >= 0 && Date.now() < w.threadReloadUntil) {
                                // Only a reader near the bottom gets re-anchored
                                // to the bottom. Mid-thread refreshes must not
                                // move the viewport at all.
                                if (w.threadReloadOffset <= Theme.dp(120)) {
                                    var reloadTarget = Math.max(0, nextHeight - height - w.threadReloadOffset);
                                    if (Math.abs(reloadTarget - contentY) >= 1)
                                        contentY = reloadTarget;
                                }
                                w.maybeAutoLoadComments();
                                return ;
                            }
                            w.maybeAutoLoadComments();
                            if (w.threadBottomFollow && w.detailOpen) {
                                w.threadScrollToBottomNow();
                                return ;
                            }
                            if (previous > height + 1 && !moving && !flicking && !w.threadAutoScrolling) {
                                var offset = Math.max(0, previous - height - contentY);
                                if (w.contextAnchorPending) {
                                    // Older context inserted above: keep the
                                    // reading row instead of its bottom gap.
                                    var delta = nextHeight - w.contextAnchorHeight;
                                    if (delta > 0)
                                        contentY = Math.max(0, w.contextAnchorY + delta);
                                } else if (offset <= Theme.dp(120)) {
                                    // Near the bottom: keep the same distance
                                    // from it. A reader in the middle keeps the
                                    // absolute content position when media or a
                                    // background refresh changes the height.
                                    var target = Math.max(0, nextHeight - height - offset);
                                    if (Math.abs(target - contentY) >= 1)
                                        contentY = target;
                                }
                            }
                            w.contextAnchorPending = false;
                        }
                        onHeightChanged: {
                            if (w.threadBottomFollow && w.detailOpen)
                                w.threadScrollToBottomNow();
                        }

                        WheelHandler {
                            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                            onWheel: (event) => {
                                if (w.threadBottomFollow || w.threadAutoScrolling)
                                    w.stopThreadBottomFollow();
                                w.threadReloadOffset = -1;
                                w.threadReloadUntil = 0;
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
                                    text: Tr.t("Loading earlier messages…")
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
                                    text: {
                                        var empty = w.comments.length === 0 && w.threadLoaded && !w.commentsLoading && !w.threadOpening;
                                        if (empty)
                                            return w.commentsError !== "" ? w.commentsError : Tr.t("No comments yet. Start the thread.");
                                        var count = w.threadCommentTotal >= 0 ? w.threadCommentTotal : (w.detailPost && w.detailPost.comment_count !== null && w.detailPost.comment_count !== undefined ? w.detailPost.comment_count : w.comments.length);
                                        return count + Tr.n(" comment", " comments", count);
                                    }
                                    color: w.commentsError !== "" && w.comments.length === 0 ? Theme.error : w.ink
                                }

                                LoadingIndicator {
                                    Layout.alignment: Qt.AlignVCenter
                                    Layout.rightMargin: Theme.dp(10)
                                    Layout.preferredWidth: Theme.dp(13)
                                    Layout.preferredHeight: Theme.dp(13)
                                    width: Theme.dp(13)
                                    height: width
                                    visible: w.commentsLoading && w.comments.length === 0
                                    running: w.commentsLoading && w.comments.length === 0
                                    color: Theme.primary
                                }

                                IconButton {
                                    Layout.alignment: Qt.AlignVCenter
                                    Layout.rightMargin: Theme.dp(8)
                                    visible: w.commentsError !== "" && w.comments.length === 0 && !w.commentsLoading
                                    icon: "refresh"
                                    size: "xs"
                                    tooltip: Tr.t("Retry")
                                    onClicked: w.loadThread(w.detailId)
                                }

                            }



                            Repeater {
                                id: commentRepeater

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
                                            text: Tr.fmt(Tr.n("Show %1 reply", "Show %1 replies", commentSlot.modelData.hidden), commentSlot.modelData.hidden)
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



                            Item {
                                width: detailColumn.width
                                height: Theme.dp(8)
                            }

                        }

                    }

                    LText {
                        Layout.fillWidth: true
                        visible: w.typingLabel !== ""
                        role: "labelSmall"
                        text: w.typingLabel
                        color: Theme.subtext
                        elide: Text.ElideRight
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
                        placeholder: Tr.t("Reply...")
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
                            tooltip: Tr.t("Cancel New Post")
                            onClicked: w.closeNewPost()
                        }

                        LText {
                            Layout.fillWidth: true
                            role: "titleMedium"
                            text: Tr.t("New Post")
                            color: w.ink
                        }

                    }

                    LText {
                        Layout.fillWidth: true
                        Layout.leftMargin: Theme.dp(38)
                        role: "labelSmall"
                        text: w.sendTargetTitle + (w.selectedSendTargets.length > 1
                            ? " +" + (w.selectedSendTargets.length - 1)
                            : "")
                        color: w.inkFaint
                        visible: text !== ""
                        elide: Text.ElideRight
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
                            readonly property bool selected: w.sendTargetSelected(modelData)
                            readonly property bool cursor: w.sendTargetKey(modelData) === w.sendCursorKey

                            width: targetList.width
                            height: Theme.dp(46)
                            radius: Theme.rad(10)
                            border.width: cursor && !selected ? 1 : 0
                            border.color: Theme.outline
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
                                onClicked: w.toggleSendTarget(targetRow.modelData, false)
                            }

                        }

                    }

                    LText {
                        Layout.fillWidth: true
                        visible: w.sendTargetsLoading
                        role: "bodySmall"
                        text: Tr.t("Loading channels…")
                        color: w.inkFaint
                    }

                    LText {
                        Layout.fillWidth: true
                        visible: w.shownSendTargets.length === 0 && !w.sendTargetsLoading
                        role: "bodySmall"
                        text: w.newPostError !== "" ? w.newPostError : (w.channelQuery !== "" ? Tr.t("No matching channels.") : Tr.t("No channels available."))
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
                        busy: w.sending || w.selectedSendTargets.length === 0
                        placeholder: Tr.t("Write a post...")
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
                onStartOAuth: (sourceId) => w.startOAuth(sourceId)
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

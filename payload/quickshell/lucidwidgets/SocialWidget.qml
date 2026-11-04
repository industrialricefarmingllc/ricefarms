import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs
import qs.lucidui
import "../squircle"
import "social"

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
    readonly property int feedLimit: 32

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
    property bool pickerOpen: false
    property string detailId: ""
    property var detailPost: null
    property var comments: []
    property bool commentsLoading: false
    property string commentsError: ""
    property int threadLimit: 20
    property bool nestedFilled: false
    property var collapsedComments: ({})
    readonly property var commentView: w.buildCommentView()
    property string replyTo: ""
    property string replyName: ""
    property bool posting: false
    property string composeError: ""
    property string authBusyKey: ""
    property string authError: ""
    property string authStatus: ""
    property var seenPostIds: ({})
    property int threadSeq: 0
    property int feedSeq: 0
    property int clockTick: 0

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

            seen[item.id] = true;
            out.push(item);
        }
        // The service already merges by time; doing it again here keeps the
        // card correct if a source ever returns streams in a different order.
        out.sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at));
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
        w.loadFeed(false);
    }

    Component.onCompleted: w.boot()
    onLiveChanged: {
        if (w.live)
            w.boot();

    }
    onPreviewChanged: {
        if (w.preview) {
            w.booted = true;
            w.phase = "ready";
        }
    }

    Timer {
        interval: 60000
        repeat: true
        running: true
        onTriggered: w.clockTick++
    }

    Timer {
        interval: 60000
        repeat: true
        running: w.live && !w.preview
        onTriggered: w.loadFeed(true)
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

    function loadFeed(refresh) {
        if (w.preview || !w.live || w.service === "")
            return ;

        if (feedProc.running) {
            w.feedDirty = true;
            return ;
        }

        var args = [w.service, "feed", "--json", "--limit", String(w.feedLimit), "--widget", w.uid];
        if (refresh)
            args.push("--refresh");

        for (var i = 0; i < w.offSources.length; i++)
            args.push("--exclude-source", w.offSources[i]);
        for (var j = 0; j < w.offStreams.length; j++)
            args.push("--exclude-stream", w.offStreams[j]);
        for (var k = 0; k < w.onStreams.length; k++)
            args.push("--include-stream", w.onStreams[k]);
        w.refreshing = true;
        w.phase = w.items.length > 0 ? w.phase : "loading";
        feedProc.command = args;
        feedProc.running = true;
    }

    function consumeFeed(text) {
        w.refreshing = false;
        try {
            var value = JSON.parse(text);
            if (value.schema !== w.schemaFeed || value.schema_version !== w.schemaVersion)
                throw new Error("unexpected feed schema");

            w.items = value.items || [];
            w.feedErrors = value.errors || [];
            w.fatal = "";
            w.actionError = "";
            w.phase = w.items.length > 0 ? "ready" : "empty";
            if (w.detailOpen)
                w.syncDetail();

        } catch (error) {
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

    // Turn the flat, parent-linked comment list into the nested order Twitter
    // uses. The service still stores the canonical flat chain; this is view
    // state only, including per-branch collapse.
    function buildCommentView() {
        var byId = {};
        var children = {};
        var i;
        for (i = 0; i < w.comments.length; i++) {
            var item = w.comments[i];
            byId[item.id] = item;
        }
        for (i = 0; i < w.comments.length; i++) {
            var value = w.comments[i];
            var parent = value.parent_id && byId[value.parent_id] ? value.parent_id : "";
            if (!children[parent])
                children[parent] = [];
            children[parent].push(value);
        }
        for (var key in children) {
            children[key].sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at));
        }
        var out = [];
        var visited = {};
        function walk(parent, depth) {
            var list = children[parent] || [];
            for (var j = 0; j < list.length; j++) {
                var comment = list[j];
                if (visited[comment.id])
                    continue;
                visited[comment.id] = true;
                var kids = children[comment.id] || [];
                var parentValue = byId[comment.parent_id];
                out.push({
                    "comment": comment,
                    "depth": Math.min(4, depth),
                    "hasChildren": kids.length > 0,
                    "childCount": kids.length,
                    "collapsed": w.collapsedComments[comment.id] === true,
                    "parentName": parentValue ? ((parentValue.author || {}).display_name || (parentValue.author || {}).handle || "") : ""
                });
                if (w.collapsedComments[comment.id] !== true)
                    walk(comment.id, depth + 1);
            }
        }
        walk("", 0);
        return out;
    }

    function toggleCollapsed(id) {
        var next = Object.assign({}, w.collapsedComments);
        if (next[id] === true)
            delete next[id];
        else
            next[id] = true;
        w.collapsedComments = next;
    }

    function hasNestedComments() {
        for (var i = 0; i < w.comments.length; i++) {
            if (Number(w.comments[i].depth || 0) > 0)
                return true;
        }
        return false;
    }

    function maybeAutoLoadComments() {
        if (!w.detailOpen || w.commentsLoading || w.hasNestedComments() || !w.canLoadMoreComments())
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

    function loadThread(id, limit) {
        w.threadSeq++;
        var seq = w.threadSeq;
        w.threadLimit = limit || w.threadLimit || 20;
        w.commentsLoading = true;
        w.commentsError = "";
        threadProc.command = [w.service, "thread", "--json", "--item", id, "--limit", String(w.threadLimit)];
        threadProc.running = true;
        w.pendingThreadSeq = seq;
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

            w.comments = value.comments || [];
            if ((value.errors || []).length > 0)
                w.commentsError = value.errors[0].message || "comments could not refresh";

            // A nested chain is not infinite-scrolled: fill it to the source
            // limit once, then let branch collapse/expand do the controlling.
            if (!w.nestedFilled && w.hasNestedComments() && w.threadLimit < 60 && w.canLoadMoreComments()) {
                w.nestedFilled = true;
                w.loadThread(w.detailId, 60);
                return ;
            }

        } catch (error) {
            if (w.pendingThreadSeq === w.threadSeq)
                w.commentsError = "Could not read this thread.";

        }
    }

    property int pendingThreadSeq: 0

    function openPost(post) {
        if (!post || !post.id)
            return ;

        w.pickerOpen = false;
        w.detailId = post.id;
        w.detailPost = post;
        w.comments = post.comments_preview || [];
        w.threadLimit = 20;
        w.nestedFilled = false;
        w.collapsedComments = ({});
        w.replyTo = "";
        w.replyName = "";
        w.composeError = "";
        w.actionError = "";
        detailScroll.contentY = 0;
        w.loadThread(post.id, 20);
    }

    function closeDetail() {
        w.detailId = "";
        w.detailPost = null;
        w.comments = [];
        w.commentsLoading = false;
        w.commentsError = "";
        w.nestedFilled = false;
        w.collapsedComments = ({});
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
        w.setOpt("socialHidden", next);
        var remaining = w.items.filter((item) => item.id !== id);
        w.items = remaining;
        if (w.detailId === id)
            w.closeDetail();
    }

    function toggleSource(id) {
        var next = w.offSources.slice();
        var index = next.indexOf(id);
        if (index >= 0)
            next.splice(index, 1);
        else
            next.push(id);

        w.setOpt("socialSourcesOff", next);
        Qt.callLater(w.loadFeed, false);
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

    function toggleLike(post) {
        if (!post || !(post.capabilities || {}).like || likeProc.running)
            return ;

        var next = post.liked !== true;
        var stats = Object.assign({}, post.stats || {});
        if (stats.likes !== null && stats.likes !== undefined)
            stats.likes = Math.max(0, Number(stats.likes) + (next ? 1 : -1));

        w.patchPost(post.id, {"liked": next, "stats": stats});
        likeProc.targetId = post.id;
        likeProc.targetKind = "post";
        likeProc.revertTo = post.liked === true;
        likeProc.revertStats = post.stats || ({});
        likeProc.command = [w.service, "like", "--json", "--item", post.id, next ? "--on" : "--off"];
        likeProc.running = true;
    }

    function toggleCommentLike(comment) {
        if (!comment || !(comment.capabilities || {}).like || likeProc.running)
            return ;

        var next = comment.liked !== true;
        var stats = Object.assign({}, comment.stats || {});
        if (stats.likes !== null && stats.likes !== undefined)
            stats.likes = Math.max(0, Number(stats.likes) + (next ? 1 : -1));

        w.patchComment(comment.id, {"liked": next, "stats": stats});
        likeProc.targetId = comment.id;
        likeProc.targetKind = "comment";
        likeProc.revertTo = comment.liked === true;
        likeProc.revertStats = comment.stats || ({});
        likeProc.command = [w.service, "like", "--json", "--item", comment.id, next ? "--on" : "--off"];
        likeProc.running = true;
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
            if (value.ok !== true)
                w.revertLike();

        } catch (error) {
            w.revertLike();
        }
    }

    function startReply(comment) {
        w.replyTo = comment.id || "";
        w.replyName = (comment.author || {}).display_name || (comment.author || {}).handle || "this comment";
        composer.focus();
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
            w.loadFeed(true);
        } catch (error) {
            w.authError = "The credential service returned an unexpected payload.";
        }
    }

    function postComment(body) {
        body = String(body || "").trim();
        if (body === "" || w.posting)
            return ;

        w.posting = true;
        w.composeError = "";
        var args = [w.service, "comment", "--json", "--item", w.detailId, "--body", body];
        if (w.replyTo !== "")
            args.push("--reply-to", w.replyTo);
        commentProc.command = args;
        commentProc.running = true;
    }

    function consumeComment(text) {
        w.posting = false;
        try {
            var value = JSON.parse(text);
            if (value.ok !== true) {
                w.composeError = value.error || "Comment was not accepted.";
                return ;
            }
            var comment = value.comment;
            if (comment) {
                var next = w.comments.slice();
                var found = false;
                for (var i = 0; i < next.length; i++) {
                    if (next[i].id === comment.id) {
                        next[i] = comment;
                        found = true;
                    }
                }
                if (!found)
                    next.push(comment);
                w.comments = next;
                if (w.detailPost) {
                    var count = Number(w.detailPost.comment_count || 0) + 1;
                    w.detailPost = Object.assign({}, w.detailPost, {"comment_count": count});
                }
            }
            composer.clear();
            w.replyTo = "";
            w.replyName = "";
            if (value.pending === true)
                w.actionError = "Queued for the comment relay";

        } catch (error) {
            w.composeError = "The comment service returned an unexpected payload.";
        }
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
        var base = anim.running ? Number(anim.to) : from;
        var to = Math.max(0, Math.min(maxY, base - dy * 3));
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

    function openExternal(post) {
        if (!post || !post.url)
            return ;

        if (post.source === "discord") {
            if (openProc.running)
                return ;

            openProc.fallbackUrl = post.url;
            openProc.command = [w.service, "open", "--json", "--item", post.id];
            openProc.running = true;
            return ;
        }
        Qt.openUrlExternally(post.url);
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
            if (w.feedDirty) {
                w.feedDirty = false;
                Qt.callLater(w.loadFeed, false);
            }
        }
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
        id: likeProc

        property string targetId: ""
        property string targetKind: "post"
        property bool revertTo: false
        property var revertStats: ({})
        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: w.consumeLike(this.text)
        }

        onExited: (code) => {
            if (code !== 0) {
                w.revertLike();
                w.actionError = "The source refused the like.";
            }
        }
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
        running: false
        command: []

        onExited: (code) => {
            if (code !== 0 && openProc.fallbackUrl !== "")
                Qt.openUrlExternally(openProc.fallbackUrl);

            openProc.fallbackUrl = "";
        }
    }

    Process {
        id: commentProc

        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: w.consumeComment(this.text)
        }

        onExited: (code) => {
            if (code !== 0) {
                w.posting = false;
                w.composeError = "Could not reach the comment service.";
            }
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

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                LText {
                    Layout.fillWidth: true
                    role: "titleMedium"
                    text: "Social"
                    color: w.ink
                }

                LText {
                    Layout.fillWidth: true
                    role: "labelSmall"
                    text: w.statusLine
                    color: w.fatal !== "" ? Theme.error : (w.feedErrors.length > 0 || w.actionError !== "" ? Theme.tertiary : w.inkFaint)
                    elide: Text.ElideRight
                }

            }

            Item {
                Layout.preferredWidth: Theme.dp(30)
                Layout.preferredHeight: Theme.dp(30)
                visible: w.refreshing

                LoadingIndicator {
                    anchors.fill: parent
                    running: w.refreshing
                    color: Theme.primary
                }

            }

            IconButton {
                visible: !w.refreshing
                icon: "refresh"
                size: "xs"
                tintOverride: w.inkDim
                onClicked: w.refresh()
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
                    }

                    delegate: SocialPostCard {
                        required property var modelData

                        width: feedScroll.width
                        post: modelData
                        host: w
                        onActivated: w.openPost(modelData)
                        onLikeClicked: w.toggleLike(modelData)
                        onCommentsClicked: w.openPost(modelData)
                        onExternalClicked: w.openExternal(modelData)
                        onDismissed: w.hidePost(modelData.id)
                    }

                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: (event) => {
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
                        if (contentY > maxY)
                            contentY = maxY;
                        else if (contentY < 0)
                            contentY = 0;

                    }

                    onContentHeightChanged: Qt.callLater(clampToContent)
                    onCountChanged: {
                        feedWheel.stop();
                        Qt.callLater(clampToContent);
                    }
                    onMovementEnded: clampToContent()
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
                            name: w.fatal !== "" ? "warning" : "hub"
                            size: Theme.dp(22)
                            color: w.fatal !== "" ? Theme.error : w.inkDim
                        }

                    }

                    LText {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        role: "titleSmall"
                        text: w.fatal !== "" ? "The feed is not reachable" : (w.phase === "loading" ? "Gathering streams…" : (w.items.length > 0 ? "You're all caught up" : "Nothing selected yet"))
                        color: w.ink
                        wrapMode: Text.Wrap
                        visible: w.phase !== "loading" || w.preview || w.fatal !== ""
                    }

                    LText {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        role: "bodySmall"
                        text: w.fatal !== "" ? w.fatal : (w.phase === "loading" ? "The first fetch can take a few seconds." : (w.items.length > 0 ? "Swipe left or right on a post to hide it." : "Choose sources from the hub button, or add a source in ~/.config/lucid-social/config.toml."))
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

                        LText {
                            Layout.fillWidth: true
                            role: "titleMedium"
                            text: "Thread"
                            color: w.ink
                        }

                        Chip {
                            visible: w.detailPost !== null && String(w.detailPost.url || "") !== ""
                            kind: "assist"
                            text: "Open"
                            icon: "open_in_new"
                            onClicked: w.openPostUrl()
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
                        interactive: contentHeight > height
                        onContentYChanged: {
                            if (contentY + height >= contentHeight - Theme.dp(80))
                                w.maybeAutoLoadComments();

                        }
                        onContentHeightChanged: w.maybeAutoLoadComments()

                        WheelHandler {
                            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                            onWheel: (event) => {
                                w.wheelBy(detailScroll, event, detailWheel);
                                event.accepted = true;
                            }
                        }

                        Column {
                            id: detailColumn

                            width: detailScroll.width
                            spacing: 0

                            SocialPostCard {
                                width: detailColumn.width
                                post: w.detailPost || ({})
                                host: w
                                detail: true
                                onActivated: {}
                                onLikeClicked: w.toggleLike(w.detailPost)
                                onCommentsClicked: {}
                                onExternalClicked: w.openPostUrl()
                            }

                            Rectangle {
                                width: detailColumn.width
                                height: 1
                                color: Theme.alpha(w.ink, 0.1)
                            }

                            RowLayout {
                                width: detailColumn.width
                                height: Theme.dp(38)
                                spacing: Theme.dp(6)

                                LText {
                                    Layout.leftMargin: Theme.dp(14)
                                    Layout.fillWidth: true
                                    role: "labelLarge"
                                    text: (w.detailPost && w.detailPost.comment_count !== null && w.detailPost.comment_count !== undefined ? w.detailPost.comment_count : w.comments.length) + " comments"
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

                                SocialCommentRow {
                                    required property var modelData

                                    comment: modelData.comment
                                    depth: modelData.depth
                                    hasChildren: modelData.hasChildren
                                    childCount: modelData.childCount
                                    collapsed: modelData.collapsed
                                    parentName: modelData.parentName
                                    host: w
                                    onReplyRequested: w.startReply(modelData.comment)
                                    onLikeClicked: w.toggleCommentLike(modelData.comment)
                                    onCollapseToggled: w.toggleCollapsed(modelData.comment.id)
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
                        replyName: w.replyName
                        busy: w.posting
                        placeholder: w.detailPost !== null && (w.detailPost.capabilities || {}).comment === true ? "Add a comment…" : "Queue a local comment…"
                        onSend: (body) => w.postComment(body)
                        onCancelReply: w.cancelReply()
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

}

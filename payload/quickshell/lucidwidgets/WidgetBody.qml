import QtQuick
import qs

Item {
    id: body

    // set by the frame once the loader is ready
    property var host: null
    // a variant that draws straight onto the wallpaper with no container behind it
    property bool bare: false
    // a body with nothing worth showing right now: the frame fades the whole card
    // out and it drops out of the input mask, so it stops catching clicks too
    property bool hidden: false
    // the card drawn as a full pill rather than a rounded rectangle
    property bool pill: false

    // Open a link with the launch placeholder growing out of `item`, the
    // element that was pressed. `board` is the full-output widget deck, so
    // its coordinates plus the screen origin are screen coordinates.
    function openExternalUrl(url, item, opts) {
        if (!url)
            return false;

        opts = opts || {};
        var board = body.host ? body.host.board : null;
        var screenName = board ? String(board.screenName || "") : (body.host ? String(body.host.screenName || "") : "");
        var screen = Widgets.screenNamed(screenName);
        if (!screen && Quickshell.screens.length > 0)
            screen = Quickshell.screens[0];

        var rect = null;
        if (item && board && screen) {
            var p = item.mapToItem(board, 0, 0);
            rect = {
                "x": screen.x + p.x,
                "y": screen.y + p.y,
                "width": Math.max(1, item.width),
                "height": Math.max(1, item.height)
            };
        }

        return Launch.openUrl(url, {
            "command": opts.command || "",
            "title": opts.title || "Browser",
            "icon": opts.icon || "web-browser",
            "rect": rect,
            "screen": screen,
            "wmClass": opts.wmClass || "",
            "wmClasses": opts.wmClasses || [],
            "timeoutMs": opts.timeoutMs > 0 ? opts.timeoutMs : 2500
        });
    }

    readonly property string variant: body.host ? body.host.wvariant : ""
    readonly property string uid: body.host ? body.host.uid : ""
    readonly property bool hovered: body.host ? body.host.hovered : false
    // true inside a settings gallery tile: no polling, no network, sample content
    readonly property bool preview: body.host ? body.host.preview === true : false
    // True on the output the shell treats as its main one. Widgets can be
    // placed "everywhere"; high-frequency animations and polling should only
    // run once, on the main output, instead of once per monitor.
    readonly property bool primaryScreen: body.host && body.host.board
        ? body.host.board.isPrimary === true : true
    // true only for a card just placed, not one restored from disk
    readonly property bool born: body.host ? body.host.born === true : false
    // true while a grip is held, for bodies that would rather not rebuild mid-drag
    readonly property bool resizing: body.host ? body.host.resizing === true : false
    readonly property real pad: Theme.dp(20)
    readonly property real corner: body.host ? body.host.bodyRadius : Theme.windowRadius
    readonly property bool editing: body.uid !== "" && Widgets.editUid === body.uid
    // the card's m3 container, and the ink that reads on it. "auto" is the
    // widget's own default: the ones that are mostly one big reading go tonal
    property string defaultTone: "surface"
    readonly property string tone: {
        var t = body.opt("tone");
        return (t === undefined || t === "auto" || t === "") ? body.defaultTone : t;
    }
    readonly property bool tonal: body.tone !== "surface"
    readonly property color toneFill: {
        switch (body.tone) {
        case "primary":
            return Theme.withBlur(Theme.primaryContainer);
        case "secondary":
            return Theme.withBlur(Theme.secondaryContainer);
        case "tertiary":
            return Theme.withBlur(Theme.tertiaryContainer);
        }
        return Theme.bg;
    }
    readonly property color toneInk: {
        switch (body.tone) {
        case "primary":
            return Theme.fgPrimaryContainer;
        case "secondary":
            return Theme.fgSecondaryContainer;
        case "tertiary":
            return Theme.fgTertiaryContainer;
        }
        return Theme.text;
    }
    readonly property color toneInkAccent: {
        switch (body.tone) {
        case "primary":
            return Theme.primary;
        case "secondary":
            return Theme.secondary;
        case "tertiary":
            return Theme.tertiary;
        }
        return Theme.accent;
    }
    // what sits on an inkAccent fill
    readonly property color toneOnInkAccent: {
        switch (body.tone) {
        case "primary":
            return Theme.fgPrimary;
        case "secondary":
            return Theme.fgSecondary;
        case "tertiary":
            return Theme.fgTertiary;
        }
        return Theme.fgAccent;
    }
    // every output keeps its own copy of each card, visible only on the one it
    // belongs to. a body that polls, notifies or writes on its own should only do
    // it from that copy, or two monitors would do everything twice
    readonly property bool live: body.host !== null && !body.preview && body.host.onThisScreen === true

    function beginEdit() {
        Widgets.editUid = body.uid;
    }

    function endEdit() {
        if (Widgets.editUid === body.uid)
            Widgets.editUid = "";

    }

    function opt(key) {
        return body.host ? body.host.opt(key) : undefined;
    }

    function setOpt(key, value) {
        if (body.host)
            body.host.setOpt(key, value);

    }

    // several keys in one write, so bindings never see half of a change
    function setOpts(changes) {
        if (body.host)
            body.host.setOpts(changes);

    }

    function pct(v) {
        return Math.round(Math.max(0, Math.min(100, v))) + "%";
    }

    // what the card and its contents are drawn in. a body can bind its own over
    // these, the way the media card follows its cover
    property color fill: body.toneFill
    property color ink: body.toneInk
    property color inkAccent: body.toneInkAccent
    property color fgInkAccent: body.toneOnInkAccent
    property bool ownInk: false
    readonly property color inkDim: body.tonal || body.ownInk ? Theme.alpha(body.ink, 0.78) : Theme.subtext
    readonly property color inkFaint: body.tonal || body.ownInk ? Theme.alpha(body.ink, 0.56) : Theme.subtextDim

}

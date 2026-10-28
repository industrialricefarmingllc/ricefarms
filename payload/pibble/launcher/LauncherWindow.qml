import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "root:/config"
import "root:/launcher/Settings"
import "root:/services"

// The launcher surface itself: the wlr-layer-shell window, the open/close
// reveal, the hidden field that captures all typing, and the handful of actions
// that need a child process (launching an app, running the wallpaper command,
// decoding a clip).
//
// Everything the panes *read* lives in LauncherState; this holds only what
// genuinely needs an item tree or a Process.
PanelWindow {
    id: root

    property bool shown: false
    // With Settings.preload on, mapped for the life of the daemon rather than
    // just while open. Unmapping makes Qt drop this window's scene graph and
    // every texture in it, so the next open has to rebuild the lot on the GUI
    // thread before it can draw a frame - which is exactly the stall that ate
    // the start of the reveal. Measured per open, after a throwaway open so the
    // one-time build isn't counted:
    //
    //                      unmapped on close        kept mapped
    //   compositor blur    72-102ms, 2 stalls       0ms (one 36ms outlier)
    //   xray blur          159-170ms, 1 stall       0ms, plus a 41-65ms
    //                                               close stall on ~half
    //
    // Identical on all four panes; the pane only decides how much there is to
    // rebuild, not whether the rebuild happens.
    //
    // What it holds is the whole window, every pane at once - the panes are
    // direct children, never Loaders, so their item trees always existed; what
    // survives a close is their scene-graph nodes and, mostly, their GPU
    // textures. That is not free, and the bill is in VRAM rather than RSS:
    // measured with nvidia-smi against this process, closed, having visited all
    // four panes, 823MiB against 341MiB when the surface unmaps instead, plus
    // ~66MiB of RSS. Roughly 240MiB of the gap is there from daemon start before
    // any pane is opened, which is the surface's own full-screen buffers and the
    // 5120x2160 growMask layer.
    //
    // That ~482MiB is what Settings.preload buys back when it's off, at the cost
    // of the stall above on every single open.
    //
    // Assigned false for one beat by syncScreen(), which is the only other thing
    // that unmaps this - see there for why a monitor switch has to, and note it
    // has to restore this as a *binding*, not a plain true.
    visible: Settings.preload || root.shown
    // Mapped but closed: the surface exists only to hold its own scene graph,
    // so it has to behave as if it were not there at all - see the
    // keyboardFocus, mask and content bindings that read this.
    readonly property bool surfaceIdle: !root.shown

    // LauncherState and Wallpapers both need to know whether the launcher is
    // up: panes gate live decoding on it, and a wallpaper applied while it's
    // open must not swap the xray backdrop out mid-animation.
    onShownChanged: {
        LauncherState.shown = root.shown;
        Wallpapers.launcherShown = root.shown;
        Wallpapers.syncXrayShown();
        // While the surface stays mapped, backingWindowVisible is already true
        // and never changes again, so the reveal has to be kicked off here
        // instead. A no-op the rest of the time: on the unmapped path the
        // window has not mapped yet at this point, so startReveal() bails on
        // its own backingWindowVisible guard and the map fires it as before.
        if (root.shown) {
            root.startReveal();
        } else {
            // arm the flush that gets this close's surface state committed (see
            // idleFlushTicks)
            root.idleFlushTicks = 0;
            root.syncScreen(); // a monitor switch while it was open, deferred to here
        }
    }
    // Which output the launcher maps onto: pinned to primaryScreen (DP-1)
    // rather than the focused output (see primaryScreen above).
    //
    // Only ever changed while the launcher is down. A layer surface's output is
    // fixed when it's created, so moving output destroys and remaps the window
    // - the same teardown the `visible: true` note above is about, and mid-open
    // it would be a visible one. A focus change while the launcher is up is
    // therefore picked up on the next close, and the open it would have
    // interrupted plays out on the output it started on.
    //
    // Never assigned directly for the same reason; syncScreen() is what moves
    // it, and it moves in two steps.
    screen: root.mappedScreen
    // Seeded as a binding so the very first map already lands on the right
    // output; syncScreen() replaces it with a plain value from then on, and is
    // called once at startup (before anything can open) so the binding can't
    // outlive the first real open.
    // Pinned to the primary output (DP-1): upstream follows focus across
    // monitors, but here the launcher lives on primary always.
    readonly property var primaryScreen: {
        for (let i = 0; i < Quickshell.screens.length; i++) {
            const mon = Hyprland.monitorFor(Quickshell.screens[i]);
            if (mon && mon.name === "DP-1")
                return Quickshell.screens[i];
        }
        return ActiveOutput.screen;
    }
    property var mappedScreen: root.primaryScreen
    function syncScreen(): void {
        if (root.shown || !root.primaryScreen)
            return;
        if (root.mappedScreen === root.primaryScreen) {
            // Already there, so nothing to remap - but the assignment still
            // has to happen, since a plain assignment is what drops the seed
            // binding whether or not the value changes, and the startup call
            // is here for exactly that.
            root.mappedScreen = root.primaryScreen;
            return;
        }
        // Unmapped first, and the new output taken on a later tick, rather than
        // assigned straight over the top. Assigning `screen` alone builds the
        // new wl_surface *before* it tears the old one down, and the two
        // overlapping is what loses compositor blur across a monitor switch:
        // Quickshell's BackgroundEffect holds one ext_background_effect_surface
        // per attached window and only makes a new one when it is holding none,
        // so on the overlap it either keeps the one bound to the dying surface
        // (no protocol object for the new one, ever) or makes one and then has
        // the old surface's teardown destroy it. Either way the region requests
        // land nowhere and the launcher opens unblurred until the daemon is
        // restarted. Unmapping first means the old surface is gone - and the
        // effect object with it - before the new one exists, which is the case
        // Quickshell does handle.
        //
        // The scene graph this drops is the same one the `screen` assignment
        // would have dropped anyway (a new surface means a new backing window
        // either way), so it costs a rebuild that was already being paid, off
        // screen, with the launcher closed.
        root.visible = false;
        remap.restart();
    }
    // The gap the unmap needs: Qt destroys the wl_surface off the event loop,
    // not inside setVisible, so the new output has to be taken after that has
    // had a chance to run. Any interval does, since it only has to be a later
    // tick - kept short because the window is unmapped for the whole of it.
    Timer {
        id: remap
        interval: 16
        onTriggered: root.finishRemap()
    }
    function finishRemap(): void {
        root.mappedScreen = root.primaryScreen;
        // Restored as a binding, not a plain `true`: `visible` tracks
        // Settings.preload, and a bare assignment here would sever that for the
        // rest of the session - the surface would then stay mapped even after
        // preload was switched off, silently making the setting a no-op for
        // anyone who had ever changed monitors.
        root.visible = Qt.binding(() => Settings.preload || root.shown);
    }
    // An open() landing inside that gap must not open onto an unmapped window,
    // so it takes the pending remap immediately instead of waiting out the
    // timer. A no-op the rest of the time, when there is no remap in flight.
    function flushRemap(): void {
        if (!remap.running)
            return;
        remap.stop();
        root.finishRemap();
    }
    Connections {
        target: ActiveOutput

        function onScreenChanged(): void {
            root.syncScreen();
        }
    }

    // Keeps the xray bake keyed on the output the launcher actually mapped
    // onto; Wallpapers falls back to the primary screen until this resolves.
    onScreenChanged: if (root.screen)
        Wallpapers.screen = root.screen

    // The reveal circle is a client-side mask over this window's own content
    // (see growMask below), so it renders identically on every compositor. Only
    // the screen it is measured against is this window's business - the
    // geometry derived from it lives on LauncherState, which the panes read.
    Binding {
        target: LauncherState
        property: "screenWidth"
        value: root.screen ? root.screen.width : 0
    }
    Binding {
        target: LauncherState
        property: "screenHeight"
        value: root.screen ? root.screen.height : 0
    }

    // The "grow" reveal's circle, published for the text scramble's per-label
    // gate (see ui/ScrambleText.qml): a label the reveal hasn't reached is not
    // on screen, however opaque it is, and must not spend its scramble behind
    // the mask. Anim is a service and can't reach up here for it, so it's
    // pushed down - and left negative ("nothing is masking") for the launch
    // styles that fade instead of growing, and for a reveal that has landed.
    Binding {
        target: Anim
        property: "maskRadius"
        value: LauncherState.growMode && LauncherState.reveal < 1 ? LauncherState.revealDiameter / 2 : -1
    }
    Binding {
        target: Anim
        property: "maskX"
        value: LauncherState.originX
    }
    Binding {
        target: Anim
        property: "maskY"
        value: LauncherState.originY
    }

    function open(targetPane: string): void {
        fadeOut.stop(); // reopening mid-dismiss is allowed
        root.flushRemap();
        root.resetState(targetPane);
        root.shown = true;
        // Reopening mid-dismiss is the one path where `shown` is already true
        // here, so the assignment above is a no-op and onShownChanged - the
        // only thing that starts the reveal now that the surface stays mapped -
        // never fires. Left to that alone, the launcher sat open (exclusive
        // keyboard focus, no input mask, so it swallowed every key and click)
        // with reveal and content.opacity both parked at the 0 resetState just
        // put them at, drawing nothing at all. The one thing still visible was
        // the compositor blur region, which is only off while surfaceIdle: at
        // reveal 0 it sits at its 1px floor, leaving one blurred
        // wallpaper-coloured pixel at the reveal origin (measured (22,0,55)
        // against a (29,29,29) desktop, in the corner under grow-top-left) for
        // as long as the invisible launcher stayed "open" - and it stayed open
        // until the user pressed the keybind again, having seen nothing happen.
        // Calling it here covers that; the guard inside
        // makes it a no-op on the ordinary path, where onShownChanged has
        // already run it.
        root.startReveal();
        input.forceActiveFocus();
        // Fresh data per open, kicked off after the reveal lands (see
        // fadeIn.onFinished): the scans themselves are async, but their
        // outputs parse, sort and rebuild models on the GUI thread, and the
        // clipboard scan takes ~1-3s end to end. Kicking them off here used
        // to land that work mid-reveal (measured 100-400ms hitches plus
        // multi-second full-loop freezes); the panes show persisted results
        // until the new ones land, so nothing visible waits on them.
    }

    function resetState(targetPane: string): void {
        LauncherState.exiting = false;
        root.revealStarted = false;
        LauncherState.reveal = 0;
        content.opacity = 0;
        LauncherState.warmingApps = false;
        LauncherState.warmingWallpapers = false;
        LauncherState.wallpaperWarmTick = 0;
        LauncherState.expandedClip = null;
        LauncherState.cancelCapture();
        LauncherState.query = "";
        // Panes keep the opacity their last entrance animation ended at; each
        // puts itself back before the pane change below restarts that
        // animation (see resetEntrance for why the order matters).
        appsPage.resetEntrance();
        wallpapersPage.resetEntrance();
        clipboardPage.resetEntrance();
        settingsPane.resetEntrance();
        for (let i = 0; i < customPages.count; i++) {
            const host = customPages.itemAt(i);
            if (host)
                host.resetEntrance();
        }
        // Panes replay their entrance animation off onPaneChanged, which only
        // fires on an actual value change - reopening onto the same pane the
        // launcher was last closed on is otherwise a no-op assignment, so the
        // pane's opacity stays wherever the reset above left it with nothing
        // to animate it back in. Round-trip through a dead value so the
        // assignment always fires a real transition.
        //
        // `pibble toggle <page>` passes targetPane so a closed launcher opens
        // straight onto the requested page instead of the home pane; an
        // invalid/disabled/absent target falls back to home, the same rule
        // setPane() uses.
        const home = (targetPane && (targetPane === "settings" || LauncherState.activePanes.includes(targetPane))) ? targetPane : LauncherState.homePane();
        if (LauncherState.pane === home)
            LauncherState.pane = "";
        LauncherState.pane = home;
        LauncherState.paneBeforeSettings = LauncherState.homePane();
        LauncherState.selected = 0;
        LauncherState.wallpaperSelected = 0;
        LauncherState.carouselStep = 0;
        LauncherState.clipSelected = 0;
        LauncherState.powerArmed = false;
        LauncherState.powerDragging = false;
        LauncherState.powerRaw = 0;
        LauncherState.rebootArmed = false;
        LauncherState.rebootDragging = false;
        LauncherState.rebootRaw = 0;
    }

    // A page opts into its own Settings tab by declaring a `settingsTab`
    // Component on its root item (see PageContext). The label comes from the
    // page's own folder name, not from anything the page declares. Recomputed
    // off the delegates' loaded items so it tracks a page loading or
    // unloading, not just the set of uploaded pages changing.
    function syncSettingsTabs(): void {
        const tabs = [];
        for (let i = 0; i < customPages.count; i++) {
            const host = customPages.itemAt(i);
            const item = host ? host.pageItem : null;
            if (item && "settingsTab" in item && item.settingsTab) {
                const name = host.modelData.label;
                tabs.push({
                    pageId: host.modelData.id,
                    label: name.charAt(0).toUpperCase() + name.slice(1),
                    component: item.settingsTab
                });
            }
        }
        LauncherState.customSettingsTabs = tabs;
    }
    // A page *leaving* never goes through a host's onLoaded: trashing its row
    // or switching it off just destroys the delegate (or its Loader's item),
    // so without this its tab outlived it until the next daemon start. Every
    // one of those paths writes uploadedPages, and the delegates are still
    // standing when it changes, hence the deferred call.
    Connections {
        target: Settings
        function onUploadedPagesChanged(): void {
            Qt.callLater(root.syncSettingsTabs);
        }
    }


    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }
    // Bottom inset 12 (surface 1600x888, not 900): the glass plugin routes
    // geometry files by surface-size ratio (1% uniformity), and Lucid's
    // always-mapped fullscreen flash layer is exactly 1600x900 on Overlay -
    // one level above. At full height our pills ratio-match the flash too
    // (1.000), so the circle glass drew twice: behind text here, OVER text
    // there. At 888 the flash's ratio goes 1.35% non-uniform and its copy
    // is skipped, while our own file declares the real 888 and still
    // matches exactly. Revisit if the plugin ever routes by name.
    margins {
        bottom: 12
    }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    // Overlay while open so the picker (wallpapers included) layers above
    // fullscreen windows (Top sits below them), Top while idle: Hyprland
    // frosts behind always-mapped fullscreen Overlay surfaces, which read
    // as a stuck fullscreen blur tracking every open. Same pattern as
    // Lucid's dock (menuOpen ? Overlay : Top).
    WlrLayershell.layer: root.shown ? WlrLayer.Overlay : WlrLayer.Top
    // "quickshell-*" on purpose: the liquid-glass-hypr plugin gates on a
    // namespace substring ("quickshell") and routes geometry files to
    // surfaces by size — under its own "pibble-launcher" name the launcher
    // never matched, so its circle glass landed on Lucid's always-mapped
    // fullscreen flash layer instead (same 1600x900 size, one level above),
    // drawing OVER the text. Matched, the plugin draws on this surface
    // itself, where content composites crisply on top — glass behind text.
    // (Hyprland layerrule matches are regex: the quickshell xray rule also
    // matches this name, same as every other glass surface. Harmless: xray
    // only modifies blur, and no blur rule targets the launcher.)
    WlrLayershell.namespace: "quickshell-pibble"
    // Exclusive is what makes the launcher take every key while it is open, so
    // an idle mapped surface must give it up completely - otherwise the
    // keyboard stays captured by a launcher nobody can see.
    WlrLayershell.keyboardFocus: root.surfaceIdle ? WlrKeyboardFocus.None : WlrKeyboardFocus.Exclusive
    // Likewise for pointer input: an empty region is click-through, so an idle
    // surface can't swallow clicks meant for whatever is underneath it. Only
    // set while idle - an open launcher wants the whole surface.
    mask: root.surfaceIdle ? idleMask : null
    Region { id: idleMask }
    // This is a bonus on top of the client-side circle, not what draws
    // it: wherever a compositor implements ext-background-effect-v1,
    // this blurs the same area the circle already occupies. "fade" and
    // "none" have no circle, so they just get the whole surface,
    // statically, for as long as the window is open. Requesting a
    // region at all is what flips background-effect into "on request"
    // on niri, which then defaults its own xray-through-other-windows
    // behavior on too - so only ask when "Background blur" is actually
    // set to "compositor" ("xray", the non-protocol mode, draws a
    // blurred wallpaper behind the launcher itself instead - see
    // xrayBackdrop below).
    //
    // Compositor blur is opted out of entirely (null): on Hyprland any
    // surface holding a background-effect object gets blurred behind,
    // even confined to a 1px region that leaves a stuck fullscreen blur
    // on a permanently-mapped surface - while Lucid's shells set this to
    // null and never blur. Pibble's blur is client-side (xray backdrop /
    // glass shader), so nothing is lost.
    BackgroundEffect.blurRegion: null
    // Clipped to the output, which is not cosmetic. A Region is rasterised as
    // one span per scanline, and this ellipse is as tall as it is wide - several
    // screens' worth by the end of the reveal - so most of the spans it costs to
    // build, commit and re-blur on every frame of the animation describe circle
    // that is nowhere near the screen. Intersecting them away lights exactly the
    // same pixels and measurably steadies the reveal: over five reveals, frame
    // time went from 1.28ms to 0.77ms sd and frames over 10ms from 10-in-265 to
    // 1-in-265. That matters because the edge's position error is its velocity
    // times the frame-time error, and mid-reveal it is moving ~14px per ms.
    //
    // `intersection` goes on the *child* - it says how that region combines with
    // its parent. On the parent it silently does nothing, the ellipse unions
    // instead, and the whole screen blurs.
    Region {
        id: growRegion
        width: LauncherState.screenWidth
        height: LauncherState.screenHeight
        Region {
            intersection: Intersection.Intersect
            shape: RegionShape.Ellipse
            x: LauncherState.originX - LauncherState.revealBlurDiameter / 2
            y: LauncherState.originY - LauncherState.revealBlurDiameter / 2
            width: LauncherState.revealBlurDiameter
            height: LauncherState.revealBlurDiameter
        }
    }
    Region {
        id: fadeBlurRegion
        width: LauncherState.screenWidth
        height: LauncherState.screenHeight
    }
    Region {
        id: noBlurRegion
        // Off the surface, not at (0,0). All this region has to be is non-empty
        // (see BackgroundEffect.blurRegion above for why asking for nothing is
        // not the same as asking for almost nothing) - and a 1px region *inside*
        // the surface is a genuine pixel of blurred, undimmed backdrop. That is
        // invisible in a corner but obvious once the reveal origin is somewhere
        // you look: with grow-center and the launcher merely idle it put one
        // bright wallpaper-coloured pixel in the exact middle of the screen
        // (measured: (193,129,60) against a (29,29,32) desktop). Out here the
        // compositor clips it away entirely while the client still speaks the
        // protocol, which is the only thing the region was ever for.
        //
        // The `x` jitter is the resend described below; -8 and -9 are equally
        // off the surface, so it only exists to make the region change.
        x: -8 - (root.idleFlushTicks % 2)
        y: -8
        width: 1
        height: 1
    }
    // Asking once, at the moment the launcher closes, does not reliably land.
    // The blur region is double-buffered surface state (ext-background-effect:
    // "applied on the next wl_surface.commit"), and a close is the one moment
    // with no next frame: `shown` is cleared by a ScriptAction in the same
    // animation tick that draws the collapse's last frame, and a mapped-but-idle
    // surface - which this now is for the rest of the daemon's life, rather than
    // unmapping - never renders again on its own. So the switch to noBlurRegion
    // above sometimes never reached the compositor, which then went on blurring
    // whatever it had a frame earlier: a ~15px quarter-disc of wallpaper sitting
    // at the reveal origin (a dot in the corner under grow-top-left, in the
    // middle of the screen under grow-center) until the next open, which is the
    // only thing that made the surface draw again. Measured 2-3 in every 25
    // closes; "fade" and "none" have no collapse to shrink it, so what they can
    // strand is the whole screen's worth.
    //
    // Asking again on each of the next few frames fixes it: 0 in 25 closes with
    // four resends, which is margin - the failures only ever missed by a frame.
    // Nothing here is ever on screen and the region itself never changes shape;
    // it is the same 1px sliver, moved a pixel sideways to make Quickshell
    // re-send it. The same beat also carries the input mask and the
    // keyboard-focus mode, which are double-buffered for the same reason.
    property int idleFlushTicks: 0
    Timer {
        interval: 16
        repeat: true
        running: root.surfaceIdle && root.idleFlushTicks < 4
        onTriggered: root.idleFlushTicks++
    }
    // Fresh-data kickoff shared by the post-reveal hook below and the close
    // paths: a close that lands before the reveal finished (quick toggle)
    // would otherwise skip the scan for that open entirely, leaving the
    // next open one cycle stale. Scans landing while closed parse on an
    // idle loop (identical output is skipped), so this is free.
    function rescanData(): void {
        Clipboard.rescan();
        Wallpapers.rescan();
        Steam.rescan();
        CustomPages.rescan();
    }

    // ---------- exit / intro ----------
    function exit(): void {
        if (LauncherState.exiting)
            return;
        LauncherState.exiting = true;
        firstFrames.stop();
        fadeIn.stop();
        root.rescanData();
        fadeOut.restart();
    }

    // Recovery park for a scrambled open state (e.g. output vanishing
    // mid-open leaves fullscreen dim/blur stranded): drops every piece
    // of open state synchronously instead of animating out of it. The
    // IPC close path uses this; ordinary closes keep the animation via
    // exit().
    function hardClose(): void {
        fadeOut.stop();
        fadeIn.stop();
        firstFrames.stop();
        LauncherState.exiting = false;
        LauncherState.reveal = 0;
        content.opacity = 0;
        root.shown = false;
        root.rescanData();
    }

    // Launch close for morph spawns: the grid vanishes instantly under the
    // morph container (reads as the tile lifting off), instead of playing
    // the fullscreen masked fade frame-for-frame underneath the flight -
    // that overlap was the visible chop. Mirrors fadeOut's off-screen
    // bookkeeping synchronously (launch score, settings tab, dialog).
    function launchClose(): void {
        fadeOut.stop();
        fadeIn.stop();
        firstFrames.stop();
        LauncherState.exiting = false;
        LauncherState.reveal = 0;
        content.opacity = 0;
        root.shown = false;
        root.rescanData();
        LauncherState.settingsTab = "general";
        if (root.pendingRecordEntry) {
            Apps.recordLaunch(root.pendingRecordEntry);
            root.pendingRecordEntry = null;
        }
        LauncherState.openPendingDialog();
    }

    // resume from a dialog that borrowed the screen (e.g. the Pages
    // tab's upload picker): replays the entrance animation without
    // resetState()'s full reset (pane/tab/selection/rescans), so it lands
    // back exactly where the exit animation left off instead of at the
    // home pane
    function reopenAfterDialog(): void {
        root.flushRemap();
        LauncherState.exiting = false;
        root.revealStarted = false;
        LauncherState.reveal = 0;
        content.opacity = 0;
        root.shown = true;
        // Same reason as in open(): the dialog is only handed the screen once
        // the exit animation has finished, so this normally reopens a closed
        // launcher - but a toggle while the dialog held it leaves `shown`
        // already true, and then nothing else would replay the entrance.
        root.startReveal();
        input.forceActiveFocus();
    }


    ParallelAnimation {
        id: fadeIn
        onFinished: {
            // Fresh data per open lands here, after the reveal, instead of
            // at open(): scan outputs parse/sort/rebuild models on the GUI
            // thread (clipboard ~60KB, wallpapers ~400KB + sort), and the
            // clipboard scan itself runs ~1-3s. Firing them at open landed
            // that work mid-reveal.
            root.rescanData();
            // warm once per daemon run: the thumbs stay pinned by the
            // warm-up Images, so re-ticking the ~2s FrameAnimation on
            // every open just burned frames right as the user started
            // typing (visible as reveal/tile jank on quick Tab presses)
            if (!LauncherState.wallpapersWarmedOnce) {
                LauncherState.wallpapersWarmedOnce = true;
                LauncherState.warmingWallpapers = true;
            }
            // deferred one-time startup work (clip scans run per open)
            if (!SystemInfo.scansStarted) {
                SystemInfo.startDeferredScans();
                // the Dynamic theme already sampled at load; every other theme
                // still wants a palette ready in case it's switched to
                if (Settings.theme !== "matugen")
                    Theme.sampleWallpaper();
            }
        }
        NumberAnimation {
            target: content
            property: "opacity"
            from: 0
            to: 1
            duration: Anim.launch(LauncherState.fadeMode ? 720 : 1012)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: [0.2, 0.16, 0.06, 1.13, 1.0, 1.0]
        }
        NumberAnimation {
            target: LauncherState
            property: "reveal"
            from: 0
            to: 1
            // Only visible in "grow" styles - unused by "fade"/"none".
            duration: Anim.launch(1170)
            // User-tuned easing (cubic-bezier(0.2, 0.16, 0.06, 1.13) -
            // the 1.13 control overshoots just past 1 before settling),
            // at 2.25x duration.
            easing.type: Easing.BezierSpline
            easing.bezierCurve: [0.2, 0.16, 0.06, 1.13, 1.0, 1.0]
        }
    }

    SequentialAnimation {
        id: fadeOut
        ParallelAnimation {
            NumberAnimation {
                target: content
                property: "opacity"
                to: 0
                duration: Anim.launch(LauncherState.fadeMode ? 260 : 320)
                easing.type: Easing.InCubic
            }
            NumberAnimation {
                target: LauncherState
                property: "reveal"
                // Only visible in "grow" styles, same as above.
                to: 0
                duration: Anim.launch(320)
                // Same edge-travel budget as the entrance curve above, on a
                // tighter one: this covers the whole radius in 320ms rather than
                // 520, so its average is already the higher of the two. InQuad
                // put its peak (2x average) on the very last frame, which is
                // exactly the wrong place - the collapse skipped just as it
                // vanished. This peaks at 1.35x, mid-animation.
                easing.type: Easing.BezierSpline
                easing.bezierCurve: [0.4, 0.2, 0.55, 0.75, 1.0, 1.0]
            }
        }
        // hide the window; the daemon keeps running
        ScriptAction {
            script: root.shown = false
        }
        // now off-screen: put the settings filmstrip back on its first tab.
        // Same reason the launch score below is bumped here rather than at the
        // click - the tabs carry a Behavior on x, so resetting this on the way
        // *in* (with the rest of resetState) slid the whole filmstrip back from
        // wherever it was left, in plain view, right through the entrance.
        ScriptAction {
            script: LauncherState.settingsTab = "general"
        }
        // now off-screen: safe to bump the launch score (see
        // pendingRecordEntry above)
        ScriptAction {
            script: {
                if (root.pendingRecordEntry) {
                    Apps.recordLaunch(root.pendingRecordEntry);
                    root.pendingRecordEntry = null;
                }
            }
        }
        // the dialog itself lives on the Pages tab; this only says "the exit
        // animation has finished, it's safe to hand over the screen now"
        ScriptAction {
            script: LauncherState.openPendingDialog()
        }
    }
    // ---------- actions ----------
    // Launch through gtk-launch (GLib): quickshell's own Exec parser
    // follows the desktop-entry spec strictly, where single quotes are
    // not quoting characters - entries like `Exec=kitty bash -lc '...'`
    // get split mid-quote and crash on startup. GLib parses shell-style
    // (like every GTK-based launcher), and also honors Path= and
    // DBusActivatable. Falls back to the entry's own execute() if
    // gtk-launch can't find the id.
    property var launchEntry: null
    // recordLaunch() bumps the entry's score, which LauncherState.matches (sorted
    // by launchCount) reactively re-sorts on - bumping it immediately
    // visibly reshuffles the grid while the close animation is still
    // fading it out. Held here and only recorded once fadeOut actually
    // hides the window (see its ScriptAction below), so the re-sort
    // happens off-screen. Separate from launchEntry, which onExited
    // below usually clears well before that animation finishes.
    property var pendingRecordEntry: null
    Process {
        id: appLaunch
        onExited: exitCode => {
            if (exitCode !== 0 && root.launchEntry)
                root.launchEntry.execute();
            root.launchEntry = null;
        }
    }
    // Steam games carry no .desktop id for gtk-launch, so they go through
    // the Steam client directly. -applaunch (not the steam://rungameid/
    // URL Steam's own shortcuts use) plus -silent is what keeps the
    // client's window shut: the game starts while Steam stays (or starts)
    // in the background instead of being pulled to the foreground.
    // Ranked like everything else via pendingRecordEntry above.
    Process {
        id: steamLaunch
        onExited: exitCode => {
            if (exitCode === 42)
                Notifier.missingDependency("steam not found", "Install Steam to launch Steam games.");
            else if (exitCode !== 0)
                Notifier.error("Steam launch failed", "steam exited with code " + exitCode);
        }
    }
    // No-match fallback (see LauncherState.browserRequested): URLs open
    // directly, anything else is handed to the *default browser itself* as
    // a raw string, so whatever its own configured search engine is handles
    // it - never a hardcoded engine here (the default is zen right now, but
    // this resolves it live via x-scheme-handler/https).
    Process {
        id: browserLaunch
        onExited: exitCode => {
            if (exitCode !== 0)
                Notifier.error("Browser launch failed", "could not open query in the default browser (exit " + exitCode + ")");
        }
    }
    // Focus-or-launch: a second launch of an already-running app focuses its
    // window (Hyprland switches to its workspace as part of the focus)
    // instead of spawning a duplicate. Shift/Ctrl+Enter bypasses this (see
    // the launch keybind below) to force a second window. Steam and index
    // entries carry no window class to match on, so they always launch.
    function entryClassCandidates(entry): var {
        const out = [];
        const push = v => {
            if (typeof v !== "string")
                return;
            const full = v.toLowerCase().trim().replace(/\.desktop$/, "");
            if (full && out.indexOf(full) < 0)
                out.push(full);
            const dot = full.lastIndexOf(".");
            const tail = dot >= 0 ? full.slice(dot + 1) : full;
            if (tail && out.indexOf(tail) < 0)
                out.push(tail);
        };
        if (!entry || entry.steamAppId || entry.indexPdfPath || entry.indexUrl)
            return out;
        push(entry.startupClass);
        push(entry.id);
        return out;
    }
    // Fuzzy fallback for entries whose desktop id never equals the window
    // class (e.g. Zed: id "dev.zed.Zed", class "dev.zed.Zed-Dev"; Comfy:
    // id "comfy-desktop-nogpu", class "Comfy Desktop"). Stripped to bare
    // alphanumerics so separators can't hide a containment. Only consulted
    // when nothing matched exactly, so a close sibling (Firefox vs
    // Firefox Developer Edition) still prefers its exact window.
    function entryFuzzyCandidates(entry): var {
        const out = [];
        const push = v => {
            if (typeof v !== "string")
                return;
            const s = v.toLowerCase().replace(/[^a-z0-9]/g, "");
            if (s.length >= 4 && out.indexOf(s) < 0)
                out.push(s);
        };
        if (!entry || entry.steamAppId || entry.indexPdfPath || entry.indexUrl)
            return out;
        push(entry.startupClass);
        push(entry.id);
        push(entry.name);
        return out;
    }
    // Snapshot of one live window for the matcher below, or null when it
    // carries no addressable identity at all.
    function windowInfo(t): var {
        if (!t)
            return null;
        let ipc = null;
        try {
            ipc = t.lastIpcObject;
        } catch (e) {
            ipc = null;
        }
        const classes = [];
        if (ipc) {
            if (ipc.class)
                classes.push(ipc.class);
            if (ipc.initialClass)
                classes.push(ipc.initialClass);
        }
        try {
            if (t.wayland && t.wayland.appId)
                classes.push(t.wayland.appId);
        } catch (e) {}
        if (!classes.length)
            return null;
        let addr = (ipc && ipc.address) ? ipc.address : "";
        if (!addr) {
            try {
                addr = t.address ? t.address : "";
            } catch (e) {}
        }
        if (!addr)
            return null;
        let ws = -1;
        try {
            ws = (ipc && ipc.workspace && ipc.workspace.id !== undefined) ? Number(ipc.workspace.id) : (t.workspace ? t.workspace.id : -1);
        } catch (e) {}
        let fh = Number.MAX_SAFE_INTEGER;
        try {
            if (ipc && ipc.focusHistoryID !== undefined && ipc.focusHistoryID !== null)
                fh = Number(ipc.focusHistoryID);
        } catch (e) {}
        return { addr: addr, classes: classes, ws: ws, fh: fh };
    }
    // Best address among infos passing test(), or "". Prefers a window on
    // the current workspace, else the most recently focused.
    function rankWindow(infos, curWs, test): string {
        let best = "";
        let bestOnCur = false;
        let bestFocus = Number.MAX_SAFE_INTEGER;
        for (let i = 0; i < infos.length; i++) {
            const info = infos[i];
            if (!test(info))
                continue;
            const onCur = info.ws === curWs;
            if (best === "" || (onCur && !bestOnCur) || (onCur === bestOnCur && info.fh < bestFocus)) {
                best = info.addr;
                bestOnCur = onCur;
                bestFocus = info.fh;
            }
        }
        return best;
    }
    // Address of a live window for the entry, or "" when none matches.
    // Two passes: exact class equality first, then the fuzzy containment
    // fallback (see entryFuzzyCandidates) - so Zed (id "dev.zed.Zed",
    // class "dev.zed.Zed-Dev") and Comfy (id "comfy-desktop-nogpu", class
    // "Comfy Desktop") focus instead of duplicating, while a close sibling
    // (Firefox vs Firefox Developer Edition) still prefers its exact
    // window. Several windows of the same app (e.g. three kittys): prefers
    // one on the current workspace so launching what is already here stays
    // here, else the most recently focused (lowest focusHistoryID).
    function findExistingWindow(entry): string {
        const cands = root.entryClassCandidates(entry);
        if (!cands.length)
            return "";
        let tls = [];
        try {
            tls = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        } catch (e) {
            return "";
        }
        let curWs = -1;
        try {
            curWs = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1;
        } catch (e) {}
        const infos = [];
        for (let i = 0; i < tls.length; i++) {
            const info = root.windowInfo(tls[i]);
            if (info)
                infos.push(info);
        }
        const exact = root.rankWindow(infos, curWs, info => {
            for (let a = 0; a < info.classes.length; a++) {
                if (cands.indexOf(String(info.classes[a]).toLowerCase().trim()) >= 0)
                    return true;
            }
            return false;
        });
        if (exact)
            return exact;
        const fuzzy = root.entryFuzzyCandidates(entry);
        if (!fuzzy.length)
            return "";
        return root.rankWindow(infos, curWs, info => {
            for (let a = 0; a < info.classes.length; a++) {
                const c = String(info.classes[a]).toLowerCase().replace(/[^a-z0-9]/g, "");
                if (c.length < 4)
                    continue;
                for (let f = 0; f < fuzzy.length; f++) {
                    if (c.indexOf(fuzzy[f]) >= 0 || fuzzy[f].indexOf(c) >= 0)
                        return true;
                }
            }
            return false;
        });
    }
    // Resolve a launch rect into launcher-surface coords for the morph
    // stage. The tap path maps its own cell (AppsPage coords); Enter
    // carries null and the selected cell is resolved here. mapToItem is
    // transform-aware, so drawer scale/offsets at tap time are accounted
    // for; a null result (or nonsense) means no morph, never no launch.
    function morphRect(rect: var): var {
        let r = rect;
        if (!r)
            r = appsPage.selectedIconRect();
        if (!r || !(r.width > 0) || !Number.isFinite(r.x + r.y + r.width + r.height))
            return null;
        const s = appsPage.mapToItem(content, r.x, r.y, r.width, r.height);
        if (!s || !(s.width > 0))
            return null;
        return { x: s.x, y: s.y, width: s.width, height: s.height };
    }
    // instant=true comes from a morph spawn (see onLaunchRequested): the
    // grid vanishing synchronously under the morph container reads as the
    // tile lifting off, and keeps the fullscreen masked fade from running
    // frame-for-frame underneath the flight. Plain launches keep exit().
    // Pibble's own index entries (PDFs, Zen domains - see services/Index.qml):
    // plain objects with no .desktop id and no Steam appid, opened directly.
    // Ranked like everything else via pendingRecordEntry above.
    Process {
        id: indexLaunch
        onExited: exitCode => {
            if (exitCode !== 0)
                Notifier.error("Open failed", "could not open the indexed item (exit " + exitCode + ")");
        }
    }
    function launch(entry, instant: bool) {
        if (!entry)
            return;
        pendingRecordEntry = entry;
        if (entry.indexPdfPath) {
            // Detached like the app path below (own session, stdio to
            // /dev/null); -w keeps the exit code for the notifier above.
            indexLaunch.command = ["bash", "-c", 'exec setsid -w xdg-open "$1" >/dev/null 2>&1', "_", entry.indexPdfPath];
            indexLaunch.running = true;
            if (instant)
                root.launchClose();
            else
                exit();
            return;
        }
        if (entry.indexUrl) {
            // Zen-specific open (the history is Zen's), falling back to the
            // default browser where Zen's entry is missing.
            indexLaunch.command = ["bash", "-c", `
                if command -v gtk-launch >/dev/null 2>&1 && { [ -f "$HOME/.local/share/applications/zen.desktop" ] || [ -f /usr/share/applications/zen.desktop ]; }; then
                    exec setsid -w gtk-launch zen.desktop "$1" >/dev/null 2>&1
                else
                    exec setsid -w xdg-open "$1" >/dev/null 2>&1
                fi
            `, "_", entry.indexUrl];
            indexLaunch.running = true;
            if (instant)
                root.launchClose();
            else
                exit();
            return;
        }
        if (entry.steamAppId) {
            launchEntry = null;
            steamLaunch.command = ["bash", "-c", 'command -v steam >/dev/null 2>&1 || exit 42; exec setsid steam -silent -applaunch "$1" >/dev/null 2>&1', "_", String(entry.steamAppId)];
            steamLaunch.running = true;
            if (instant)
                root.launchClose();
            else
                exit();
            return;
        }
        launchEntry = entry;
        // The launched app inherits gtk-launch's stdio, i.e. this Process's
        // pipes - which close once gtk-launch exits, so chatty apps
        // (flatpaks especially) would SIGPIPE on their next log line and
        // die seconds after launch. Point stdio at /dev/null and give the
        // app its own session; setsid -w keeps gtk-launch's exit code for
        // the fallback below.
        appLaunch.command = ["bash", "-c", 'command -v gtk-launch >/dev/null || exit 42; setsid -w gtk-launch "$1" >/dev/null 2>&1', "_", entry.id];
        appLaunch.running = true;
        if (instant)
            root.launchClose();
        else
            exit();
    }
    // Opens a no-match query in the default browser: clear URLs (with or
    // without a scheme) go straight via xdg-open; anything else is passed
    // raw to the default browser's .desktop entry, which searches it with
    // the browser's own default engine. Deliberately not recorded as an app
    // launch, and never morphed - there is no tile to lift off from.
    function openQueryInBrowser(q: string) {
        const query = (q ?? "").trim();
        if (!query)
            return;
        // Launch-desktop pin for the no-match browser fallback too: no tile
        // and no entry, so an empty matchKey (any fresh window is plausibly
        // ours - see Morph.matches) tagged with the origin. The late path
        // ages morph-less pins out fast (15s) so a stray later window can't
        // be claimed by a stale browser pin.
        try {
            let ows = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1;
            if (!(ows > 0))
                ows = Morph.activeWs;
            if (ows > 0)
                Morph.pinLaunch("", ows);
        } catch (e) {}
        browserLaunch.command = ["bash", "-c", `
            q="$1"
            if [[ "$q" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]] || [[ "$q" =~ ^[^[:space:]/]+\.[^[:space:]/]{2,}(/[^[:space:]]*)?$ ]]; then
                url="$q"
                [[ "$url" == *://* ]] || url="https://$url"
                exec setsid xdg-open "$url" >/dev/null 2>&1
            else
                desk=$(xdg-mime query default x-scheme-handler/https 2>/dev/null)
                if [ -n "$desk" ] && command -v gtk-launch >/dev/null 2>&1; then
                    exec setsid gtk-launch "$desk" "$q" >/dev/null 2>&1
                else
                    enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$q")
                    exec setsid xdg-open "https://duckduckgo.com/?q=$enc" >/dev/null 2>&1
                fi
            fi
        `, "_", query];
        browserLaunch.running = true;
        exit();
    }
    // A pick is only committed once the user's wallCommand has actually
    // succeeded: Settings.currentWallpaper is what the Dynamic theme samples
    // (see Theme's matugen run) and what the xray backdrop resolves its blurred
    // variant from, so committing it up front would retheme the whole
    // shell around a wallpaper that never reached the screen. That's the
    // reason the command runs as a tracked Process rather than an
    // execDetached - its exit code is the deciding signal.
    property var pendingWall: null
    property var queuedWall: null
    Process {
        id: wallApply
        // set when a newer pick killed this run (see LauncherWindow.applyWallpaper): the
        // non-zero exit that follows is ours, not the command failing
        property bool superseded: false
        onExited: exitCode => {
            wallGrace.stop();
            const wall = root.pendingWall;
            root.pendingWall = null;
            if (superseded)
                superseded = false;
            else if (exitCode !== 0)
                Notifier.error("Wallpaper command failed", Settings.wallCommand + "\n\nChange it in Settings > Pages > Wallpapers command.");
            else if (wall)
                root.commitWallpaper(wall);
            if (root.queuedWall) {
                const next = root.queuedWall;
                root.queuedWall = null;
                // one event-loop hop before respawning, same as
                // Theme's matugen run's rerun: running can't go false→true from
                // inside the handler that observed it going false
                Qt.callLater(() => root.runWallCommand(next));
            }
        }
    }
    // Commands that never exit - a foreground swaybg/mpvpaper rather than
    // a daemon client like awww/swww - would otherwise hold the commit
    // forever. Anything that genuinely fails (missing binary, bad
    // arguments) does so in milliseconds, so a command still alive this
    // long has taken effect and is simply staying resident: commit it and
    // leave onExited above to report a failure that arrives much later.
    // Kept short (rather than a multi-second margin) so the resident case
    // notifies about as fast as the exits-immediately case does.
    Timer {
        id: wallGrace
        interval: 800
        onTriggered: {
            if (root.pendingWall) {
                root.commitWallpaper(root.pendingWall);
                root.pendingWall = null;
            }
        }
    }
    function runWallCommand(wall) {
        pendingWall = wall;
        // Refused while the integration is off (see Settings.weEnabled): the
        // picker hides Workshop entries, so this only fires for a stale pick.
        // No fallback render exists - a directory is not an image - so this
        // notifies instead of running half a command.
        if (wall.we && !Settings.weEnabled) {
            pendingWall = null;
            Notifier.error("Wallpaper Engine is disabled", "Re-enable it in Settings > Pages > Wallpaper Engine integration.");
            return;
        }
        // Wallpaper Engine picks bypass the freeform wallCommand: the
        // renderer is a resident layer-shell client that must be told every
        // output explicitly (--screen-root/--bg). A bare `<path>` would open
        // a floating window instead of the desktop background.
        if (wall.we) {
            // Outputs from Settings.weScreens (empty = all). See Defaults.
            const wanted = Settings.weScreens.split(",").map(s => s.trim()).filter(s => s !== "");
            const outs = Quickshell.screens.map(s => s.name).filter(n => wanted.length === 0 || wanted.includes(n));
            const targets = outs.length > 0 ? outs : Quickshell.screens.map(s => s.name);
            if (wall.weVideo && wall.anim) {
                // Video walls go through mpvpaper, one process per output:
                // proven smooth on all three outputs at once, where lwe's
                // single-process 3-instance libmpv embed slideshows. Muted,
                // original speed (slowing video only halves fps, unlike
                // scene time), and off the resampled Bluetooth clock (which
                // visibly judders A/V sync). No -a flag: it stops when any
                // window is maximized, which on a tiled desktop is always,
                // so nothing would ever play.
                const mpvOuts = targets.map(n => `"${n}"`).join(" ");
                wallApply.command = ["bash", "-c", `
                    export PATH="$HOME/.local/bin:$PATH"
                    command -v mpvpaper >/dev/null 2>&1 || exit 42
                    pkill -x linux-wallpaper
                    pkill mpvpaper
                    for out in ${mpvOuts}; do
                        setsid mpvpaper -s -o "no-audio --loop-file=inf" "$out" "$1" >/dev/null 2>&1 &
                    done
                    exit 0
                `, "_", wall.anim];
                wallApply.running = true;
                wallGrace.restart();
                return;
            }
            // Scene walls go through the renderer, which must be told every
            // output explicitly (--screen-root/--bg): a bare `<path>` would
            // open a floating window instead of the desktop background.
            const roots = targets.map(n => `--screen-root "${n}" --bg "${wall.path}"`).join(" ");
            wallApply.command = ["bash", "-c", `
                export PATH="$HOME/.local/bin:$PATH"
                command -v "$1" >/dev/null 2>&1 || exit 42
                pkill -x linux-wallpaper
                pkill mpvpaper
                export __GL_SYNC_TO_VBLANK=0
                exec setsid -w "$1" --fps 30 --scaling fill --silent ${roots} >/dev/null 2>&1
            `, "_", Settings.weBinary];
            wallApply.running = true;
            wallGrace.restart();
            return;
        }
        // $WALL and $BLUR are exported for the command to template with.
        // $BLUR is the cached blurred variant the scan already resolved
        // for this wallpaper - the same image the launcher's own backdrop
        // draws, or the user's <stem>blurred.<ext> where they've supplied
        // one. Empty until the background pass has generated it (a few
        // seconds on a cold cache, see Wallpapers' scan), which is why commands
        // that use it should guard for that.
        // setsid -w keeps this a tracked child in every way that matters
        // (it waits, and reports the command's own exit code) while giving
        // the command its own session, so a resident setter - mpvpaper,
        // a foreground swaybg - outlives the daemon exactly as it did
        // under the execDetached this replaced, instead of being torn down
        // with quickshell. Stdio goes to /dev/null for the reason spelled
        // out on appLaunch: a resident child left holding this Process's
        // pipes gets SIGPIPE'd the moment they close.
        //
        // A static pick always tears down the Wallpaper Engine backends
        // first: they are resident layer-shell/mpvpaper clients that would
        // otherwise keep rendering over (or under) the static image. Done
        // here rather than left to the freeform wallCommand so a custom
        // command without its own pkill can't strand them running.
        wallApply.command = ["bash", "-c", `
            export PATH="$HOME/.local/bin:$PATH"
            pkill -x linux-wallpaper 2>/dev/null || true
            pkill mpvpaper 2>/dev/null || true
            WALL="$1" BLUR="$2"
            export WALL BLUR
            exec setsid -w bash -c "$3" >/dev/null 2>&1
        `, "_", wall.path, wall.blur, Settings.wallCommand];
        wallApply.running = true;
        wallGrace.restart();
    }
    function commitWallpaper(wall) {
        // record what was applied so the Dynamic theme can sample this
        // exact file directly, instead of asking the compositor what's
        // currently on screen (see Theme's matugen run)
        Settings.currentWallpaper = wall.path;
        Settings.save();
        Theme.sampleWallpaper();
        // System-wide sync: what Lucid's picker ran via set-wallpaper.sh
        // (state files, theme mode, full matugen templates). Images go
        // through the full script (set + theme); animated sources (videos,
        // Wallpaper Engine walls) have no static file to set and re-setting
        // would kill the mpvpaper session the wall command just started
        // (or fight the layer-shell client for a WE pick), so they get the
        // theme-only pass instead: the cached thumbnail/frame is sampled
        // for luminance + matugen while the live backend keeps rendering.
        // Thumb is read off the picked wall itself (not Wallpapers.
        // matugenSource, whose binding may not have caught up to the
        // Settings.currentWallpaper assignment above yet); the script's
        // -f check drops a missing/unready thumbnail gracefully.
        if (!wall.video && !wall.we)
            Quickshell.execDetached([Quickshell.env("HOME") + "/.config/hypr/scripts/wallpaper/set-wallpaper.sh", wall.path]);
        else if (wall.thumb && wall.thumb !== "")
            Quickshell.execDetached(["env", "THEME_ONLY=1", Quickshell.env("HOME") + "/.config/hypr/scripts/wallpaper/set-wallpaper.sh", wall.thumb]);
        // No "Wallpaper changed" alert: applying a wallpaper is visible on
        // screen already, so a notification for it is noise. The picker's
        // other action alerts (copy, trash, page discovery) are unaffected.
    }
    function applyWallpaper(wall) {
        if (!wall)
            return;
        if (wallApply.running) {
            // a newer pick supersedes one still in flight: drop the wrapper
            // (its wallpaper is no longer the one wanted) and start the new
            // command from onExited. Only the wrapper is signalled - a
            // resident setter is off in its own session, left for the
            // user's own command to replace as it always was
            queuedWall = wall;
            wallApply.superseded = true;
            wallApply.running = false;
        } else {
            runWallCommand(wall);
        }
        exit();
    }
    function expandClip(clip): void {
        if (!clip)
            return;
        LauncherState.expandedClip = clip;
        LauncherState.expandedText = "";
        LauncherState.expandedBytes = -1;
        LauncherState.expandedFullPath = "";
        LauncherState.expandedFullId = "";
        // cells record expandOrigin synchronously on the change above
        Qt.callLater(() => LauncherState.expandAnimStart());
        // Skip the on-demand decode when the clip's native size already
        // fits the thumb cap (307200 pixels): the thumb (built with
        // magick's "only shrink if larger" >) IS the full-res image
        // there, so decoding again would just swap the Image source to
        // identical pixels - and any source change makes QML clear the
        // current pixmap and reload async, flashing blank for no visual
        // gain. Pixel count and not a bounding box, because that is the
        // shape of the cap the thumbnail pass applies (see Clipboard's
        // thumbnails command); testing the two sides separately would
        // call a shrunken thumb full-res and leave the expanded view on
        // it forever.
        const d = (clip.dims || "").split("x");
        const iw = parseInt(d[0]) || 0;
        const ih = parseInt(d[1]) || 0;
        if (clip.image && iw * ih > 307200) {
            LauncherState.expandedFullId = clip.id;
            clipFullImg.forId = clip.id;
            clipFullImg.command = ["bash", "-c", `
                export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"
                dir="$1"; id="$2"
                f="$dir/$id-full.png"
                [ -s "$f" ] || cliphist decode "$id" > "$f"`, "_", Clipboard.thumbDir, clip.id];
            clipFullImg.running = true;
        }
        // Fast path: decode for the details view immediately so the
        // text reveal runs together with the expand animation.
        root.infoClipId = clip.id;
        clipInfo.command = ["bash", "-c", `
            export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"
            cliphist decode "$1" | wc -c
            # this is a single on-demand decode (not the ~200-entry scan
            # pass), so a much larger cap than the scan's is affordable;
            # the expand view scrolls past its viewport rather than
            # truncating, so this only needs to be generous, not exact
            [ "$2" = "txt" ] && cliphist decode "$1" | head -c 200000
            exit 0`, "_", clip.id, clip.image ? "img" : "txt"];
        clipInfo.running = true;
        // Slow path: copy (which re-stores the entry under a new id via
        // the watcher), notify, then patch the new id into the list so
        // cached thumbnails stay valid.
        clipCopy.command = ["bash", "-c", `
            export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"
            if ! command -v wl-copy >/dev/null 2>&1; then
                [ "$5" = "1" ] && notify-send -a pibble -i system-software-install "wl-copy not found" "wl-copy (wl-clipboard) is used to place clipboard history entries back on the clipboard - install it to copy from this page."
                exit 0
            fi
            tmp=$(mktemp)
            cliphist decode "$1" > "$tmp"
            wl-copy < "$tmp"
            # the notification body carries the full copied text (images
            # get the description passed in as $4)
            if [ "$2" = "img" ]; then
                body="$4"
            else
                body=$(head -c 4000 "$tmp")
            fi
            rm -f "$tmp"
            # copied images ride along as notification media (the decoded
            # entry is already cached by the thumbnail scan)
            if [ "$6" = "1" ]; then
                if [ "$2" = "img" ] && [ -s "$3/$1.png" ]; then
                    notify-send -a pibble -i edit-copy -h "string:image-path:$3/$1.png" "Copied to clipboard" "$body"
                else
                    notify-send -a pibble -i edit-copy "Copied to clipboard" "$body"
                fi
            fi
            sleep 0.3
            nid=$(cliphist list | head -n 1 | cut -f1)
            echo "$nid"
            if [ "$2" = "img" ] && [ -n "$nid" ] && [ "$nid" != "$1" ]; then
                cp "$3/$1.png" "$3/$nid.png" 2>/dev/null
            fi
            exit 0`, "_", clip.id, clip.image ? "img" : "txt", Clipboard.thumbDir,
            clip.preview.slice(0, 60), Settings.alertEnabled("missingDeps") ? "1" : "0", Settings.alertEnabled("actions") ? "1" : "0"];
        clipCopy.running = true;
    }
    property string infoClipId: ""
    Process {
        id: clipFullImg
        property string forId: ""
        onExited: (code) => {
            if (code === 0 && forId === LauncherState.expandedClip?.id) {
                LauncherState.expandedFullPath = Clipboard.thumbDir + "/" + forId + "-full.png";
            }
        }
    }
    Process {
        id: clipInfo
        stdout: StdioCollector {
            onStreamFinished: {
                const nl = text.indexOf("\n");
                LauncherState.expandedBytes = parseInt(text.slice(0, nl).trim()) || 0;
                LauncherState.expandedText = text.slice(nl + 1);
            }
        }
    }
    Process {
        id: clipCopy
        stdout: StdioCollector {
            onStreamFinished: {
                const nid = text.trim();
                if (nid && root.infoClipId && nid !== root.infoClipId) {
                    const idx = Clipboard.entries.findIndex(c => c.id === root.infoClipId);
                    if (idx >= 0) {
                        const c = Clipboard.entries[idx];
                        const upd = Object.assign({}, c, { id: nid });
                        if (c.image && c.thumb)
                            upd.thumb = Clipboard.thumbDir + "/" + nid + ".png";
                        // patched in place (not moved to the front): expanding a
                        // clip re-copies it, which is what forces this id patch
                        // (cliphist assigns a fresh id on every copy, and the
                        // cache is keyed by id) - but expanding is also just
                        // "look at this", not "move it", so the clip stays put
                        // instead of jumping to index 0 out from under you
                        const next = Clipboard.entries.slice();
                        next[idx] = upd;
                        Clipboard.entries = next;
                        // reassigning Clipboard.entries gives clipMatches a new array
                        // reference, and onClipMatchesChanged unconditionally
                        // resets clipSelected to 0 on any such change (it's
                        // meant for "you typed a new query", not "an id got
                        // patched") - restore the selection to wherever this
                        // clip landed once that reset has already run
                        Qt.callLater(() => {
                            const newIdx = LauncherState.clipMatches.findIndex(c2 => c2.id === nid);
                            if (newIdx >= 0)
                                LauncherState.clipSelected = newIdx;
                        });
                    }
                }
            }
        }
    }
    // Mask shape: same geometry as the blur-region ellipse above, so
    // the client-drawn circle and any compositor blur behind it
    // (where supported) stay in sync.
    //
    // Sized to match the surface (not just the circle) so MultiEffect
    // maps mask <-> source pixel-for-pixel instead of stretching a small
    // texture across the whole surface - which holds for both the items
    // that mask against it, since both fill the window. Kept genuinely
    // visible (not visible: false) and layered explicitly, since an
    // invisible item's layer never actually renders - a huge offset is
    // what keeps it off the real screen instead.
    //
    // Dropping this layer while the launcher is closed was tried, since it is a
    // full-screen (here 5120x2160) FBO that nothing masks against with nothing
    // on screen. It rendered correctly and cost no open latency, but it only
    // moved the number before the first open (590 -> 492MiB); once the launcher
    // had been opened once, closed sat at 814MiB either way. The driver appears
    // to keep the freed allocation in this process's pool rather than hand it
    // back, so the saving never reaches anything else on the GPU.
    Item {
        id: growMask
        visible: true
        layer.enabled: true
        x: -100000
        y: -100000
        width: root.width
        height: root.height

        Rectangle {
            antialiasing: true
            x: LauncherState.originX - LauncherState.revealDiameter / 2
            y: LauncherState.originY - LauncherState.revealDiameter / 2
            width: LauncherState.revealDiameter
            height: LauncherState.revealDiameter
            radius: width / 2
            color: "white"
        }
    }
    XrayBackdrop {
        maskSource: growMask
        // an idle mapped surface draws nothing at all (see root.surfaceIdle);
        // the backdrop is otherwise the one thing here that is opaque on its
        // own rather than riding content's opacity
        visible: !root.surfaceIdle && Settings.bgBlur === "xray"
    }
    // Circle publisher for the liquid-glass-hypr compositor plugin (same
    // file contract as Lucid's bar/dock GlassLayout): the plugin draws
    // live glass in-render-pass (real behind pixels, edges, refraction,
    // bokeh) confined to the reveal circle. Empty pills when closed, so
    // nothing lingers; per-frame during the reveal, like Lucid's morphs.
    // Published 20% larger than the content circle: keeps the glass edge
    // (and its edge refraction) away from the screen edge.
    // Requires the surface namespace to match the plugin's namespaces
    // pattern (see WlrLayershell.namespace above): geometry files route
    // by surface SIZE, so an unmatched surface's glass lands on whatever
    // same-size surface does match — which drew it OVER the text.
    GlassLayout {
        name: "pibble"
        // Must match WlrLayershell.namespace above; size alone can't tell
        // this 900px surface from Lucid's 896px island bar (0.4% apart).
        surfaceNamespace: "quickshell-pibble"
        targetScreen: root.screen
        surfaceW: root.width
        surfaceH: root.height
        // Quantized to 0.5px (see GlassLayout): the diameters below are
        // float products of an int, so every frame differs textually for
        // zero visible change at output scale.
        pills: (root.shown && LauncherState.reveal > 0) ? [{
            x: Math.round((LauncherState.originX - LauncherState.revealDiameter * 0.6) * 2) / 2,
            y: Math.round((LauncherState.originY - LauncherState.revealDiameter * 0.6) * 2) / 2,
            w: Math.round(LauncherState.revealDiameter * 1.2 * 2) / 2,
            h: Math.round(LauncherState.revealDiameter * 1.2 * 2) / 2,
            r: [LauncherState.revealDiameter * 0.6, LauncherState.revealDiameter * 0.6, LauncherState.revealDiameter * 0.6, LauncherState.revealDiameter * 0.6],
            // deliberate circle: the launch reveal is animation geometry,
            // not a corner - opt out of the shared squircle so it stays
            // a true circle while opening
            sq: 0
        }] : []
    }
    Item {
        id: content
        anchors.fill: parent
        // belt-and-braces with the opacity below, which a closed launcher
        // already leaves at 0: `visible` is what guarantees an idle mapped
        // surface costs the compositor nothing to composite
        visible: !root.surfaceIdle
        opacity: 0
        // "grow" styles: clip content itself into the growing circle
        // instead of relying on compositor blur to fake one - renders
        // identically on every compositor.
        layer.enabled: LauncherState.growMode
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: growMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 0.05
        }
            Rectangle {
                anchors.fill: parent
                color: Qt.alpha(Theme.surface, Settings.dimOpacity)
            }
            // Background click-catcher; also the scroll-wheel path. Wheel
            // events land here from anywhere on screen: MouseAreas ignore
            // wheel unless they connect onWheel, so tile/button areas pass
            // scrolls down to this full-screen area. (A topmost sibling with
            // a WheelHandler never received the events on this layer surface,
            // so the handler lives on a MouseArea, whose delivery is proven
            // by the click path.)
            MouseArea {
                id: backdropArea
                anchors.fill: parent
                property real wheelAcc: 0
                // swipe-left/right cycles panes - same cyclePane() the
                // Tab/Shift+Tab keybinds drive. swipe-up/down instead
                // pages through the current pane's grid (apps/clips/
                // wallpaper tiles), one full page of tiles at a time - see
                // LauncherState.pageMove(). Over the windows wallpaper carousel's own
                // bounds specifically (background gaps between its cells -
                // the cells' own swipe handling is on the carousel's cell), left/right
                // instead drags the carousel live (LauncherState.carouselDragTo()) and
                // commits whole slots on release (LauncherState.carouselDragEnd(), a
                // distance carried by the drag scaled by release speed)
                // and up/down is a no-op, since the carousel has no grid
                // pages.
                //
                // The edge swipes (power/reboot shade, swipe-to-go-back)
                // below are tracked the exact same way, in this same
                // MouseArea, instead of with sibling DragHandlers - a
                // DragHandler tried that first, but it competes with this
                // MouseArea for the same touch grab, and on a layer-shell
                // surface that race is genuinely unreliable: logged
                // touch traces showed identical, correctly-detected edge
                // presses sometimes never reaching the DragHandler's
                // active state at all, silently swallowing the gesture,
                // for no reason visible at the QML level. Mouse input
                // never showed this because it doesn't go through the
                // same touch grab arbitration. Routing everything through
                // this MouseArea's own press/move/release - already
                // proven reliable for pane-cycle/page-move/carousel above
                // - removes the race entirely instead of trying to win it.
                readonly property bool onCarousel: LauncherState.pane === "walls" && Settings.wallpaperStyle !== "grid"
                property real pressX: 0
                property real pressY: 0
                property real pressTime: 0
                property bool horizTracking: false
                property bool vertTracking: false
                property bool carouselTracking: false
                property bool edgePress: false
                // same idea as edgePress, but the right edge specifically -
                // left alone here so backTracking below can pull the
                // swipe-to-go-back pill out instead of this being treated
                // as a pane-cycle swipe
                property bool rightEdgePress: false
                // power/reboot notification-shade-style edge drag: starts
                // once a press begins inside the top/bottom edgeSwipeZone
                // strip, same as edgePress above, or - once a prompt is
                // already armed - from anywhere, since at that point the
                // whole screen belongs to it (dragZone gets pinned to
                // whichever prompt is armed, ignoring where this press
                // landed; see onPressed below)
                property bool powerRebootTracking: false
                // Android-edge-back-gesture-style drag from the right edge.
                // Deliberately NOT gated on !LauncherState.promptOpen (see horizTracking/
                // vertTracking/carouselTracking above, which are): it needs to
                // keep working while a power/reboot prompt is armed so
                // there's always a touch-reachable way to let go of it (a
                // tap already works via onClicked below, but the edge-back
                // swipe is the gesture people reach for instinctively) -
                // LauncherState.goBack() checks powerArmed/rebootArmed first, so a
                // completed swipe here disarms instead of navigating.
                property bool backTracking: false
                property real backGrabX: 0
                onClicked: mouse => {
                    if (LauncherState.powerArmed || LauncherState.rebootArmed) {
                        // MouseArea's clicked doesn't care how far the
                        // pointer traveled between press and release - a
                        // horizontal swipe lands here too (the power/reboot
                        // DragHandler only tracks the y axis, so it never
                        // grabs a horizontal drag and steals it away from
                        // this click). Only a real tap should count as
                        // "anything else lets go"; a swipe must do nothing.
                        if (Math.abs(mouse.x - pressX) > 15 || Math.abs(mouse.y - pressY) > 15)
                            return;
                        if (LauncherState.powerArmed)
                            LauncherState.disarmPower();
                        else
                            LauncherState.disarmReboot();
                    } else if (LauncherState.expandedClip)
                        LauncherState.collapseClip();
                    else if (LauncherState.capturingBind)
                        LauncherState.cancelCapture();
                    else
                        input.forceActiveFocus();
                }
                onPressed: mouse => {
                    pressX = mouse.x;
                    pressY = mouse.y;
                    pressTime = Date.now();
                    edgePress = mouse.y <= LauncherState.edgeSwipeZone || mouse.y >= height - LauncherState.edgeSwipeZone;
                    rightEdgePress = mouse.x >= width - LauncherState.edgeSwipeZone;
                    // while a power/reboot prompt is armed, every gesture on
                    // screen belongs to it (see powerRebootTracking below) -
                    // pane/grid navigation and the carousel flick sit out
                    // entirely so they can't fire alongside it
                    const carousel = wallpapersPage.carousel;
                    const inCarousel = onCarousel && carousel.contains(carousel.mapFromItem(backdropArea, mouse.x, mouse.y));
                    carouselTracking = !LauncherState.promptOpen && inCarousel && Settings.gesturesEnabled() && !rightEdgePress;
                    horizTracking = !LauncherState.promptOpen && Settings.gesturesEnabled() && !inCarousel && !rightEdgePress;
                    vertTracking = !LauncherState.promptOpen && Settings.gesturesEnabled() && !onCarousel && !edgePress;

                    powerRebootTracking = Settings.gesturesEnabled() && (LauncherState.promptOpen || edgePress);
                    if (powerRebootTracking) {
                        // an armed prompt pins the zone to itself regardless
                        // of where on screen this press landed - only a
                        // fresh, unarmed edge press still needs to look at
                        // the touch position to decide which prompt (if
                        // either) it's arming
                        LauncherState.dragZone = LauncherState.powerArmed ? "top"
                            : LauncherState.rebootArmed ? "bottom"
                            : mouse.y < LauncherState.edgeSwipeZone ? "top"
                            : mouse.y > height - LauncherState.edgeSwipeZone ? "bottom" : "none";
                        LauncherState.powerDragging = LauncherState.dragZone === "top";
                        LauncherState.rebootDragging = LauncherState.dragZone === "bottom";
                        // only fold in the live raw values when actually
                        // continuing an already-armed prompt's drag - a
                        // fresh, unarmed edge press must start from a clean
                        // baseline. powerRaw/rebootRaw spring back to 0 over
                        // Anim.menu(320)ms on disarm (Behavior enabled once
                        // *Dragging above is false), so a re-swipe from the
                        // edge started before that finishes would otherwise
                        // bake the still-animating leftover value into this
                        // drag's reference point, corrupting it until the
                        // old animation happens to finish on its own.
                        LauncherState.dragGrabY = LauncherState.promptOpen
                            ? mouse.y - LauncherState.powerRaw + LauncherState.rebootRaw
                            : mouse.y;
                    }

                    backTracking = Settings.gesturesEnabled() && rightEdgePress;
                    if (backTracking) {
                        backGrabX = mouse.x;
                        LauncherState.backGrabY = mouse.y;
                        LauncherState.backDragging = true;
                    }
                }
                onPositionChanged: mouse => {
                    if (carouselTracking)
                        LauncherState.carouselDragTo(mouse.x - pressX);
                    if (powerRebootTracking && LauncherState.dragZone !== "none") {
                        const delta = mouse.y - LauncherState.dragGrabY;
                        if (LauncherState.dragZone === "top")
                            LauncherState.powerRaw = Math.max(0, delta);
                        else
                            LauncherState.rebootRaw = Math.max(0, -delta);
                    }
                    if (backTracking)
                        LauncherState.backRaw = Math.max(0, backGrabX - mouse.x);
                }
                onReleased: mouse => {
                    const dx = mouse.x - pressX;
                    const dy = mouse.y - pressY;
                    if (carouselTracking) {
                        const elapsedMs = Math.max(1, Date.now() - pressTime);
                        LauncherState.carouselDragEnd(dx, dx / elapsedMs * 1000);
                    } else if (Math.abs(dx) >= Math.abs(dy)) {
                        // dominant axis only, so a diagonal drag can't fire both
                        if (horizTracking && Math.abs(dx) > 80)
                            LauncherState.cyclePane(dx < 0 ? 1 : -1);
                    } else {
                        if (vertTracking && Math.abs(dy) > 80)
                            LauncherState.pageMove(dy < 0 ? 1 : -1);
                    }
                    horizTracking = false;
                    vertTracking = false;
                    carouselTracking = false;

                    if (powerRebootTracking) {
                        LauncherState.powerDragging = false;
                        LauncherState.rebootDragging = false;
                        if (LauncherState.powerProgress >= 1) {
                            // hold the completed pose and wait for Enter
                            LauncherState.powerArmed = true;
                            LauncherState.powerRaw = LauncherState.powerThreshold;
                        } else {
                            LauncherState.disarmPower(); // springs back up
                        }
                        if (LauncherState.rebootProgress >= 1) {
                            LauncherState.rebootArmed = true;
                            LauncherState.rebootRaw = LauncherState.rebootThreshold;
                        } else {
                            LauncherState.disarmReboot();
                        }
                        LauncherState.dragZone = "none";
                        powerRebootTracking = false;
                    }
                    if (backTracking) {
                        LauncherState.backDragging = false;
                        if (LauncherState.backProgress >= 1)
                            LauncherState.goBack();
                        LauncherState.backRaw = 0; // springs back (no-op if goBack() just changed pane/closed)
                        backTracking = false;
                    }
                }
                onWheel: wheel => {
                    // while a clip is expanded, wheel scrolls its text
                    // instead of the grid underneath - unconditionally
                    // consumed here (even a no-op when the text doesn't
                    // overflow) so it never falls through to pageMove/
                    // navigate and shifts the hidden grid behind the card
                    if (LauncherState.expandedClip !== null) {
                        clipboardPage.scrollExpanded(wheel.angleDelta.y);
                        return;
                    }
                    wheelAcc += wheel.angleDelta.y;
                    while (wheelAcc >= 120) {
                        LauncherState.navigate(0, -1);
                        wheelAcc -= 120;
                    }
                    while (wheelAcc <= -120) {
                        LauncherState.navigate(0, 1);
                        wheelAcc += 120;
                    }
                }

            }

        ClockPage {}

        AppsPage {
            id: appsPage
        }

        WallpapersPage {
            id: wallpapersPage
        }

        ClipboardPage {
            id: clipboardPage
        }

        // Custom pages: one host per enabled upload. Bound to
        // Settings.uploadedPages directly (not LauncherState.orderedPages) for
        // the same delegate-stability reason the Pages settings row is -
        // membership only changes on upload/trash/disk sync, never on a pure
        // reorder.
        Repeater {
            id: customPages
            model: Settings.uploadedPages ?? []

            CustomPageHost {
                onLoaded: root.syncSettingsTabs()
            }
        }

        SettingsPane {
            id: settingsPane
        }

        PowerOverlay {}
    }

    // LauncherState raises these for anything needing this window's item tree
    // or a child process; nothing else connects to them.
    Connections {
        target: LauncherState

        function onFocusRequested(): void {
            input.forceActiveFocus();
        }
        function onExitRequested(): void {
            root.exit();
        }
        function onLaunchRequested(entry: var, rect: var, forceNew: var): void {
            // Second launch of a running app: go to its workspace instead
            // of duplicating it. Shift/Ctrl+Enter forces a new window.
            // Kept outside the morph guard below: a failure here must fall
            // through to a plain launch, never abort it.
            // TEMPORARY trace for the Zed focus issue (remove after):
            // logs which branch every app launch takes.
            const traceId = entry ? (entry.id || entry.name || "?") : "(null)";
            if (!forceNew) {
                try {
                    const addr = root.findExistingWindow(entry);
                    Quickshell.execDetached(["sh", "-c", "echo \"$(date +%T) focus-branch id=" + traceId + " addr=" + (addr || "(none)") + "\" >> /tmp/pibble-focus.log"]);
                    if (addr) {
                        Hyprland.dispatch("hl.dsp.focus({window='address:" + addr + "'})");
                        exit();
                        return;
                    }
                } catch (e) {
                    console.warn("focus-existing failed, launching instead:", e);
                }
            } else {
                Quickshell.execDetached(["sh", "-c", "echo \"$(date +%T) forceNew id=" + traceId + "\" >> /tmp/pibble-focus.log"]);
            }
            // Origin workspace for the launch-desktop pin (see Morph.pinToOrigin):
            // the workspace focused at Enter time, not at map time. Fresh
            // read here - Morph.activeWs (bridged) can lag a switch by a
            // query round-trip, and the launcher stays up across switches.
            let originWs = -1;
            try {
                originWs = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1;
            } catch (e) {}
            if (!(originWs > 0))
                originWs = Morph.activeWs;
            // The morph is garnish - launching is core. Everything new
            // (rect resolution, morph handoff) stays inside this guard, so
            // a failure there can never abort the spawn below. launch()
            // itself is untouched for the same reason.
            let morphed = false;
            try {
                const surfRect = root.morphRect(rect);
                if (surfRect) {
                    // Monitor origin/id from the compositor-cached table
                    // (see Morph.monGeos); live query only as fallback.
                    const sname = root.screen ? root.screen.name : "";
                    const geo = Morph.monGeo(sname);
                    if (geo) {
                        morphed = Morph.spawn(entry, surfRect, geo.id, geo.x, geo.y, originWs);
                    } else {
                        const mon = root.screen ? Hyprland.monitorFor(root.screen) : null;
                        morphed = Morph.spawn(entry, surfRect, mon ? mon.id : -1, mon ? mon.x : 0, mon ? mon.y : 0, originWs);
                    }
                }
                if (!morphed && entry && originWs > 0) {
                    // No tile rect (or bad monitor): no visual row, but the
                    // window still needs its origin tag for the late pin.
                    try {
                        Morph.pinLaunch((entry.startupClass || entry.name || entry.id || ""), originWs);
                    } catch (e) {}
                }
            } catch (e) {
                console.warn("morph handoff failed, launching without morph:", e);
            }
            root.launch(entry, morphed);
        }
        function onBrowserRequested(query: string): void {
            root.openQueryInBrowser(query);
        }
        function onWallpaperRequested(wall: var): void {
            root.applyWallpaper(wall);
        }
        function onClipExpandRequested(clip: var): void {
            root.expandClip(clip);
        }
        function onClipCollapseRequested(): void {
            LauncherState.collapseClip();
        }
        function onDialogFinished(): void {
            root.reopenAfterDialog();
        }
        // LauncherState.query is what every pane filters off; the field below
        // is where the typing actually lands. Clearing the query (a pane
        // switch, a fresh open) has to reach the field too - and stops a
        // debounced keystroke below from resurrecting it afterwards.
        function onQueryChanged(): void {
            // any query change reconciles state: a pending debounced
            // keystroke is either this change itself (just applied) or
            // superseded by it (external clear) - never still armed
            queryDebounce.stop();
            if (input.text !== LauncherState.query)
                input.text = LauncherState.query;
        }
    }

    // Search staging: every keystroke refilters all panes (grids rebuild
    // tiles, the carousel re-scores, clips re-snippet). The filters are
    // gated to the visible pane (see matches/wallpaperMatches/clipMatches),
    // so per-character refilter is cheap enough to publish immediately:
    // interval 0 defers to the next event-loop tick (batching same-tick
    // changes) instead of 200ms after the last keystroke.
    property string pendingQuery: ""
    Timer {
        id: queryDebounce
        interval: 0
        onTriggered: root.applyQuery(root.pendingQuery)
    }
    function applyQuery(text: string): void {
        LauncherState.query = text;
        if (text.length > 0 && LauncherState.pane === "clock") {
            const panes = LauncherState.activePanes;
            const i = panes.indexOf("clock");
            if (i >= 0 && panes.length > 1)
                LauncherState.pane = panes[(i + 1) % panes.length];
        }
        if (LauncherState.pane === "walls" && Settings.wallpaperStyle !== "grid")
            LauncherState.jumpCarousel();
    }
    // Launch acts on the filtered matches, so a Return inside the debounce
    // window must not fire on the stale filter - flush first.
    function flushQuery(): void {
        if (queryDebounce.running) {
            queryDebounce.stop();
            root.applyQuery(root.pendingQuery);
        }
    }

    // Hidden input that captures all typing, mirroring the design's off-screen <input>
    TextInput {
        id: input
        width: 1
        height: 1
        opacity: 0
        focus: true

        // typing from the clock jumps into whatever's next in the cycle
        // order - custom pages included, not just the built-in three:
        // now that a page can read pibble.textInput (see PageContext)
        // there's no reason to skip past one looking for a built-in.
        // The text itself isn't touched here; it's already sitting in
        // this same field, which every page (built-in or custom) reads
        // live off, so the switch alone is enough to carry the query
        // over onto whatever pane it lands on.
        onTextChanged: {
            // stage, don't publish: the shared query (and every pane's
            // filter + tile churn behind it) follows on the next tick via
            // queryDebounce. When the text already matches, there is
            // nothing unpublished - either the sync-back from
            // onQueryChanged above, or typing undone back to the
            // published query - so a stale timer must not outlive it.
            if (text !== LauncherState.query) {
                root.pendingQuery = text;
                queryDebounce.restart();
            } else {
                queryDebounce.stop();
            }
        }

        Keys.onPressed: event => {
            // keybind capture (settings): record which keys are down and
            // the latest chord name they spell, but don't save yet - the
            // bind only commits once every held key is released, so a
            // chord like Ctrl+S can be pressed as a whole instead of
            // firing the instant Ctrl (or S) lands.
            if (LauncherState.capturingBind) {
                event.accepted = true;
                if (event.isAutoRepeat)
                    return;
                if (!LauncherState.captureHeldKeys.includes(event.key))
                    LauncherState.captureHeldKeys = LauncherState.captureHeldKeys.concat([event.key]);
                // always take the newest key event: pressing a different
                // key switches to it outright (A then Ctrl shows "Ctrl",
                // not "A"), and a bare modifier can still be extended by
                // whatever's pressed next into a real chord ("Ctrl" then
                // "S" becomes "Ctrl+S"). A stray unrecognized key leaves
                // the display as-is rather than blanking it.
                const ks = LauncherState.keyName(event);
                LauncherState.captureLive = ks || LauncherState.modifierLabel(event.key) || LauncherState.captureLive;
                return;
            }
            const ks = LauncherState.keyName(event);
            const kb = Settings.keybinds;
            // armed power prompt: Enter powers off, anything else lets go
            if (LauncherState.powerArmed) {
                event.accepted = true;
                // a bare modifier press is not a decision either way
                if ([Qt.Key_Control, Qt.Key_Shift, Qt.Key_Alt, Qt.Key_Meta].includes(event.key))
                    return;
                // compare the unmodified key: Ctrl still held from the
                // Ctrl+P arm must not turn the confirm into "Ctrl+Return"
                const bare = ks.replace(/^(?:Ctrl\+|Alt\+|Shift\+)+/, "");
                if (bare === (kb.launch ?? "Return"))
                    LauncherState.powerOff();
                else
                    LauncherState.disarmPower();
                return;
            }
            // armed reboot prompt: same confirm/cancel dance as power
            if (LauncherState.rebootArmed) {
                event.accepted = true;
                if ([Qt.Key_Control, Qt.Key_Shift, Qt.Key_Alt, Qt.Key_Meta].includes(event.key))
                    return;
                const bare = ks.replace(/^(?:Ctrl\+|Alt\+|Shift\+)+/, "");
                if (bare === (kb.launch ?? "Return"))
                    LauncherState.rebootNow();
                else
                    LauncherState.disarmReboot();
                return;
            }
            if (ks === (kb.exit ?? "Escape")) {
                // layered: expanded clip -> settings -> whole app - see
                // LauncherState.goBack(), also used by the right-edge swipe gesture
                LauncherState.goBack();
                event.accepted = true;
            } else if (ks === (kb.settings ?? "Ctrl+S")) {
                LauncherState.toggleSettings();
                event.accepted = true;
            } else if (ks === (kb.power ?? "Ctrl+P")) {
                LauncherState.playPower();
                event.accepted = true;
            } else if (ks === (kb.reboot ?? "Ctrl+R")) {
                LauncherState.playReboot();
                event.accepted = true;
            } else if (ks === (kb.wallpapers ?? "Ctrl+W")) {
                LauncherState.setPane("walls");
                event.accepted = true;
            } else if (ks === (kb.reverseCycle ?? "Shift+Tab")) {
                LauncherState.cyclePane(-1);
                event.accepted = true;
            } else if (ks === (kb.cycle ?? "Tab")) {
                LauncherState.cyclePane(1);
                event.accepted = true;
            } else if (ks === (kb.launch ?? "Return") || ks === ("Shift+" + (kb.launch ?? "Return")) || ks === ("Ctrl+" + (kb.launch ?? "Return"))) {
                root.flushQuery();
                // Plain Enter focuses the app's workspace when it's already
                // running (see onLaunchRequested); Shift/Ctrl+Enter always
                // spawns a second window instead.
                LauncherState.activate(ks !== (kb.launch ?? "Return"));
                event.accepted = true;
            } else if (ks === (kb.navRight ?? "Right")) {
                LauncherState.navigate(1, 0);
                event.accepted = true;
            } else if (ks === (kb.navLeft ?? "Left")) {
                LauncherState.navigate(-1, 0);
                event.accepted = true;
            } else if (ks === (kb.navDown ?? "Down")) {
                LauncherState.navigate(0, 1);
                event.accepted = true;
            } else if (ks === (kb.navUp ?? "Up")) {
                LauncherState.navigate(0, -1);
                event.accepted = true;
            } else if (ks === (kb.pageNext ?? "PageDown")) {
                LauncherState.pageMove(1);
                event.accepted = true;
            } else if (ks === (kb.pagePrev ?? "PageUp")) {
                LauncherState.pageMove(-1);
                event.accepted = true;
            }
        }

        Keys.onReleased: event => {
            // keybind capture: commit the last chord seen while keys
            // were down, but only once every key of it has come back up
            // - releasing the modifier first (or the main key first)
            // both land here, so either release order works.
            if (LauncherState.capturingBind) {
                event.accepted = true;
                if (event.isAutoRepeat)
                    return;
                LauncherState.captureHeldKeys = LauncherState.captureHeldKeys.filter(k => k !== event.key);
                if (LauncherState.captureHeldKeys.length === 0) {
                    // a bare modifier alone (nothing ever extended it
                    // into a real chord) isn't saveable
                    if (LauncherState.captureLive && !LauncherState.bareModifierLabels.includes(LauncherState.captureLive))
                        SettingsSchema.setBind(LauncherState.capturingBind, LauncherState.captureLive);
                    LauncherState.cancelCapture();
                }
            }
        }
    }
    // Start the reveal only after the mapped window has actually rendered
    // a couple of frames. Animations are wall-clock based, so starting at
    // map time means first-frame latency eats the start of the animation
    // and the hole pops in already partly grown.
    property bool revealStarted: false
    // The warm-up flags themselves live on LauncherState, since the panes are
    // what read them; the frame animations that drive them are here, because
    // they belong to this window's render loop.
    FrameAnimation {
        id: firstFrames
        onTriggered: {
            // caches survive between opens; warm only the first time
            if (LauncherState.warmedOnce) {
                fadeIn.restart();
                stop();
                return;
            }
            if (currentFrame === 1) {
                LauncherState.warmingApps = true;
            } else if (currentFrame >= 3) {
                LauncherState.warmingApps = false;
                LauncherState.warmedOnce = true;
                fadeIn.restart();
                stop();
            }
        }
    }
    // Spread the wallpaper warm-up over one thumbnail per frame: doing
    // all uploads in a single frame caused a ~110ms hitch right as the
    // reveal ended, mid-spring when the user had typed early.
    FrameAnimation {
        running: LauncherState.warmingWallpapers
        onTriggered: {
            LauncherState.wallpaperWarmTick = currentFrame;
            // thumbnails first (one per frame), then the pane's cells
            // (one per frame - each ClippingRectangle is an offscreen
            // render target and costs a chunk of frame time to create)
            if (currentFrame > Wallpapers.list.length + LauncherState.wallpaperPageSize + 4)
                LauncherState.warmingWallpapers = false;
        }
    }
    function startReveal() {
        // `shown` is part of the guard now that the surface is mapped from
        // daemon start: without it the entrance would play once, into a closed
        // launcher, the moment the window first maps.
        if (root.revealStarted || !root.shown || !root.backingWindowVisible)
            return;
        root.revealStarted = true;
        // With the launch animation off there is no reveal to protect
        // from the warm-up frames: show everything on the very first
        // frame. (firstFrames still runs for cache warming; the
        // zero-duration fadeIn it triggers just re-sets these same
        // values.) Gated on noneMode, not the grid tile animStyle -
        // fadeIn's duration comes from Anim.launch()/noneMode, so checking
        // animStyle here let a "none" grid style with a real launch
        // animation snap reveal/opacity to 1 for a frame and then have
        // fadeIn yank them back to 0 to animate in, flickering.
        if (LauncherState.noneMode) {
            LauncherState.reveal = 1;
            content.opacity = 1;
        }
        firstFrames.reset();
        firstFrames.start();
    }
    onBackingWindowVisibleChanged: startReveal()

    // Pre-decode app icons and wallpaper thumbnails while idle, so the
    // drawer's first appearance doesn't stall on cold image loads. The
    // sources/sourceSizes match the visible tiles exactly for cache hits.
    //
    // Held off the window rather than at its origin. These are 1px items, but
    // with preload on they now render for the daemon's whole life, and 1px of
    // *drawn icon* in the top-left corner of an idle surface is a visible dot.
    // Nothing here needs to be on screen - building the items is the point -
    // so they sit where growMask sits.
    Item {
        x: -100000
        y: -100000
        // `visible` is what gets an item's scene-graph nodes built and its
        // textures uploaded; merely existing does nothing, which is why the
        // surface staying mapped (preload) doesn't warm anything on its own.
        // Gated on warmingApps alone, this whole 170-item tree was therefore
        // built on the first open's second frame: a measured 72ms stall
        // landing between the toggle and the reveal, so the first open started
        // its animation at +71ms against +2-18ms for every one after it.
        // Built at daemon start instead, where the same work is invisible, the
        // first open starts at +5ms and daemon start grows an 82ms stall.
        //
        // Only where the surface is already mapped, though: with preload off
        // there is nothing to build into while the launcher is down, and Qt
        // drops the lot on every close regardless, so there this stays what it
        // was - a warm pass that runs during the open it belongs to.
        visible: Settings.preload || LauncherState.warmingApps
        opacity: 0.004
        Repeater {
            model: Apps.warmOrder
            Image {
                required property var modelData
                width: 1
                height: 1
                asynchronous: true
                sourceSize: Qt.size(88, 88)
                source: Icons.url(modelData.icon)
            }
        }
    }
    // No clipboard-thumbnail warm pass. One used to live here, holding every
    // cached clip thumb decoded at 480x640 for the life of the daemon so page
    // flips would hit the pixmap cache. Measured at 120 clips it cost ~264MiB
    // of RSS and bought nothing: identical open stalls, zero stalls paging
    // through the grid either way, and the same proportion of the grid painted
    // 180ms after a flip. The thumbs are already downscaled on disk (see
    // Clipboard's thumbnail pass), so the on-demand decode the tiles do is
    // cheap enough not to need pre-warming.
    Item {
        visible: LauncherState.warmingWallpapers
        opacity: 0.004
        Repeater {
            model: Wallpapers.list
            Image {
                required property int index
                required property var modelData
                width: 1
                height: 1
                visible: LauncherState.wallpaperWarmTick > index
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(480, 270)
                source: "file://" + modelData.thumb
            }
        }
    }

    Component.onCompleted: {
        input.forceActiveFocus();
        syncScreen();
        startReveal();
    }
}

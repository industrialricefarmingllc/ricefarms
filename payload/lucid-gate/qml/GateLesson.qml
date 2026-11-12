import QtQuick
import Quickshell
import Quickshell.Io
import qs
import qs.lucidui
import qs.squircle
import QtWebEngine

// Duolingo, inside the gate.
//
// A persistent WebEngine profile keeps the login between gates.  After each
// load a small probe is installed in the page: it clicks the next lesson on the
// path, watches for the end-of-session slide, and reports both back here.  The
// task is complete when Duolingo itself says the session is over -- no dwell
// timer and no "done" button.
Item {
    id: root

    property var probe: ({})
    property string lastEval: ""
    property string status: "Opening Duolingo…"
    property bool completed: false
    property bool pageLoaded: false
    property bool manualHome: false
    // which output this warm view belongs to
    property string screenName: ""
    // only the view on the current lesson output may probe or complete
    readonly property bool currentLesson: root.screenName === "" || root.screenName === GateCore.lessonTargetScreen
    property string evalResult: ""
    readonly property string placeUrl: "https://www.duolingo.com/learn"
    readonly property string loginUrl: "https://www.duolingo.com/login"

    signal closeRequested()

    Component.onCompleted: {
        view.profile = GateWeb.profile;
        view.settings.showScrollBars = false;
        view.settings.scrollAnimatorEnabled = true;
        if (root.screenName === "" || root.screenName === GateCore.lessonTargetScreen)
            root.open(GateCore.lessonUrl);
        console.log("lucid-gate: lesson created");
    }
    Component.onDestruction: {
        probeTimer.stop();
        console.log("lucid-gate: lesson destroyed");
    }

    Connections {
        target: GateCore

        function onLessonRequestChanged() {
            if (GateCore.lessonOpen && root.currentLesson)
                root.open(GateCore.lessonUrl);
        }
    }

    function open(url) {
        root.completed = false;
        root.pageLoaded = false;
        root.manualHome = false;
        root.probe = ({});
        root.status = "Opening Duolingo…";
        if (root.currentLesson)
            GateCore.lessonPageReady = false;

        const target = (url && String(url) !== "") ? String(url) : root.placeUrl;
        if (String(view.url) === target)
            view.reload();
        else
            view.url = target;

        view.forceActiveFocus();
    }

    function installProbe() {
        if (root.completed || !GateCore.lessonOpen || !root.currentLesson)
            return ;

        view.runJavaScript(probeInstall, (result) => {
            if (result !== "installed" && result !== "already")
                console.log("lucid-gate/duolingo:", result);

        });
        view.runJavaScript("window.__lucidGate && (window.__lucidGate.pauseAuto = "
            + (root.manualHome ? "true" : "false") + ")");
    }

    function readProbe() {
        if (view.loading || root.completed || !GateCore.lessonOpen || !root.currentLesson)
            return ;

        // drive the page-side tick from QML instead of trusting the page's
        // own interval, which some SPA scheduling can starve
        view.runJavaScript("window.__lucidGateTick && window.__lucidGateTick()");
        view.runJavaScript(probeState, (result) => root.absorb(result));
    }

    function absorb(result) {
        try {
            const next = JSON.parse(result);
            if (!next || typeof next !== "object")
                return ;
            if (!next.installed) {
                root.installProbe();
                return ;
            }

            root.probe = next;
            if (next.done && !root.completed) {
                root.completed = true;
                root.status = "Lesson complete";
                probeTimer.stop();
                // the task is finished now; the extra two seconds are only
                // for reading Duolingo's own summary before the card closes
                if (GateCore.sessionFor("duolingo") !== null)
                    GateCore.completeTask("duolingo");
                else
                    GateCore.completeManualDuolingo();

                GateCore.lingerLesson(2000);
                return ;
            }
            if (root.completed)
                return ;

            const course = next.course ? next.course + " · " : "";
            if (next.path && next.path.indexOf("/lesson") === 0)
                root.status = course + "Lesson in progress";
            else if (next.path === "/learn")
                root.status = course + (Number(next.clicks) > 0 ? "Starting the next lesson…" : "Next lesson ready");
            else if (next.path === "/" || String(next.path || "").indexOf("login") >= 0)
                root.status = "Sign in to Duolingo once";
            else
                root.status = "Duolingo";

        } catch (e) {
            root.status = "Reading Duolingo…";
        }
    }

    function close() {
        console.log("lucid-gate: lesson close requested");
        root.closeRequested();
    }

    function goHome() {
        root.manualHome = true;
        view.runJavaScript("window.__lucidGate && (window.__lucidGate.pauseAuto = true)");
        if (String(view.url) === root.placeUrl)
            view.reload();
        else
            view.url = root.placeUrl;
    }

    function goLogin() {
        view.url = root.loginUrl;
    }

    function reloadView() {
        view.reload();
    }

    SquircleClip {
        id: stage

        anchors.fill: parent
        radius: Theme.windowRadius
        smoothing: Prefs.squircleF

        WebEngineView {
            id: view

            anchors.fill: parent
            profile: GateWeb.profile
            url: ""
            focus: true
            opacity: root.pageLoaded ? 1 : 0
            backgroundColor: Theme.isLight ? "#f7f7f7" : "#131f24"

            Behavior on opacity {
                NumberAnimation {
                    duration: Theme.durMedium
                    easing.type: Easing.OutCubic
                }

            }

            onLoadingChanged: (request) => {
                if (request.status === WebEngineView.LoadSucceededStatus) {
                    root.pageLoaded = true;
                    if (root.currentLesson)
                        GateCore.lessonPageReady = true;
                    view.forceActiveFocus();
                    root.installProbe();
                }
            }
            onUrlChanged: {
                GateCore.rememberLessonUrl(String(view.url));
                root.readProbe();
            }
        }

        // Launch-style placeholder: the app's own mark on an opaque tile and
        // the m3 expressive loader until the engine has something to show.
        Item {
            id: placeholder

            anchors.fill: parent
            opacity: root.pageLoaded ? 0 : 1
            visible: opacity > 0.01

            Behavior on opacity {
                NumberAnimation {
                    duration: Theme.durMedium
                    easing.type: Easing.OutCubic
                }

            }

            SquircleRect {
                anchors.fill: parent
                radius: Theme.rad(14)
                fillColor: Theme.surfaceContainer
            }

            // the m3 expressive loader sits *behind* the app's own mark,
            // the way the launcher holds a starting app
            Item {
                readonly property real markSize: Theme.dp(54)

                anchors.centerIn: parent
                width: markSize
                height: width

                // the drawn shape is 0.84 of the item box, so divide by that
                // to make the visible circle's radius 1.66x the app mark
                LoadingIndicator {
                    anchors.centerIn: parent
                    width: parent.markSize * 1.66 / 0.84
                    height: width
                    running: !root.pageLoaded
                }

                Image {
                    anchors.centerIn: parent
                    width: parent.markSize
                    height: width
                    source: GateCore.assetsPath + "/duolingo-owl.png"
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                }

            }

        }

    }

    Timer {
        id: probeTimer

        interval: 750
        repeat: true
        running: !root.completed && GateCore.lessonOpen && root.pageLoaded && root.currentLesson
        triggeredOnStart: true
        onTriggered: root.readProbe()
    }

    // Injected into the page. Idempotent. Runs an observer for the end slide
    // and a one-second tick that starts the next lesson from the path.
    readonly property string probeInstall: `
(function () {
  if (window.__lucidGate && window.__lucidGate.installed) return "already";
  var G = window.__lucidGate = {
    installed: true, done: false, doneAt: 0, path: location.pathname,
    clicks: 0, hint: "", candidates: [], lastClick: 0, loginClicked: false,
    started: 0, course: "", introClicked: false, pauseAuto: false
  };
  if (!document.getElementById("lucid-gate-scrollbars")) {
    var style = document.createElement("style");
    style.id = "lucid-gate-scrollbars";
    style.textContent = "::-webkit-scrollbar{width:0!important;height:0!important}"
      + "html,body{scrollbar-width:none!important;-ms-overflow-style:none!important}";
    (document.head || document.documentElement).appendChild(style);
  }
  function visible(el) {
    if (!el) return false;
    var r = el.getBoundingClientRect();
    return r.width > 8 && r.height > 8 && r.bottom > 0 && r.top < innerHeight;
  }
  function label(el) {
    return String(el.innerText || el.getAttribute("aria-label") || el.getAttribute("title") || "").trim();
  }
  function doneCheck() {
    if (G.done) return;
    var slide = document.querySelector(
      '[data-test="session-complete-slide"], [data-test="session-complete"], [data-test="lesson-complete"]');
    var body = document.body ? document.body.innerText : "";
    var wording = /lesson complete|practice complete|session complete|unit complete/i.test(body);
    if (slide || (G.started && wording)) {
      G.done = true;
      G.doneAt = Date.now();
      G.hint = slide ? "slide" : "text";
    }
  }
  function clickLogin() {
    if (G.loginClicked) return;
    var login = Array.prototype.slice.call(document.querySelectorAll("a, button")).filter(visible).find(function (el) {
      return /log ?in|sign ?in|i already have an account/i.test(label(el));
    });
    if (login) {
      G.loginClicked = true;
      login.click();
    }
  }
  function clickStartBubble() {
    var all = Array.prototype.slice.call(document.querySelectorAll("*")).filter(function (el) {
      var t = (el.innerText || "").trim();
      var r = el.getBoundingClientRect();
      return /^START\\b/i.test(t) && t.length < 24 && r.width > 20 && r.height > 10
        && r.bottom > 0 && r.top < innerHeight;
    });
    var bubble = null, best = 1e9;
    for (var i = 0; i < all.length; i++) {
      var r = all[i].getBoundingClientRect();
      var area = r.width * r.height;
      if (area > 0 && area < best) { best = area; bubble = all[i]; }
    }
    if (!bubble) return false;
    var nodes = Array.prototype.slice.call(document.querySelectorAll('button[data-test*="skill-path-level"]'));
    // the smallest matching element is often the "START +20 XP" label above
    // the node; try every bubble until its centre lands inside a path node
    for (var i = 0; i < all.length; i++) {
      var br = all[i].getBoundingClientRect();
      var cx = br.x + br.width / 2, cy = br.y + br.height / 2;
      for (var j = 0; j < nodes.length; j++) {
        var q = nodes[j].getBoundingClientRect();
        if (cx >= q.x && cx <= q.x + q.width && cy >= q.y && cy <= q.y + q.height) {
          nodes[j].click();
          G.hint = "start:" + (nodes[j].getAttribute("aria-label") || "");
          return true;
        }
      }
    }
    return false;
  }
  // The path often lands on a recap/intro card. Only "START ..." is clicked;
  // CHECK / CONTINUE during exercises are left to the learner.
  function clickLessonIntro() {
    if (G.introClicked) return;
    var next = document.querySelector('[data-test="player-next"]');
    if (!next) return;
    var t = label(next);
    if (/^start\\b/i.test(t)) {
      next.click();
      G.introClicked = true;
      G.hint = "intro:" + t.slice(0, 24);
    }
  }
  function clickNext() {
    if (G.done || G.clicks >= 6 || location.pathname !== "/learn") return;
    if (clickStartBubble()) { G.clicks++; return; }
    var explicit = [
      '[data-test="continue-button"]',
      '[data-test="start-button"]',
      '[data-test="lesson-node"]',
      'a[href*="/lesson"]'
    ];
    for (var i = 0; i < explicit.length; i++) {
      var el = document.querySelector(explicit[i]);
      if (visible(el) && !el.disabled) {
        el.click(); G.clicks++; G.hint = explicit[i]; return;
      }
    }
    var words = /^(continue|start|start lesson|let'?s go|jump back in|resume)$/i;
    var all = Array.prototype.slice.call(document.querySelectorAll("button, a")).filter(visible);
    var matches = all.filter(function (el) {
      var t = label(el);
      return words.test(t) || /^continue/i.test(t);
    });
    G.candidates = matches.slice(0, 8).map(function (el) {
      return { text: label(el).slice(0, 40), tag: el.tagName, test: el.getAttribute("data-test") || "" };
    });
    if (matches.length) {
      matches.sort(function (a, b) {
        var ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();
        return rb.width * rb.height - ra.width * ra.height;
      });
      matches[0].click();
      G.clicks++;
      G.hint = "text:" + label(matches[0]).slice(0, 30);
    }
  }
  function tick() {
    G.path = location.pathname;
    if (G.path.indexOf("/lesson") === 0 && !G.started) G.started = Date.now();
    var m = document.title.match(/Learn\\s+(.+?)\\s+with/i);
    G.course = m ? m[1] : (G.course || "");
    doneCheck();
    if (G.done) return;
    if (G.path === "/" || G.path === "/login") {
      if (!G.loginClicked) clickLogin();
      return;
    }
    if (G.path.indexOf("/lesson") === 0) {
      clickLessonIntro();
      return;
    }
    if (G.pauseAuto) return;
    if (G.path === "/learn" && Date.now() - G.lastClick > 2500) {
      G.lastClick = Date.now();
      clickNext();
    }
  }
  new MutationObserver(doneCheck).observe(document.documentElement, {
    subtree: true, childList: true, characterData: true
  });
  window.__lucidGateTick = tick;
  setInterval(tick, 1000);
  setTimeout(tick, 600);
  return "installed";
})()
`

    IpcHandler {
        target: "gate-duo"

        function probe(): string {
            return JSON.stringify(root.probe);
        }

        function url(): string {
            return view.url;
        }

        function evalJs(code: string): string {
            view.runJavaScript(code, (result) => {
                root.lastEval = String(result);
            });
            return "ok";
        }

        function lastEval(): string {
            return root.lastEval;
        }

        function reload(): string {
            view.reload();
            return "reloading";
        }

        function login(): string {
            view.url = root.loginUrl;
            return "login";
        }

    }

    readonly property string probeState: `
(function () {
  var G = window.__lucidGate;
  if (!G) return JSON.stringify({ installed: false, path: location.pathname, done: false });
  return JSON.stringify({
    installed: true, path: location.pathname, done: G.done, hint: G.hint,
    clicks: G.clicks, candidates: G.candidates, title: document.title,
    course: G.course || "", started: !!G.started, loginClicked: !!G.loginClicked,
    introClicked: !!G.introClicked
  });
})()
`
}

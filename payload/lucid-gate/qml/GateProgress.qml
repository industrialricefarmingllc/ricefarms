import QtQuick
import Quickshell
import Quickshell.Io
import QtWebEngine
import qs

// A background WebEngine that shares the Duolingo profile and polls the
// account's total XP. It is what lets the ledger credit lessons done outside
// this shell (phone, another browser) — the first value seen is the baseline,
// so nothing from before the feature existed is paid out.
Item {
    id: root

    property int xp: -1
    property real at: 0
    property string lastError: ""
    property int reloads: 0

    WebEngineView {
        id: view

        anchors.fill: parent
        // the poller is off-screen; keep its page active instead of letting
        // the engine freeze an unexposed view
        lifecycleState: WebEngineView.LifecycleState.Active
        profile: GateWeb.profile
        url: "https://www.duolingo.com/learn"

        onLoadingChanged: (request) => {
            if (request.status === WebEngineView.LoadSucceededStatus)
                root.install();

        }
        onUrlChanged: root.read()

        Component.onCompleted: {
            if (GateWeb.profile)
                view.profile = GateWeb.profile;

        }
    }

    Connections {
        target: view

        function onProfileChanged() {
            // the singleton hands out its profile just after the shell starts;
            // reload so the page sees the persistent cookies
            if (view.profile)
                view.reload();

        }
        function onLoadingChanged() {
            if (!view.loading)
                settle.restart();
        }
    }

    Timer {
        id: settle

        interval: 4000
        onTriggered: {
            // a logged-out page has no cached account state; give the profile
            // a couple of chances before leaving the poller idle
            if (root.reloads < 2 && root.lastError.indexOf("no user id") >= 0) {
                root.reloads++;
                view.reload();
            }
        }
    }

    // Duolingo no longer resolves /users/me, so the account id is read out of
    // the web app's own cached state (a gzip'd base64 blob). The id is then
    // used against the public user endpoint. Both steps run once per page load.
    function install() {
        view.runJavaScript(`
(function () {
  if (window.__lucidProgress && window.__lucidProgress.timer) return "already";
  var P = window.__lucidProgress = { id: 0, xp: null, at: 0, error: "", timer: 0 };

  P.userId = async function () {
    try {
      var raw = localStorage.getItem("duo.state");
      if (raw) {
        var b64 = String(JSON.parse(raw)).replace(/-/g, "+").replace(/_/g, "/");
        while (b64.length % 4) b64 += "=";
        var bin = Uint8Array.from(atob(b64), function (c) { return c.charCodeAt(0); });
        var text = await new Response(new Blob([bin]).stream()
          .pipeThrough(new DecompressionStream("gzip"))).text();
        var match = text.match(/"id":\\s*(\\d{10,})/);
        if (match) return Number(match[1]);
      }
    } catch (e) {}
    var cookie = document.cookie.match(/(?:^|;\\s*)logged_out_uuid=(\\d+)/);
    return cookie ? Number(cookie[1]) : 0;
  };

  P.poll = async function () {
    try {
      if (!P.id) P.id = await P.userId();
      if (!P.id) throw new Error("no user id");
      var r = await fetch("/2017-06-30/users/" + P.id + "?fields=totalXp,streak",
        { credentials: "include", headers: { "Accept": "application/json" } });
      if (!r.ok) throw new Error("HTTP " + r.status);
      var j = await r.json();
      P.xp = Number(j.totalXp || 0);
      P.at = Date.now();
      P.error = "";
    } catch (e) {
      P.at = Date.now();
      P.error = String(e);
    }
  };

  P.timer = setInterval(P.poll, 60000);
  P.poll();
  return "installed";
})()
`);
    }

    function read() {
        view.runJavaScript("JSON.stringify(window.__lucidProgress || {})", (result) => {
            try {
                const progress = JSON.parse(result);
                if (progress && progress.timer) {
                    root.at = Number(progress.at || 0);
                    root.lastError = String(progress.error || "");
                    if (Number(progress.xp) > 0) {
                        root.xp = Number(progress.xp);
                        GateCore.reportDuoProgress(root.xp);
                    }
                } else {
                    // the page reloaded (or the script was dropped); re-arm
                    root.install();
                }
            } catch (e) {
                root.lastError = "reading progress";
            }
        });
    }

    Timer {
        interval: 20000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.read()
    }

    IpcHandler {
        target: "gate-progress"

        function refresh(): string {
            root.read();
            return "refreshing";
        }

        function state(): string {
            return JSON.stringify({
                "xp": root.xp, "at": root.at, "error": root.lastError,
                "url": String(view.url), "loading": view.loading,
                "title": view.title, "pid": view.renderProcessPid
            });
        }

    }

}

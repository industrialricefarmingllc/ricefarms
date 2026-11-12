pragma Singleton
import QtQuick
import Quickshell
import QtWebEngine

// One durable Duolingo profile for the whole shell lifetime.
//
// The QML profile type is deprecated from Qt 6.9; the prototype form sets the
// persistence properties once, and instance() creates a profile that can be
// handed to views. Keeping this singleton (rather than a profile inside the
// lesson surface) means the cookie jar, local storage and cache stay alive
// between lessons and are flushed normally at shell exit.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property string profilePath: root.home + "/.local/share/lucid-gate/webengine"
    readonly property string cachePath: root.home + "/.cache/lucid-gate/webengine"
    readonly property string userAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    property var profile: null

    WebEngineProfilePrototype {
        id: prototype

        storageName: "lucid-gate-duolingo"
        persistentStoragePath: root.profilePath
        cachePath: root.cachePath
        persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies
        persistentPermissionsPolicy: WebEngineProfile.StoreOnDisk
        httpCacheType: WebEngineProfile.DiskHttpCache
    }

    Component.onCompleted: {
        root.profile = prototype.instance();
        if (root.profile) {
            root.profile.httpUserAgent = root.userAgent;
            root.profile.spellCheckEnabled = false;
        }
        console.log("lucid-gate: web profile", root.profilePath);
    }
}

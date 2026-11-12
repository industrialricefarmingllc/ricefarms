pragma Singleton

import QtQuick
import Quickshell

// Small accessibility helper shared by Lucid's controls.
//
// Qt exposes the widget tree to Orca and friends once the accessibility
// bridge is on (QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1, set by the session).
// This singleton gives the shell one place to speak status changes, so a
// screen reader hears "Muted", "Wallpaper applied" and the like even when the
// visible label does not change.
Singleton {
    id: root

    property bool enabled: (Quickshell.env("QT_LINUX_ACCESSIBILITY_ALWAYS_ON") === "1"
        || Quickshell.env("QT_ACCESSIBILITY") === "1")

    // Announce without stealing focus. `urgent` interrupts the current
    // utterance, for errors and destructive confirmations.
    function announce(message, urgent) {
        if (message === undefined || message === null || String(message) === "")
            return ;
        if (typeof Prefs !== "undefined" && Prefs.a11yAnnounce === false)
            return ;

        try {
            Accessible.announce(String(message), urgent ? Accessible.Assertive : Accessible.Polite);
        } catch (e) {
            // older Qt: leave the message in the log rather than break a control
            console.log("a11y:", message);
        }
    }

    // The name a control should expose when its visible label is only a glyph.
    function iconName(icon, fallback) {
        if (icon === undefined || icon === null || icon === "")
            return fallback || "";

        const words = String(icon).replace(/[_-]+/g, " ").trim();
        return words === "" ? (fallback || "") : words;
    }

}

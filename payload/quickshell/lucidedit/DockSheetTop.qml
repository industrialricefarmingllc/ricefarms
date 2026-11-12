import QtQuick
import qs
import qs.lucidprefs

// the top of the dock's sheet: whether it shows at all, and the launcher opened out
// of it to see it with what is set below
SettingCard {
    SettingRow {
        title: Tr.t("Show the dock")
        description: Prefs.dockEnabled ? Tr.t("Off, the dock goes, and the launcher opens from the bottom edge on its own.") : Tr.t("The dock is switched off.")
        showDivider: false

        M3Switch {
            checked: Prefs.dockEnabled
            onToggled: (v) => {
                return Prefs.setSurface("dockEnabled", v);
            }
        }

    }

    SettingRow {
        title: Tr.t("Try the launcher")
        description: Tr.t("Opens it out of the dock, so you can see it with the style and sizes below.")
        showDivider: false

        M3Button {
            text: Tr.t("Open")
            variant: "tonal"
            onClicked: Edit.launcherRequested()
        }

    }

    SettingRow {
        title: Tr.t("Move it")
        description: Tr.t("On the desktop, drag the handle above the dock up to float it higher, or down into the bottom edge to make it a notch.")
        enabled: Prefs.dockEnabled
        showDivider: false
    }

}

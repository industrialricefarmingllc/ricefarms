import QtQuick
import Quickshell
import qs
import qs.lucidui

Column {
    id: page

    // the XDG entries meant for this desktop, and the rest
    readonly property var forHere: Startup.xdgEntries.filter((e) => {
        return e.applies;
    })
    // two packages can ship the same entry under two names
    readonly property var notHere: {
        const seen = {};
        return Startup.xdgEntries.filter((e) => {
            const k = e.name + "\n" + e.reason;
            if (e.applies || seen[k])
                return false;

            seen[k] = true;
            return true;
        });
    }
    readonly property int movableApps: Startup.movable.filter((l) => {
        return l.file === "autostart";
    }).length
    readonly property int movableVars: Startup.movable.length - page.movableApps
    property string newName: ""
    property string newValue: ""
    readonly property string newProblem: page.newName === "" ? "" : Startup.nameProblem(page.newName, -1)
    // a warning while typing, which still lets it be added
    readonly property string newAdvice: page.newName === "" ? "" : Startup.adviceFor(page.newName, page.newValue)

    function addVar() {
        if (Startup.addVar(page.newName, page.newValue)) {
            nameField.clear();
            valueField.clear();
            page.newName = "";
            page.newValue = "";
        }
    }

    function twinText(program) {
        const e = Startup.xdgTwin(program);
        return e ? "\"" + e.name + "\", under Apps that start themselves, opens it too, so it starts twice." : "";
    }

    function count(n, one, many) {
        return n + " " + (n === 1 ? one : many);
    }

    function fileName(l) {
        return "modules/" + l.file + ".lua";
    }

    spacing: Theme.dp(18)
    Component.onCompleted: Startup.refresh()

    SettingCard {
        visible: Startup.moduleProbed && !Startup.moduleInstalled

        SettingRow {
            title: "Not set up"
            warning: "This page writes ~/.config/hypr/lucid-startup.lua, and your Hyprland config does not read it. Run the installer with --with-hypr, or copy Lucid's modules/startup.lua into ~/.config/hypr/modules/ and add require(\"modules.startup\") to hyprland.lua, after modules.env."
            showDivider: false
        }

    }

    // lines added to the two files by hand: one press puts them here, where
    // they can be switched off and changed like the rest
    SettingCard {
        visible: Startup.moduleInstalled && Startup.movable.length > 0

        SettingRow {
            title: "Found in your Hyprland config"
            description: [page.movableApps > 0 ? page.count(page.movableApps, "app opened", "apps opened") + " at login" : "", page.movableVars > 0 ? page.count(page.movableVars, "variable", "variables") : ""].filter((x) => {
                return x !== "";
            }).join(" and ") + ", set by hand in your Hyprland files. Move them here to switch them off and change them on this page; the lines stay in the files, commented out."

            M3Button {
                text: "Move them here"
                variant: "filled"
                onClicked: Startup.take(Startup.movable, true)
            }

        }

    }

    SettingCard {
        title: "APPS"
        subtitle: "Opened each time you log in, after the shell is up."

        Repeater {
            model: Startup.apps

            SettingRow {
                id: appRow

                required property var modelData
                required property int index
                readonly property string twin: modelData.on !== false ? page.twinText(Startup.programOf(modelData.cmd)) : ""

                title: modelData.name || modelData.cmd
                monoTitle: !modelData.entry
                description: modelData.cmd === Startup.ownCommand(modelData) ? "" : modelData.cmd
                warning: appRow.twin
                stacked: appRow.twin !== ""

                Row {
                    spacing: Theme.dp(4)

                    M3Button {
                        visible: appRow.twin !== ""
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Keep the other one"
                        variant: "tonal"
                        onClicked: Startup.setApp(appRow.index, {
                            "on": false
                        })
                    }

                    M3IconButton {
                        anchors.verticalCenter: parent.verticalCenter
                        iconPath: "play_arrow"
                        onClicked: Startup.runApp(appRow.index)
                    }

                    M3IconButton {
                        anchors.verticalCenter: parent.verticalCenter
                        iconPath: "delete"
                        destructive: true
                        onClicked: Startup.removeApp(appRow.index)
                    }

                    M3Switch {
                        anchors.verticalCenter: parent.verticalCenter
                        checked: appRow.modelData.on !== false
                        onToggled: (v) => {
                            return Startup.setApp(appRow.index, {
                                "on": v
                            });
                        }
                    }

                }

            }

        }

        // what modules/autostart.lua starts, in the same list with a button
        // that brings it here, or opens the file when it is more than a line
        Repeater {
            model: Startup.configApps

            SettingRow {
                id: lineRow

                required property var modelData
                readonly property string twin: page.twinText(modelData.program)

                title: modelData.program || "A line of Lua"
                monoTitle: true
                description: "In " + page.fileName(modelData) + ": " + modelData.cmd
                warning: lineRow.twin
                stacked: true

                Row {
                    spacing: Theme.dp(8)

                    M3Button {
                        visible: lineRow.twin !== ""
                        text: "Keep the other one"
                        variant: "tonal"
                        onClicked: Startup.take([lineRow.modelData], false)
                    }

                    M3Button {
                        visible: lineRow.modelData.simple
                        text: "Move here"
                        variant: "text"
                        iconPath: "add"
                        onClicked: Startup.take([lineRow.modelData], true)
                    }

                    M3Button {
                        visible: !lineRow.modelData.simple
                        text: "Open the file"
                        variant: "text"
                        iconPath: "open_in_new"
                        onClicked: Quickshell.execDetached(["xdg-open", lineRow.modelData.path])
                    }

                }

            }

        }

        SettingRow {
            title: Startup.apps.length + Startup.configApps.length > 0 ? "Add another" : "Nothing opens at login yet"
            description: Startup.apps.length + Startup.configApps.length > 0 ? "Pick an installed app, or type a command and press Enter." : "Add what you open first thing every day, such as a chat app, a music player or a sync client, and it is waiting for you when you log in."
            stacked: true

            Row {
                width: parent.width
                spacing: Theme.dp(10)

                M3Button {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Add an app"
                    variant: "tonal"
                    iconPath: "add"
                    onClicked: Prefs.appPickerRequested(Startup.pickerKey)
                }

                M3TextField {
                    id: commandField

                    width: Math.min(parent.width - x, Theme.dp(420))
                    placeholder: "Or a command, such as nextcloud --background"
                    commitOnBlur: false
                    onAccepted: (value) => {
                        Startup.addCommand(value);
                        commandField.clear();
                    }
                    onCancelled: commandField.clear()
                }

            }

        }

    }

    SettingCard {
        title: "APPS THAT START THEMSELVES"
        subtitle: "Turning on \"start at login\" or the like inside an app puts it here, and some packages add one for every desktop."

        SettingRow {
            title: Startup.xdgBySession ? "Started by your session" : "Start them with Hyprland"
            description: Startup.xdgBySession ? "Your session manager already starts these, so the switches below are all there is to it." : "Hyprland on its own does not start these, so an app's own \"start at login\" does nothing. On, Lucid starts them at your next login the way a desktop session would."
            resetKey: Startup.xdgBySession ? "" : "startupXdg"

            M3Switch {
                visible: !Startup.xdgBySession
                checked: Prefs.startupXdg
                onToggled: (v) => {
                    return Prefs.startupXdg = v;
                }
            }

        }

        SettingRow {
            title: "Apps"
            description: !Startup.xdgProbed ? "Reading…" : (page.forHere.length === 0 ? "None for this desktop." : "Switching one off hides it for you alone, as any desktop does; the system's copy is left as it is.")
            stacked: true
            enabled: Startup.xdgStarts && !Startup.xdgBusy
            disabledReason: Startup.xdgBusy ? "Saving…" : "Not started at the moment: the switch above is off."

            Column {
                width: parent.width
                spacing: Theme.dp(14)

                Repeater {
                    model: page.forHere

                    CheckLine {
                        required property var modelData

                        width: parent.width
                        label: modelData.name + (modelData.installed ? "" : "  (not installed)")
                        icon: modelData.icon ? Quickshell.iconPath(modelData.icon, true) : ""
                        checked: modelData.enabled
                        enabled: !Startup.xdgBusy
                        onToggled: Startup.setXdg(modelData.id, !checked)
                    }

                }

            }

        }

        SettingRow {
            visible: page.notHere.length > 0
            title: "Not started here"
            description: page.notHere.map((e) => {
                return e.name + " (" + e.reason + ")";
            }).join(", ")
            stacked: true
            showDivider: false
        }

    }

    SettingCard {
        title: "ENVIRONMENT VARIABLES"
        subtitle: "Settings every app reads as it starts. Apps from keybinds see a change at once; the dock and the launcher at your next login."

        Repeater {
            model: Startup.vars

            SettingRow {
                id: varRow

                required property var modelData
                required property int index
                readonly property string problem: Startup.nameProblem(modelData.name, index)
                readonly property string state: Startup.varState(modelData)

                title: modelData.name
                monoTitle: true
                stacked: true
                description: varRow.state === "active" ? "In force." : (varRow.state === "pending" ? "Set. The dock and the launcher pick it up at your next login." : "")
                readonly property string advice: Startup.adviceFor(modelData.name, modelData.value)

                warning: varRow.problem !== "" ? varRow.problem : (varRow.advice !== "" ? varRow.advice : (modelData.name === "PATH" && modelData.on !== false ? "Replaces the whole search path: put the current one in it too, or apps stop being found." : ""))

                Row {
                    width: parent.width
                    spacing: Theme.dp(4)

                    M3TextField {
                        width: Math.min(parent.width - Theme.dp(110), Theme.dp(520))
                        text: varRow.modelData.value
                        placeholder: "Value"
                        onAccepted: (value) => {
                            return Startup.setVar(varRow.index, {
                                "value": value
                            });
                        }
                    }

                    M3IconButton {
                        anchors.verticalCenter: parent.verticalCenter
                        iconPath: "delete"
                        destructive: true
                        onClicked: Startup.removeVar(varRow.index)
                    }

                    M3Switch {
                        anchors.verticalCenter: parent.verticalCenter
                        checked: varRow.modelData.on !== false
                        onToggled: (v) => {
                            return Startup.setVar(varRow.index, {
                                "on": v
                            });
                        }
                    }

                }

            }

        }

        Repeater {
            model: Startup.configVars

            SettingRow {
                id: envLine

                required property var modelData

                title: modelData.simple ? modelData.name : "A line of Lua"
                monoTitle: true
                description: "In " + page.fileName(modelData) + (modelData.simple ? ", set to " + modelData.value : ": " + modelData.text.trim())
                warning: modelData.simple ? Startup.adviceFor(modelData.name, modelData.value) : ""
                stacked: envLine.warning !== ""

                M3Button {
                    text: envLine.modelData.simple ? "Move here" : "Open the file"
                    variant: "text"
                    iconPath: envLine.modelData.simple ? "add" : "open_in_new"
                    onClicked: {
                        if (envLine.modelData.simple)
                            Startup.take([envLine.modelData], true);
                        else
                            Quickshell.execDetached(["xdg-open", envLine.modelData.path]);
                    }
                }

            }

        }

        SettingRow {
            visible: Startup.lingering.length > 0
            title: "Still set until you log in again"
            description: Startup.lingering.join(", ") + ": taken off the list, but apps opened from now on still get " + (Startup.lingering.length === 1 ? "it" : "them") + " until the next login."
        }

        SettingRow {
            title: "Add a variable"
            stacked: true
            warning: page.newProblem !== "" ? page.newProblem : page.newAdvice

            Row {
                width: parent.width
                spacing: Theme.dp(10)

                M3TextField {
                    id: nameField

                    width: Theme.dp(220)
                    placeholder: "NAME"
                    commitOnBlur: false
                    error: page.newProblem !== ""
                    onEdited: (value) => {
                        return page.newName = value.trim();
                    }
                    onAccepted: page.addVar()
                }

                M3TextField {
                    id: valueField

                    width: Math.min(parent.width - x - Theme.dp(110), Theme.dp(300))
                    placeholder: "value"
                    commitOnBlur: false
                    onEdited: (value) => {
                        return page.newValue = value;
                    }
                    onAccepted: page.addVar()
                }

                M3Button {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Add"
                    variant: "filled"
                    enabled: page.newName !== "" && page.newProblem === ""
                    onClicked: page.addVar()
                }

            }

        }

        SettingRow {
            title: "Suggested for this machine"
            description: !Startup.configProbed ? "Looking…" : (Startup.suggestions.length > 0 ? "Each one fixes something Lucid found here." : "Nothing this machine needs. Lucid suggests a variable only when it finds what the variable fixes: Java apps, a machine with an NVIDIA card alone, a screen scaled to 2× or more.")
            stacked: Startup.suggestions.length > 0

            Column {
                width: parent.width
                spacing: Theme.dp(14)

                Repeater {
                    model: Startup.suggestions

                    Item {
                        id: tip

                        required property var modelData

                        width: parent.width
                        height: Math.max(tipText.implicitHeight, tipAdd.implicitHeight)

                        Column {
                            id: tipText

                            anchors.left: parent.left
                            anchors.right: tipAdd.left
                            anchors.rightMargin: Theme.dp(16)
                            spacing: Theme.dp(2)

                            Text {
                                width: parent.width
                                text: tip.modelData.name + "=" + tip.modelData.value
                                color: Theme.text
                                font.family: "monospace"
                                font.pixelSize: Theme.fontBody
                                elide: Text.ElideRight
                            }

                            Text {
                                width: parent.width
                                text: tip.modelData.why
                                color: Theme.subtext
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontBodySm
                                wrapMode: Text.Wrap
                            }

                        }

                        M3Button {
                            id: tipAdd

                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Add"
                            variant: "tonal"
                            iconPath: "add"
                            onClicked: Startup.addVar(tip.modelData.name, tip.modelData.value)
                        }

                    }

                }

            }

        }

        SettingRow {
            title: "Cursor, icon and Qt theme"
            description: "Their variables are set from Settings → Environment, with the themes themselves."
            showDivider: false

            M3Button {
                text: "Open"
                variant: "text"
                onClicked: Prefs.settingsRequested("environment")
            }

        }

    }

}

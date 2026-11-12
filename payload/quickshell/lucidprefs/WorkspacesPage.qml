import QtQuick
import qs
import qs.lucidui

Column {
    id: page

    readonly property var blurbs: ({
        "special": "shows it, and puts away any other workspace that is up. " + Specials.keysText(Specials.stashKeys) + " parks the window you are in here, and sends it back out again.",
        "music": "puts your player over whatever you are doing.",
        "comms": "brings up chat and mail, out of the way until you want them.",
        "todo": "brings up your list, wherever you are.",
        "sysmon": "shows what the machine is up to."
    })
    readonly property var kinds: ({
        "music": "music players",
        "comms": "chat and mail apps",
        "todo": "to-do apps",
        "sysmon": "system monitors"
    })

    // the marks offered for a workspace you make, in the order they are shown
    readonly property var glyphChoices: ["apps", "layers", "web", "mail", "chat", "code", "terminal", "edit_note", "checklist", "content_paste", "music_note", "graphic_eq", "movie", "videocam", "tv", "photo_library", "sports_esports", "folder", "archive", "build", "settings", "monitor_heart", "host", "security", "print", "mic"].filter((g) => {
        return Specials.glyphs[g] !== undefined;
    })
    // "" hides the form, "+" is a new workspace, anything else the one being edited
    property string formKey: ""
    property string formName: ""
    property string formGlyph: "apps"
    readonly property bool formNew: page.formKey === "+"

    function openForm(key) {
        const s = key === "+" ? null : Specials.space(key);
        page.formName = s ? s.label : "";
        page.formGlyph = s ? s.glyph : "apps";
        page.formKey = key;
        nameField.focusInput();
    }

    function submitForm() {
        const name = page.formName.trim();
        if (name === "")
            return ;

        if (page.formNew) {
            const key = Specials.create(name, page.formGlyph);
            page.formKey = "";
            // straight on to its key, which is the one thing it cannot work without
            if (key !== "")
                Keybinds.newRequested(Specials.newBind(key));

        } else {
            Specials.rename(page.formKey, name, page.formGlyph);
            page.formKey = "";
        }
    }

    function blurb(key) {
        if (page.blurbs[key] !== undefined)
            return page.blurbs[key];

        const names = Specials.chosenNames(key);
        return names.length > 0 ? "brings up " + names.join(", ") + "." : "brings up the apps you give it below.";
    }

    function keyLine(key) {
        const keys = Specials.keysOf(key);
        return (keys.length > 0 ? Specials.keysText(keys) : "No key yet. Its key") + " " + page.blurb(key);
    }

    function known(key) {
        const names = [];
        for (const a of Specials.catalog[key] || []) {
            if (names.indexOf(a.name) === -1)
                names.push(a.name);

        }
        return names.length > 1 ? names.slice(0, -1).join(", ") + " or " + names[names.length - 1] : names.join("");
    }

    spacing: Theme.dp(26)

    SettingCard {
        visible: Specials.moduleProbed && !Specials.moduleInstalled

        SettingRow {
            title: Tr.t("The keys are not set up")
            warning: Tr.t("These workspaces come with Lucid's Hyprland config, and yours does not load it. Run the installer with --with-hypr, or copy modules/specials.lua and the special workspace binds from Lucid's modules/binds.lua into your own.")
            showDivider: false
        }

    }

    SettingCard {
        title: Tr.t("WORKSPACES")
        subtitle: Tr.t("Each one slides over the workspace you are on, and the same keys put it away again.")

        Repeater {
            model: Specials.spaces.map((s) => {
                return s.key;
            })

            SettingRow {
                id: spaceRow

                required property string modelData
                // a deleted workspace's row outlives it for a moment
                readonly property var space: Specials.space(modelData) || {
                    "key": modelData,
                    "label": "",
                    "own": true,
                    "apps": ""
                }
                readonly property var bind: Specials.bindOf(modelData)

                title: space.label
                resetKey: space.own ? "" : space.pref
                description: page.keyLine(modelData)

                Row {
                    spacing: Theme.dp(4)

                    M3Button {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: Specials.keysOf(spaceRow.modelData).length === 0 && Keybinds.loaded && !Keybinds.missing
                        text: spaceRow.bind ? Tr.t("Edit key") : Tr.t("Set a key")
                        variant: "text"
                        onClicked: {
                            if (spaceRow.bind)
                                Keybinds.editRequested(spaceRow.bind.id);
                            else
                                Keybinds.newRequested(Specials.newBind(spaceRow.modelData));
                        }
                    }

                    M3IconButton {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: spaceRow.space.own === true
                        iconPath: "edit"
                        onClicked: page.openForm(spaceRow.modelData)
                    }

                    M3IconButton {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: spaceRow.space.own === true
                        destructive: true
                        iconPath: "delete"
                        onClicked: Prefs.askConfirm(Tr.t("Delete ") + spaceRow.space.label + "?", Tr.t("Its windows come back to the workspace you are on") + (spaceRow.bind ? Tr.t(", and its key (") + Keybinds.tokens(spaceRow.bind.keys).join(" + ") + Tr.t(") is removed from keybinds.json") : "") + ".", Tr.t("Delete"), "special-delete:" + spaceRow.modelData)
                    }

                    M3Switch {
                        anchors.verticalCenter: parent.verticalCenter
                        checked: Specials.isOn(spaceRow.modelData)
                        onToggled: (v) => {
                            return Specials.setOn(spaceRow.modelData, v);
                        }
                    }

                }

            }

        }

        SettingRow {
            visible: page.formKey === ""
            title: Tr.t("Make your own")
            description: Tr.t("A workspace of your own, with its own key, mark and apps.")
            showDivider: false

            M3Button {
                text: Tr.t("New workspace")
                variant: "tonal"
                iconPath: "add"
                onClicked: page.openForm("+")
            }

        }

        SettingRow {
            visible: page.formKey !== ""
            title: page.formNew ? Tr.t("New workspace") : Tr.t("Edit ") + (Specials.space(page.formKey) || {
                "label": ""
            }).label
            description: page.formNew ? Tr.t("A name, and the mark it shows in the bar. Its key comes next, and its apps are added below.") : Tr.t("A name, and the mark it shows in the bar.")
            stacked: true
            showDivider: false

            Column {
                width: parent.width
                spacing: Theme.dp(16)

                M3TextField {
                    id: nameField

                    width: Math.min(parent.width, Theme.dp(360))
                    placeholder: Tr.t("Notes")
                    text: page.formName
                    commitOnBlur: false
                    error: page.formName.length > 0 && page.formName.trim() === ""
                    onEdited: (v) => {
                        return page.formName = v;
                    }
                    onAccepted: (v) => {
                        page.formName = v;
                        page.submitForm();
                    }
                    onCancelled: page.formKey = ""
                }

                Flow {
                    width: parent.width
                    spacing: Theme.dp(6)

                    Repeater {
                        model: page.glyphChoices

                        Rectangle {
                            id: glyphTile

                            required property string modelData
                            readonly property bool picked: page.formGlyph === modelData

                            width: Theme.dp(40)
                            height: Theme.dp(40)
                            radius: Theme.radiusSm
                            color: glyphTile.picked ? Theme.accent : (glyphArea.containsMouse ? Theme.bgHover : Theme.bgTile)

                            Icon {
                                anchors.centerIn: parent
                                name: Specials.glyphName(glyphTile.modelData)
                                size: Theme.dp(22)
                                fill: 1
                                color: glyphTile.picked ? Theme.fgAccent : Theme.subtext
                            }

                            MouseArea {
                                id: glyphArea

                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: page.formGlyph = glyphTile.modelData
                            }

                        }

                    }

                }

                Row {
                    spacing: Theme.dp(8)

                    M3Button {
                        text: page.formNew ? Tr.t("Create") : Tr.t("Save")
                        variant: "filled"
                        enabled: page.formName.trim() !== ""
                        onClicked: page.submitForm()
                    }

                    M3Button {
                        text: Tr.t("Cancel")
                        variant: "text"
                        onClicked: page.formKey = ""
                    }

                }

            }

        }

    }

    SettingCard {
        title: Tr.t("APPS")
        subtitle: Tr.t("The key starts whichever of these is not running yet. Anything else you open while a workspace is up stays in it too.")

        Repeater {
            model: ["music", "comms", "todo", "sysmon"].concat(Specials.ownSpaces.map((s) => {
                return s.key;
            }))

            SettingRow {
                id: appsRow

                required property string modelData
                // a deleted workspace's row outlives it for a moment
                readonly property var space: Specials.space(modelData) || {
                    "key": modelData,
                    "label": "",
                    "own": true,
                    "apps": ""
                }
                readonly property var apps: {
                    const out = (Specials.available[modelData] || []).map((a) => {
                        return a.id;
                    });
                    // an added app is only in the list while it is ticked
                    for (const id of Specials.chosen(modelData)) {
                        if (Specials.isCustom(id) && out.indexOf(id) === -1)
                            out.push(id);

                    }
                    return out;
                }

                title: space.label
                resetKey: space.own ? "" : space.apps
                stacked: true
                enabled: Specials.isOn(modelData)
                disabledReason: space.label + " is switched off above, so its key does nothing."
                description: apps.length > 0 ? "" : (space.own ? Tr.t("Nothing yet. Add the apps its key should bring up.") : Tr.t("None of the ") + page.kinds[modelData] + Tr.t(" Lucid knows are installed: ") + page.known(modelData) + ".")

                Column {
                    width: parent.width
                    spacing: Theme.dp(14)

                    Repeater {
                        model: appsRow.apps

                        CheckLine {
                            required property string modelData
                            readonly property var app: Specials.appById(appsRow.modelData, modelData)

                            label: app ? app.name : modelData
                            icon: Specials.iconOf(appsRow.modelData, modelData)
                            enabled: appsRow.enabled
                            checked: Specials.isChosen(appsRow.modelData, modelData)
                            onToggled: Specials.setChosen(appsRow.modelData, modelData, !checked)
                        }

                    }

                    M3Button {
                        text: Tr.t("Add an app")
                        variant: "text"
                        iconPath: "add"
                        enabled: appsRow.enabled
                        onClicked: Prefs.appPickerRequested(appsRow.modelData)
                    }

                }

            }

        }

    }

    SettingCard {
        title: Tr.t("BEHAVIOUR")

        SettingRow {
            title: Tr.t("Keep apps in their workspace")
            resetKey: "specialKeepApps"
            description: Tr.t("The apps picked above always open inside their workspace, from the launcher and the dock too, and the key pulls them back in if you moved them out.")

            M3Switch {
                checked: Prefs.specialKeepApps
                onToggled: (v) => {
                    return Prefs.specialKeepApps = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Put away on workspace change")
            resetKey: "specialHideOnSwitch"
            description: Tr.t("Switching to another workspace hides whatever is up, instead of carrying it along over the next one.")

            M3Switch {
                checked: Prefs.specialHideOnSwitch
                onToggled: (v) => {
                    return Prefs.specialHideOnSwitch = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Dim behind")
            resetKey: "specialDim"
            description: Tr.t("How far the workspace underneath darkens while one is up.")
            stacked: true

            M3Slider {
                width: parent.width
                from: 0
                to: 60
                stepSize: 5
                suffix: "%"
                value: Math.round(Prefs.specialDim * 100)
                onMoved: (v) => {
                    return Prefs.specialDim = v / 100;
                }
            }

        }

        SettingRow {
            title: Tr.t("Blur behind")
            resetKey: "specialBlur"
            description: Tr.t("Blur the workspace underneath as well. It is redrawn blurred on every frame while one is up, so it costs more than dimming alone.")

            M3Switch {
                checked: Prefs.specialBlur
                onToggled: (v) => {
                    return Prefs.specialBlur = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Margin around")
            resetKey: "specialGaps"
            description: Tr.t("Room between the windows and the edges of the screen, so what is underneath shows around them like a card. At 0 they keep the gaps of any other workspace.")
            stacked: true
            showDivider: false

            M3Slider {
                width: parent.width
                from: 0
                to: 200
                stepSize: 10
                suffix: " px"
                value: Prefs.specialGaps
                onMoved: (v) => {
                    return Prefs.specialGaps = Math.round(v);
                }
            }

        }

    }

    SettingCard {
        title: Tr.t("RESET")

        SettingRow {
            title: Tr.t("Reset special workspaces")
            description: Tr.t("Every workspace back on, each one back to the first of its apps that is installed, and the behaviour above back to how it ships. The workspaces you made stay as they are.")
            showDivider: false

            M3Button {
                text: Tr.t("Reset")
                variant: "text"
                destructive: true
                onClicked: Prefs.askReset(Tr.t("Reset special workspaces?"), Tr.t("Every workspace goes back on, each one back to the first of its apps that is installed, and the behaviour settings back to how they ship."), Prefs.resetSpecialsToken)
            }

        }

    }

}

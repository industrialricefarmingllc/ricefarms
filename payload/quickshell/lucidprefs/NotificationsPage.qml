import QtQuick
import Quickshell
import qs

Column {
    id: page

    property int tick: 0
    readonly property bool quietNow: {
        page.tick;
        return Prefs.inQuietWindow(Loc.now());
    }
    readonly property string quietDescription: {
        if (!Prefs.quietHours)
            return "Hold popups back between two times every day. They still collect in the list.";

        var span = Prefs.minutesText(Prefs.quietFrom) + " to " + Prefs.minutesText(Prefs.quietTo);
        return page.quietNow ? "Quiet now — " + span + " every day." : "Quiet from " + span + " every day.";
    }
    readonly property string clearLabel: Prefs.liveNotifCount === 0 ? "Nothing to clear" : (Prefs.liveNotifCount === 1 ? "Clear 1 notification" : "Clear " + Prefs.liveNotifCount + " notifications")
    // apps you have muted are always listed, even ones this session has not seen
    readonly property var appList: {
        var seen = Prefs.seenApps.slice();
        for (var i = 0; i < Prefs.mutedApps.length; i++) {
            if (seen.indexOf(Prefs.mutedApps[i]) === -1)
                seen.push(Prefs.mutedApps[i]);

        }
        return seen.sort((a, b) => {
            return a.toLowerCase().localeCompare(b.toLowerCase());
        });
    }

    spacing: Theme.dp(26)

    // only for the quiet-hours readout, so it can idle when there is none
    Timer {
        interval: 20000
        repeat: true
        running: Prefs.quietHours
        triggeredOnStart: true
        onTriggered: page.tick++
    }

    SettingCard {
        title: Tr.t("POPUPS")

        SettingRow {
            title: Tr.t("Show popups")
            resetKey: "toastEnabled"
            enabled: Prefs.barNotifications
            disabledReason: "Notifications are switched off, so nothing is shown or collected."
            description: Tr.t("Slide a notification out of the bar as it arrives. With this off they go straight to the list.")

            M3Switch {
                checked: Prefs.toastEnabled
                enabled: Prefs.barNotifications
                onToggled: (v) => {
                    return Prefs.toastEnabled = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("How many at once")
            resetKey: "toastMaxVisible"
            enabled: Prefs.barNotifications && Prefs.toastEnabled
            disabledReason: "Popups are switched off."
            description: Tr.t("A burst of notifications stacks under the bar. Anything past this waits in the list instead.")
            stacked: true

            M3Slider {
                width: parent.width
                from: 1
                to: 6
                stepSize: 1
                enabled: Prefs.barNotifications && Prefs.toastEnabled
                value: Prefs.toastMaxVisible
                onMoved: (v) => {
                    return Prefs.toastMaxVisible = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("How long one stays")
            resetKey: "toastTimeout"
            enabled: Prefs.barNotifications && Prefs.toastEnabled
            disabledReason: "Popups are switched off."
            description: Tr.t("The time a popup is left on screen when the application does not ask for something else.")
            stacked: true

            M3Slider {
                width: parent.width
                from: 1
                to: 30
                stepSize: 1
                suffix: " s"
                enabled: Prefs.barNotifications && Prefs.toastEnabled
                value: Prefs.toastTimeout
                onMoved: (v) => {
                    return Prefs.toastTimeout = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Let applications set their own")
            resetKey: "toastUseAppTimeout"
            enabled: Prefs.barNotifications && Prefs.toastEnabled
            disabledReason: "Popups are switched off."
            description: Tr.t("Most applications name a duration when they send a notification. Turn this off to give every popup the same time above.")

            M3Switch {
                checked: Prefs.toastUseAppTimeout
                enabled: Prefs.barNotifications && Prefs.toastEnabled
                onToggled: (v) => {
                    return Prefs.toastUseAppTimeout = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Keep urgent ones up")
            resetKey: "toastCriticalSticky"
            enabled: Prefs.barNotifications && Prefs.toastEnabled
            disabledReason: "Popups are switched off."
            description: Tr.t("A notification marked urgent — a low battery, a failed backup — waits for you instead of timing out.")

            M3Switch {
                checked: Prefs.toastCriticalSticky
                enabled: Prefs.barNotifications && Prefs.toastEnabled
                onToggled: (v) => {
                    return Prefs.toastCriticalSticky = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Show the message")
            resetKey: "toastShowBody"
            enabled: Prefs.barNotifications && Prefs.toastEnabled
            disabledReason: "Popups are switched off."
            description: Tr.t("With this off a popup carries the title alone, and the body waits in the list.")

            M3Switch {
                checked: Prefs.toastShowBody
                enabled: Prefs.barNotifications && Prefs.toastEnabled
                onToggled: (v) => {
                    return Prefs.toastShowBody = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Lines of message")
            resetKey: "toastBodyLines"
            enabled: Prefs.barNotifications && Prefs.toastEnabled && Prefs.toastShowBody
            disabledReason: "The message body is hidden."
            description: Tr.t("How far a long message is allowed to run before it is cut short.")
            stacked: true

            M3Slider {
                width: parent.width
                from: 1
                to: 10
                stepSize: 1
                enabled: Prefs.barNotifications && Prefs.toastEnabled && Prefs.toastShowBody
                value: Prefs.toastBodyLines
                onMoved: (v) => {
                    return Prefs.toastBodyLines = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Show buttons")
            resetKey: "toastShowActions"
            enabled: Prefs.barNotifications && Prefs.toastEnabled
            disabledReason: "Popups are switched off."
            description: Tr.t("Reply, Open, Snooze — whatever the application offers, on the popup itself. They are always in the list.")

            M3Switch {
                checked: Prefs.toastShowActions
                enabled: Prefs.barNotifications && Prefs.toastEnabled
                onToggled: (v) => {
                    return Prefs.toastShowActions = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Reply without switching")
            resetKey: "notifInlineReply"
            enabled: Prefs.barNotifications
            disabledReason: "Notifications are switched off, so nothing is shown or collected."
            description: Tr.t("Chat applications that support it get a message box on the notification itself, so you can answer without leaving what you are doing.")
            showDivider: false

            M3Switch {
                checked: Prefs.notifInlineReply
                enabled: Prefs.barNotifications
                onToggled: (v) => {
                    return Prefs.notifInlineReply = v;
                }
            }

        }

    }

    SettingCard {
        title: Tr.t("DO NOT DISTURB")

        SettingRow {
            title: Tr.t("Do not disturb")
            resetKey: "doNotDisturb"
            description: Tr.t("No popups and no sound. Everything is still collected in the list, and the bell in the bar turns to a moon.")

            M3Switch {
                checked: Prefs.doNotDisturb
                onToggled: (v) => {
                    return Prefs.doNotDisturb = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Let urgent ones through")
            resetKey: "dndAllowCritical"
            description: Tr.t("Notifications marked urgent still appear while you are silenced, however you were silenced.")

            M3Switch {
                checked: Prefs.dndAllowCritical
                onToggled: (v) => {
                    return Prefs.dndAllowCritical = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Silence over a fullscreen window")
            resetKey: "dndFullscreen"
            description: Tr.t("Films and games are left alone. The notifications wait in the list for you.")

            M3Switch {
                checked: Prefs.dndFullscreen
                onToggled: (v) => {
                    return Prefs.dndFullscreen = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Quiet hours")
            resetKey: "quietHours"
            description: page.quietDescription

            M3Switch {
                checked: Prefs.quietHours
                onToggled: (v) => {
                    return Prefs.quietHours = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Between")
            enabled: Prefs.quietHours
            disabledReason: "Quiet hours are switched off."
            description: Tr.t("Written as 22:00. An end earlier than the start runs through midnight.")
            showDivider: false

            Row {
                spacing: Theme.dp(10)

                M3TextField {
                    id: fromField

                    width: Theme.dp(96)
                    enabled: Prefs.quietHours
                    placeholder: "22:00"
                    text: Prefs.minutesText(Prefs.quietFrom)
                    onAccepted: (v) => {
                        var m = Prefs.parseMinutes(v);
                        if (m >= 0)
                            Prefs.quietFrom = m;

                        fromField.text = Prefs.minutesText(Prefs.quietFrom);
                    }
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Tr.t("to")
                    color: Theme.subtext
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontBody
                    font.variableAxes: Theme.axes(Theme.fontBody, 420, 0)
                    opacity: Prefs.quietHours ? 1 : 0.38
                }

                M3TextField {
                    id: toField

                    width: Theme.dp(96)
                    enabled: Prefs.quietHours
                    placeholder: "07:00"
                    text: Prefs.minutesText(Prefs.quietTo)
                    onAccepted: (v) => {
                        var m = Prefs.parseMinutes(v);
                        if (m >= 0)
                            Prefs.quietTo = m;

                        toField.text = Prefs.minutesText(Prefs.quietTo);
                    }
                }

            }

        }

    }

    SettingCard {
        title: Tr.t("SOUND")

        SettingRow {
            title: Tr.t("Play a sound")
            resetKey: "notifSound"
            description: Tr.t("A short chime as a notification arrives. Nothing plays while you are silenced.")

            M3Switch {
                checked: Prefs.notifSound
                onToggled: (v) => {
                    return Prefs.notifSound = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Which sound")
            resetKey: "notifSoundName"
            enabled: Prefs.notifSound
            disabledReason: "Sound is switched off."
            description: Tr.t("The terminal bell or one of Lucid's own chimes. Picking one plays it.")
            stacked: true

            Row {
                width: parent.width
                spacing: Theme.dp(12)

                M3Chips {
                    width: parent.width - playSound.width - Theme.dp(12)
                    enabled: Prefs.notifSound
                    current: Sounds.notifKey(Prefs.notifSoundName)
                    options: Sounds.notifSounds
                    onChosen: (key) => {
                        Prefs.notifSoundName = key;
                        Sounds.play(key, Prefs.notifSoundVolume);
                    }
                }

                M3Button {
                    id: playSound

                    text: Tr.t("Play")
                    variant: "tonal"
                    enabled: Prefs.notifSound
                    onClicked: Sounds.play(Sounds.notifKey(Prefs.notifSoundName), Prefs.notifSoundVolume)
                }

            }

        }

        SettingRow {
            title: Tr.t("Volume")
            resetKey: "notifSoundVolume"
            enabled: Prefs.notifSound
            disabledReason: "Sound is switched off."
            description: Tr.t("Relative to whatever the notification sink is set to.")
            stacked: true

            M3Slider {
                width: parent.width
                from: 10
                to: 100
                stepSize: 5
                suffix: " %"
                enabled: Prefs.notifSound
                value: Math.round(Prefs.notifSoundVolume * 100)
                onMoved: (v) => {
                    return Prefs.notifSoundVolume = v / 100;
                }
            }

        }

        SettingRow {
            title: Tr.t("Only for urgent ones")
            resetKey: "notifSoundUrgentOnly"
            enabled: Prefs.notifSound
            disabledReason: "Sound is switched off."
            description: Tr.t("Stay quiet for the ordinary traffic and speak up only for what is marked urgent.")
            showDivider: false

            M3Switch {
                checked: Prefs.notifSoundUrgentOnly
                enabled: Prefs.notifSound
                onToggled: (v) => {
                    return Prefs.notifSoundUrgentOnly = v;
                }
            }

        }

    }

    SettingCard {
        title: Tr.t("THE LIST")

        SettingRow {
            title: Tr.t("Show application icons")
            resetKey: "notifShowIcons"
            description: Tr.t("The sending application's icon beside each notification, in the list and on the popup.")

            M3Switch {
                checked: Prefs.notifShowIcons
                onToggled: (v) => {
                    return Prefs.notifShowIcons = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Group by application")
            resetKey: "notifGrouping"
            description: Tr.t("One application's notifications collapse into a single stack you can open, instead of filling the list one by one.")

            M3Switch {
                checked: Prefs.notifGrouping
                onToggled: (v) => {
                    return Prefs.notifGrouping = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Show times")
            resetKey: "notifTimestamps"
            description: Tr.t("How long ago each one arrived, beside the application's name, and a heading splitting new ones from the rest.")

            M3Switch {
                checked: Prefs.notifTimestamps
                onToggled: (v) => {
                    return Prefs.notifTimestamps = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Show progress")
            resetKey: "notifProgress"
            description: Tr.t("File copies, downloads and transfers report how far along they are. This draws it as a bar that fills in place.")

            M3Switch {
                checked: Prefs.notifProgress
                onToggled: (v) => {
                    return Prefs.notifProgress = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Keep at most")
            resetKey: "notifMaxHistory"
            description: Tr.t("Once the list is this long the oldest notification drops off the end as a new one arrives.")
            stacked: true

            M3Slider {
                width: parent.width
                from: 10
                to: 200
                stepSize: 10
                value: Prefs.notifMaxHistory
                onMoved: (v) => {
                    return Prefs.notifMaxHistory = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Clear the list")
            description: Tr.t("Dismisses everything the shell is holding right now. The applications are not told anything else.")
            showDivider: false

            M3Button {
                text: page.clearLabel
                variant: "tonal"
                enabled: Prefs.liveNotifCount > 0
                onClicked: Prefs.notificationsClearRequested()
            }

        }

    }

    SettingCard {
        title: Tr.t("APPLICATIONS")

        SettingRow {
            title: Tr.t("Muted applications")
            description: page.appList.length === 0 ? Tr.t("Nothing has sent a notification yet. Once something does it is listed here to mute.") : Tr.t("A muted application's notifications are turned away as they arrive — no popup, no sound, nothing in the list.")
            stacked: true
            showDivider: page.appList.length > 0

            Column {
                width: parent.width
                spacing: Theme.dp(14)
                visible: page.appList.length > 0

                Repeater {
                    model: page.appList

                    CheckLine {
                        required property var modelData

                        label: modelData
                        checked: Prefs.isMuted(modelData)
                        onToggled: Prefs.setMuted(modelData, !checked)
                    }

                }

            }

        }

        SettingRow {
            title: Tr.t("Mute one by name")
            description: Tr.t("Use the name the application gives itself, spelled the same way. Press Enter to add it.")
            showDivider: Prefs.notifSeenApps !== ""

            M3TextField {
                id: muteField

                width: Theme.dp(260)
                placeholder: Tr.t("Spotify")
                onAccepted: (v) => {
                    var name = v.trim();
                    if (name !== "") {
                        Prefs.noteApp(name);
                        Prefs.setMuted(name, true);
                    }
                    muteField.clear();
                }
            }

        }

        SettingRow {
            title: Tr.t("Forget the list")
            visible: Prefs.notifSeenApps !== ""
            description: Tr.t("Empties the roll of applications seen above. Whatever you muted stays muted, and anything that sends a notification is listed again.")
            showDivider: false

            M3Button {
                text: Tr.t("Forget")
                variant: "text"
                onClicked: Prefs.notifSeenApps = ""
            }

        }

    }

    SettingCard {
        title: Tr.t("SYSTEM EVENTS")

        SettingRow {
            title: Tr.t("Keyboard layout")
            resetKey: "toastOnLayout"
            description: Tr.t("A small toast at the top of the screen with the layout you switched to.")

            M3Switch {
                checked: Prefs.toastOnLayout
                onToggled: (v) => {
                    return Prefs.toastOnLayout = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Game mode")
            resetKey: "toastOnGameMode"
            enabled: Prefs.gameModeStateFile !== ""
            disabledReason: "Game mode is noticed by watching the file its status command checks. Set the status command under Bar → System module to something like test -f /run/gamemode.state."
            description: Tr.t("When game mode turns on or off - from the tile, a keybind or anywhere else.")

            M3Switch {
                checked: Prefs.toastOnGameMode
                enabled: Prefs.gameModeStateFile !== ""
                onToggled: (v) => {
                    return Prefs.toastOnGameMode = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Battery and charger")
            resetKey: "toastOnBattery"
            description: Tr.t("Plugging in or out, a full charge, and warnings at 20, 10 and 5 %.")

            M3Switch {
                checked: Prefs.toastOnBattery
                onToggled: (v) => {
                    return Prefs.toastOnBattery = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Bluetooth devices")
            resetKey: "toastOnBluetooth"
            description: Tr.t("A device connecting, with its battery when it reports one, or disconnecting. Switching Bluetooth off stays quiet.")

            M3Switch {
                checked: Prefs.toastOnBluetooth
                onToggled: (v) => {
                    return Prefs.toastOnBluetooth = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("USB devices")
            resetKey: "toastOnUsb"
            description: Tr.t("Something plugged into a USB port, or pulled out. The machine's own built-in parts, like the camera, stay quiet.")

            M3Switch {
                checked: Prefs.toastOnUsb
                onToggled: (v) => {
                    return Prefs.toastOnUsb = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Camera")
            resetKey: "toastOnCamera"
            description: Tr.t("Camera on, with the app using it, and camera off again once it lets go.")

            M3Switch {
                checked: Prefs.toastOnCamera
                onToggled: (v) => {
                    return Prefs.toastOnCamera = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Wi-Fi")
            resetKey: "toastOnWifi"
            description: Tr.t("Joining or losing a network. A quick drop and rejoin, like waking from sleep, stays quiet.")

            M3Switch {
                checked: Prefs.toastOnWifi
                onToggled: (v) => {
                    return Prefs.toastOnWifi = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Sound output")
            resetKey: "toastOnAudio"
            description: Tr.t("The default output changing - speakers to headphones and back.")

            M3Switch {
                checked: Prefs.toastOnAudio
                onToggled: (v) => {
                    return Prefs.toastOnAudio = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Displays")
            resetKey: "toastOnDisplays"
            description: Tr.t("A monitor being plugged in or unplugged.")

            M3Switch {
                checked: Prefs.toastOnDisplays
                onToggled: (v) => {
                    return Prefs.toastOnDisplays = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Power profile")
            resetKey: "toastOnPower"
            description: Tr.t("Balanced, performance or power saver. A switch made by game mode is left to its own toast.")

            M3Switch {
                checked: Prefs.toastOnPower
                onToggled: (v) => {
                    return Prefs.toastOnPower = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Preview")
            description: Tr.t("Plays one of each, one after another, with made-up details.")
            showDivider: false

            M3Button {
                text: Tr.t("Preview")
                variant: "text"
                onClicked: Quickshell.execDetached(["qs", "ipc", "call", "toastevents", "preview"])
            }

        }

    }

}

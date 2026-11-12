import QtQuick
import qs

Column {
    id: page

    property bool showConf: false

    readonly property string installHint: "hypridle is not installed. Install the hypridle package and this page comes to life."

    // a step set earlier than the one before it still fires, just out of turn
    function orderWarning(key) {
        var st = Idle.stages;
        for (var i = 1; i < st.length; i++) {
            if (st[i].key === key && st[i].after <= st[i - 1].after)
                return "This runs before “" + st[i - 1].name + "” above it, so the steps happen out of order.";

        }
        return "";
    }

    spacing: Theme.dp(26)
    onVisibleChanged: Idle.watching = page.visible
    Component.onCompleted: Idle.watching = page.visible

    IdleSequence {
        width: parent.width
    }

    SettingCard {
        title: Tr.t("IDLE DAEMON")

        SettingRow {
            title: Tr.t("Status")
            enabled: Idle.installed
            disabledReason: page.installHint
            description: Idle.summary + (Idle.installed ? Tr.t(". Lucid writes hypridle's config for you and restarts it whenever something here changes.") : "")
            warning: Idle.lastError

            M3Button {
                variant: "tonal"
                text: Tr.t("Restart")
                enabled: Idle.installed && Prefs.idleEnabled
                onClicked: Idle.restart()
            }

        }

        SettingRow {
            title: Tr.t("Start at login")
            resetKey: "idleAutostart"
            enabled: Idle.installed
            disabledReason: page.installHint
            description: Idle.startsAtLogin ? Tr.t("hypridle comes up with your session, whether or not Lucid is running.") : Tr.t("hypridle only runs while Lucid starts it.")

            M3Switch {
                checked: Prefs.idleAutostart
                enabled: Idle.installed
                onToggled: (v) => {
                    return Prefs.idleAutostart = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Keep this machine awake")
            resetKey: "idleKeepAwake"
            enabled: Idle.installed
            disabledReason: page.installHint
            description: Tr.t("Holds every step below until you turn this off — through a reboot too. For a presentation, a long download, or a film.")
            showDivider: false

            M3Switch {
                checked: Prefs.idleKeepAwake
                enabled: Idle.installed
                onToggled: (v) => {
                    return Prefs.idleKeepAwake = v;
                }
            }

        }

    }

    SettingCard {
        title: Tr.t("WHEN YOU WALK AWAY")

        SettingRow {
            title: Tr.t("Dim the screen")
            resetKey: "idleDim"
            visible: Idle.hasBacklight
            description: Tr.t("Turns the backlight down first, as a warning that the rest is coming. Moving the mouse puts it straight back.")

            M3Switch {
                checked: Prefs.idleDim
                onToggled: (v) => {
                    return Prefs.idleDim = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Dim after")
            resetKey: "idleDimAfter"
            visible: Idle.hasBacklight
            enabled: Prefs.idleDim
            disabledReason: "Dimming is off."
            stacked: true

            M3Slider {
                width: parent.width
                enabled: Prefs.idleDim
                from: 0
                to: Idle.steps.length - 1
                stepSize: 1
                stepLabels: Idle.stepLabels
                value: Idle.stepIndex(Prefs.idleDimAfter)
                onMoved: (v) => {
                    return Prefs.idleDimAfter = Idle.stepAt(v);
                }
            }

        }

        SettingRow {
            title: Tr.t("Dim to")
            resetKey: "idleDimLevel"
            visible: Idle.hasBacklight
            enabled: Prefs.idleDim
            disabledReason: "Dimming is off."
            description: Tr.t("How far down the backlight goes. Never all the way to nothing — a black OLED panel looks broken.")
            stacked: true

            M3Slider {
                width: parent.width
                enabled: Prefs.idleDim
                from: 1
                to: 50
                stepSize: 1
                suffix: " %"
                value: Prefs.idleDimLevel
                onMoved: (v) => {
                    return Prefs.idleDimLevel = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Turn the keyboard backlight off too")
            resetKey: "idleDimKeyboard"
            visible: Idle.hasBacklight && Idle.hasKbdBacklight
            enabled: Prefs.idleDim
            disabledReason: "Dimming is off."
            description: Tr.t("Uses ") + Idle.kbdBacklight + Tr.t(", and restores it on the way back.")

            M3Switch {
                checked: Prefs.idleDimKeyboard
                enabled: Prefs.idleDim
                onToggled: (v) => {
                    return Prefs.idleDimKeyboard = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Lock the screen")
            resetKey: "idleLock"
            description: Tr.t("Runs Lucid's own lock screen. Your password gets you back in.")

            M3Switch {
                checked: Prefs.idleLock
                onToggled: (v) => {
                    return Prefs.idleLock = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Lock after")
            resetKey: "idleLockAfter"
            enabled: Prefs.idleLock
            disabledReason: "Locking is off."
            warning: page.orderWarning("lock")
            stacked: true

            M3Slider {
                width: parent.width
                enabled: Prefs.idleLock
                from: 0
                to: Idle.steps.length - 1
                stepSize: 1
                stepLabels: Idle.stepLabels
                value: Idle.stepIndex(Prefs.idleLockAfter)
                onMoved: (v) => {
                    return Prefs.idleLockAfter = Idle.stepAt(v);
                }
            }

        }

        SettingRow {
            title: Tr.t("Turn the screen off")
            resetKey: "idleScreenOff"
            description: Tr.t("Puts the monitors to sleep. The machine keeps running, so anything downloading carries on.")

            M3Switch {
                checked: Prefs.idleScreenOff
                onToggled: (v) => {
                    return Prefs.idleScreenOff = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Screen off after")
            resetKey: "idleScreenOffAfter"
            enabled: Prefs.idleScreenOff
            disabledReason: "Turning the screen off is off."
            warning: page.orderWarning("screen")
            stacked: true

            M3Slider {
                width: parent.width
                enabled: Prefs.idleScreenOff
                from: 0
                to: Idle.steps.length - 1
                stepSize: 1
                stepLabels: Idle.stepLabels
                value: Idle.stepIndex(Prefs.idleScreenOffAfter)
                onMoved: (v) => {
                    return Prefs.idleScreenOffAfter = Idle.stepAt(v);
                }
            }

        }

        SettingRow {
            title: Tr.t("Suspend")
            resetKey: "idleSuspend"
            description: Tr.t("Sleeps the whole machine. Everything stops until you press a key.")

            M3Switch {
                checked: Prefs.idleSuspend
                onToggled: (v) => {
                    return Prefs.idleSuspend = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Suspend after")
            resetKey: "idleSuspendAfter"
            enabled: Prefs.idleSuspend
            disabledReason: "Suspending is off."
            warning: page.orderWarning("suspend")
            stacked: true
            showDivider: Idle.hasBattery && Idle.acOnline !== ""

            M3Slider {
                width: parent.width
                enabled: Prefs.idleSuspend
                from: 0
                to: Idle.steps.length - 1
                stepSize: 1
                stepLabels: Idle.stepLabels
                value: Idle.stepIndex(Prefs.idleSuspendAfter)
                onMoved: (v) => {
                    return Prefs.idleSuspendAfter = Idle.stepAt(v);
                }
            }

        }

        SettingRow {
            title: Tr.t("Suspend on mains power too")
            resetKey: "idleSuspendOnAc"
            visible: Idle.hasBattery && Idle.acOnline !== ""
            enabled: Prefs.idleSuspend
            disabledReason: "Suspending is off."
            description: Tr.t("Off means the machine only sleeps on battery. Lucid reads ") + Idle.acOnline + Tr.t(" to tell.")
            showDivider: false

            M3Switch {
                checked: Prefs.idleSuspendOnAc
                enabled: Prefs.idleSuspend
                onToggled: (v) => {
                    return Prefs.idleSuspendOnAc = v;
                }
            }

        }

    }

    SettingCard {
        title: Tr.t("SLEEP AND WAKE")

        SettingRow {
            title: Tr.t("Lock before sleeping")
            resetKey: "idleLockBeforeSleep"
            description: Tr.t("Whenever the machine suspends — from here, the power menu, or a closed lid — the lock screen goes up first, so it is already there when you open it again.")

            M3Switch {
                checked: Prefs.idleLockBeforeSleep
                onToggled: (v) => {
                    return Prefs.idleLockBeforeSleep = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Wake the screen on resume")
            resetKey: "idleWakeAfterSleep"
            description: Tr.t("Turns the monitors back on the moment the machine wakes, instead of waiting for a key press.")
            showDivider: false

            M3Switch {
                checked: Prefs.idleWakeAfterSleep
                onToggled: (v) => {
                    return Prefs.idleWakeAfterSleep = v;
                }
            }

        }

    }

    SettingCard {
        title: Tr.t("EXCEPTIONS")

        SettingRow {
            title: Tr.t("Let applications keep the screen on")
            resetKey: "idleRespectInhibitors"
            description: Tr.t("A video player or a browser playing full screen can ask the system to stay awake. Off means Lucid ignores every one of those requests.")

            M3Switch {
                checked: Prefs.idleRespectInhibitors
                onToggled: (v) => {
                    return Prefs.idleRespectInhibitors = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Never interrupt something playing")
            resetKey: "idleWhileMedia"
            description: Tr.t("Checks with playerctl before each step, and skips it if a player is playing. The check happens once, when that timer runs out — stopping the music later does not start the countdown again.")
            showDivider: true

            M3Switch {
                checked: Prefs.idleWhileMedia
                onToggled: (v) => {
                    return Prefs.idleWhileMedia = v;
                }
            }

        }

        SettingRow {
            title: Tr.t("Count gamepad input as activity")
            resetKey: "idleGamepad"
            description: Tr.t("A controller counts as activity, so these steps wait while you play. Without it, gamepad input never reaches the compositor's idle timer and the screen can turn off mid-game.")
            showDivider: false

            M3Switch {
                checked: Prefs.idleGamepad
                onToggled: (v) => {
                    return Prefs.idleGamepad = v;
                }
            }

        }

    }

    SettingCard {
        title: Tr.t("THE CONFIG FILE")

        SettingRow {
            title: Tr.t("Written to")
            monoTitle: true
            description: Tr.t("Lucid owns this file while idle management is on. Anything that was in it first was copied to hypridle.conf.pre-lucid.")

            M3Button {
                variant: "text"
                text: page.showConf ? Tr.t("Hide") : Tr.t("Show")
                onClicked: page.showConf = !page.showConf
            }

        }

        SettingRow {
            title: Idle.confPath
            monoTitle: true
            visible: page.showConf
            stacked: true

            Rectangle {
                width: parent.width
                implicitHeight: confText.implicitHeight + Theme.dp(28)
                radius: Theme.radiusSm
                color: Theme.bgSunken

                Text {
                    id: confText

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.dp(14)
                    text: Idle.conf
                    color: Theme.subtext
                    font.family: "monospace"
                    font.pixelSize: Theme.fontLabel
                    font.features: ({
                        "liga": 0,
                        "calt": 0
                    })
                    wrapMode: Text.WrapAnywhere
                }

            }

        }

        SettingRow {
            title: Tr.t("Reset the idle steps")
            description: Tr.t("Puts every timing and switch on this page back to the value it ships with. The daemon switch and keep-awake are left alone.")
            showDivider: false

            M3Button {
                variant: "text"
                destructive: true
                text: Tr.t("Reset")
                onClicked: Prefs.askReset(Tr.t("Reset the idle steps?"), Tr.t("Every timing and switch on this page goes back to the value it ships with."), Prefs.resetIdleToken)
            }

        }

    }

}

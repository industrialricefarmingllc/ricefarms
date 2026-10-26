#!/usr/bin/env python3
"""Answers bluez's pairing and authorization questions for LucidShell.

Without an agent, bluez refuses every audio or input profile a device that is
not marked trusted tries to open, so paired headphones connect and stay
silent, and pairings that need a code shown or confirmed cannot happen at all.
This registers as the default agent:

- a paired device opening a profile is let in without asking
- a code to confirm, or an unknown device asking to pair, becomes a
  notification with Pair and Decline
- a code to type on the other device is shown in a notification

Speaks JSON lines on stdout: {"type": "state", "state": "ready" | "missing" |
"error", "detail": "..."}.
"""

import json
import signal
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

BLUEZ = "org.bluez"
AGENT_PATH = "/org/lucid/bluez/agent"
# no text entry in a notification, so never be asked to type a passkey
CAPABILITY = "DisplayYesNo"
# old devices that only know fixed-PIN pairing nearly all use this one
LEGACY_PIN = "0000"
NOTIFY = "org.freedesktop.Notifications"
NOTIFY_PATH = "/org/freedesktop/Notifications"
PROPS = "org.freedesktop.DBus.Properties"

AGENT_XML = """
<node>
  <interface name="org.bluez.Agent1">
    <method name="Release"/>
    <method name="RequestPinCode">
      <arg type="o" name="device" direction="in"/>
      <arg type="s" name="pincode" direction="out"/>
    </method>
    <method name="DisplayPinCode">
      <arg type="o" name="device" direction="in"/>
      <arg type="s" name="pincode" direction="in"/>
    </method>
    <method name="RequestPasskey">
      <arg type="o" name="device" direction="in"/>
      <arg type="u" name="passkey" direction="out"/>
    </method>
    <method name="DisplayPasskey">
      <arg type="o" name="device" direction="in"/>
      <arg type="u" name="passkey" direction="in"/>
      <arg type="q" name="entered" direction="in"/>
    </method>
    <method name="RequestConfirmation">
      <arg type="o" name="device" direction="in"/>
      <arg type="u" name="passkey" direction="in"/>
    </method>
    <method name="RequestAuthorization">
      <arg type="o" name="device" direction="in"/>
    </method>
    <method name="AuthorizeService">
      <arg type="o" name="device" direction="in"/>
      <arg type="s" name="uuid" direction="in"/>
    </method>
    <method name="Cancel"/>
  </interface>
</node>
"""


def emit(obj):
    try:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()
    except (BrokenPipeError, ValueError):
        raise SystemExit(0)


def log(msg):
    try:
        sys.stderr.write("bt-agent: %s\n" % msg)
        sys.stderr.flush()
    except (BrokenPipeError, ValueError):
        pass


def esc(text):
    return GLib.markup_escape_text(text or "")


class Agent:
    def __init__(self):
        self.sysbus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.bluez_owner = ""
        self.registered = False
        # the question being asked: (invocation, notification id) or None.
        # bluez never has more than one request out at a time
        self.pending = None
        # the notification showing a code to type, closed once pairing ends
        self.shown = 0

        info = Gio.DBusNodeInfo.new_for_xml(AGENT_XML)
        register = getattr(self.sysbus, "register_object_with_closures2", None) or self.sysbus.register_object
        self.agent_id = register(AGENT_PATH, info.interfaces[0], self.on_call, None, None)

        self.bus.signal_subscribe(NOTIFY, NOTIFY, "ActionInvoked", NOTIFY_PATH,
                                  None, Gio.DBusSignalFlags.NONE,
                                  self.on_action, None)
        self.bus.signal_subscribe(NOTIFY, NOTIFY, "NotificationClosed",
                                  NOTIFY_PATH, None, Gio.DBusSignalFlags.NONE,
                                  self.on_closed, None)
        Gio.bus_watch_name_on_connection(
            self.sysbus, BLUEZ, Gio.BusNameWatcherFlags.NONE,
            self.on_bluez_appeared, self.on_bluez_vanished)

    # ---------------------------------------------------------- lifecycle

    def on_bluez_appeared(self, _bus, _name, owner):
        self.bluez_owner = owner
        self.registered = False
        try:
            self.sysbus.call_sync(BLUEZ, "/org/bluez", "org.bluez.AgentManager1",
                                  "RegisterAgent",
                                  GLib.Variant("(os)", (AGENT_PATH, CAPABILITY)),
                                  None, Gio.DBusCallFlags.NONE, 5000, None)
            self.sysbus.call_sync(BLUEZ, "/org/bluez", "org.bluez.AgentManager1",
                                  "RequestDefaultAgent",
                                  GLib.Variant("(o)", (AGENT_PATH,)),
                                  None, Gio.DBusCallFlags.NONE, 5000, None)
        except GLib.Error as e:
            Gio.DBusError.strip_remote_error(e)
            emit({"type": "state", "state": "error", "detail": e.message})
            return
        self.registered = True
        emit({"type": "state", "state": "ready", "detail": ""})

    def on_bluez_vanished(self, _bus, _name):
        # bluetoothd restarting forgets every agent; register again when it is back
        self.bluez_owner = ""
        self.registered = False
        self.drop_pending()
        emit({"type": "state", "state": "missing", "detail": ""})

    def shutdown(self, *_args):
        self.drop_pending()
        self.close_notif(self.shown)
        if self.registered:
            try:
                self.sysbus.call_sync(BLUEZ, "/org/bluez", "org.bluez.AgentManager1",
                                      "UnregisterAgent",
                                      GLib.Variant("(o)", (AGENT_PATH,)), None,
                                      Gio.DBusCallFlags.NONE, 2000, None)
            except GLib.Error:
                pass
        loop.quit()
        return False

    # ------------------------------------------------------------ helpers

    def device(self, path):
        try:
            r = self.sysbus.call_sync(BLUEZ, path, PROPS, "GetAll",
                                      GLib.Variant("(s)", ("org.bluez.Device1",)),
                                      GLib.VariantType("(a{sv})"),
                                      Gio.DBusCallFlags.NONE, 3000, None)
            props = r.unpack()[0]
        except GLib.Error:
            props = {}
        return {
            "name": props.get("Alias") or props.get("Name") or props.get("Address") or "A device",
            "paired": bool(props.get("Paired")) or bool(props.get("Bonded")),
        }

    def notify(self, summary, body, actions, replace=0, resident=True):
        hints = {"urgency": GLib.Variant("y", 2 if actions else 1)}
        if resident:
            hints["resident"] = GLib.Variant("b", True)
        try:
            r = self.bus.call_sync(
                NOTIFY, NOTIFY_PATH, NOTIFY, "Notify",
                GLib.Variant("(susssasa{sv}i)",
                             ("Bluetooth", replace, "bluetooth", summary, body,
                              actions, hints, 0 if resident else -1)),
                GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 3000, None)
            return r.unpack()[0]
        except GLib.Error as e:
            log("notify failed: %s" % e.message)
            return 0

    def close_notif(self, nid):
        if not nid:
            return
        try:
            self.bus.call_sync(NOTIFY, NOTIFY_PATH, NOTIFY, "CloseNotification",
                               GLib.Variant("(u)", (nid,)), None,
                               Gio.DBusCallFlags.NONE, 2000, None)
        except GLib.Error:
            pass

    @staticmethod
    def reject(invocation, what="Rejected"):
        try:
            invocation.return_dbus_error("org.bluez.Error." + what,
                                         "Declined" if what == "Rejected" else "Canceled")
        except Exception:  # noqa: BLE001 - bluez may have given up already
            pass

    def ask(self, invocation, summary, body):
        # a new question replaces one bluez has stopped waiting for
        self.drop_pending()
        nid = self.notify(summary, body, ["accept", "Pair", "decline", "Decline"])
        if not nid:
            # nobody can be asked: saying no is the safe answer
            self.reject(invocation)
            return
        self.pending = (invocation, nid)

    def answer(self, yes):
        if not self.pending:
            return
        invocation, nid = self.pending
        self.pending = None
        self.close_notif(nid)
        if yes:
            invocation.return_value(None)
        else:
            self.reject(invocation)

    def drop_pending(self):
        if self.pending:
            invocation, nid = self.pending
            self.pending = None
            self.reject(invocation, "Canceled")
            self.close_notif(nid)

    # -------------------------------------------------------------- agent

    def on_call(self, _conn, sender, _path, _iface, method, params, invocation):
        if sender != self.bluez_owner:
            self.reject(invocation)
            return
        args = params.unpack()
        if method == "AuthorizeService":
            # bluez only asks about devices that are not trusted. A bonded one
            # was let in once already; anything else has no business here
            dev = self.device(args[0])
            if dev["paired"]:
                invocation.return_value(None)
            else:
                log("refused %s for unpaired %s" % (args[1], args[0]))
                self.reject(invocation)
        elif method == "RequestConfirmation":
            dev = self.device(args[0])
            self.ask(invocation, "Pair with %s?" % dev["name"],
                     "Check that %s shows <b>%06d</b>." % (esc(dev["name"]), args[1]))
        elif method == "RequestAuthorization":
            dev = self.device(args[0])
            self.ask(invocation, "Pair with %s?" % dev["name"],
                     "%s wants to pair with this computer." % esc(dev["name"]))
        elif method == "DisplayPasskey":
            dev = self.device(args[0])
            self.shown = self.notify("Pair with %s" % dev["name"],
                                     "Type <b>%06d</b> on %s, then press Enter." % (args[1], esc(dev["name"])),
                                     [], replace=self.shown)
            invocation.return_value(None)
        elif method == "DisplayPinCode":
            dev = self.device(args[0])
            self.shown = self.notify("Pair with %s" % dev["name"],
                                     "Type <b>%s</b> on %s, then press Enter." % (esc(args[1]), esc(dev["name"])),
                                     [], replace=self.shown)
            invocation.return_value(None)
        elif method == "RequestPinCode":
            invocation.return_value(GLib.Variant("(s)", (LEGACY_PIN,)))
        elif method == "RequestPasskey":
            # cannot happen with DisplayYesNo; there is no way to type one anyway
            self.reject(invocation)
        elif method == "Cancel":
            invocation.return_value(None)
            self.drop_pending()
            self.close_notif(self.shown)
            self.shown = 0
        elif method == "Release":
            invocation.return_value(None)
            self.registered = False
            emit({"type": "state", "state": "error", "detail": "bluez released the agent"})
        else:
            invocation.return_value(None)

    # ------------------------------------------------------- notification

    def on_action(self, _conn, _sender, _path, _iface, _signal, params, _d):
        nid, key = params.unpack()
        if self.pending and self.pending[1] == nid:
            self.answer(key in ("accept", "default"))

    def on_closed(self, _conn, _sender, _path, _iface, _signal, params, _d):
        nid, _reason = params.unpack()
        if self.pending and self.pending[1] == nid:
            # dismissing the question is a no
            self.answer(False)
        elif nid == self.shown:
            self.shown = 0


def die_with_parent():
    # the shell restarting must not leave an agent behind
    try:
        import ctypes
        ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGTERM)
    except (OSError, AttributeError):
        pass


if __name__ == "__main__":
    die_with_parent()
    loop = GLib.MainLoop()
    agent = Agent()
    try:
        gi.require_version("GLibUnix", "2.0")
        from gi.repository import GLibUnix
        signal_add = GLibUnix.signal_add
    except (ImportError, ValueError):
        signal_add = GLib.unix_signal_add
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal_add(GLib.PRIORITY_DEFAULT, sig, agent.shutdown)
    loop.run()

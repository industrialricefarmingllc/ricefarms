# lucid-gate

A task tollbooth for [lucid shell](https://github.com/Sn3akyy1/lucid) (Quickshell +
Hyprland).  A place asks to be opened; instead of a password you pay with a
small task (a Duolingo lesson), or with
Compute you earned by doing tasks when nothing was asking.

Two surfaces share one state:

- **the desktop card** — a normal lucid widget, on the desktop and not over
  windows.  It shows Compute top-left, a swipeable task strip, and the reward.  Doing a task here
  unprompted pays Compute.
- **the foreground gate** — a `WlrLayer.Overlay` surface on the monitor the
  action came from.  It dims the screen and puts the face exactly over the
  window that asked — no margins, no recentring.  Compute sits top-left, and
  the middle is a swipeable marquee of ways through: spend the balance first,
  then every task that pays for it.  While a browser task runs it collapses
  into a small always-on-top pill in the corner so the task can actually be
  done.

The face (`qml/GateSurface.qml`) is shared by both hosts.
The next "place" only needs a catalogue variant and a few pixels of layout, not
a second implementation.

```
source ──► gate run / gate request ──► daemon (ledger + socket)
                                          │ writes state.json
                                          ▼
                                   GateCore (QML singleton) ──► card / overlay
                                          ▲
                                          └── gate start / complete / unlock
```

## Install

```sh
./install.sh            # symlinks + marked patches, idempotent
systemctl --user restart quickshell
qs ipc call -- widgets add gate wallet
```

`install.sh` links `qml/` to `~/.config/quickshell/lucidgate`, `GateCore.qml`
to the config root, the widget body into `lucidwidgets/`, and the CLI into
`~/.local/bin/gate`.  It adds one catalogue entry to `Widgets.qml` and one
`GateOverlay { }` to `shell.qml`, both inside marked blocks.  Original files are
copied to `*.bak.lucid-gate-<epoch>` first.

`./install.sh --uninstall` removes the links and the marked blocks.  The ledger
in `~/.local/state/lucid-gate/` is kept.

## Currency

Compute (`memory` glyph) is earned by finishing a task with no gate pending.
A gate costs Compute from `place_costs` (default 160).  While a gate is
pending, finishing *any* task opens it for free, and pays nothing.  Compute you
saved earlier lets you skip the task entirely.

The economy is deliberately small:

| task | minimum | reward |
|---|---|---|
| Duolingo lesson | completion | +160 |

One lesson pays for a place.
After 10 tasks in a day, every place opens for free: the gate still appears,
but its unlock card crosses out the usual price, shows 0 and says so, and
tasks finished while the day is free pay their reward instead of the gate.
The day rolls at 02:00; a reboot starts a fresh count, and a machine left on
overnight carries the count over. Everything is editable in
`~/.config/lucid-gate/config.json` (`free_after`, default 10).

## Trying it

```sh
gate status
qs ipc call -- gate request discord "Send message" 120   # overlay appears
gate start duolingo                                      # pill appears
gate complete duolingo                                   # unlocks the gate free
```

or from a shell:

```sh
gate run --place discord -- discord
```

`gate run` blocks until the gate opens, then `exec`s the command exactly once.
`gate request --wait` is the same without the exec.

Gate the programs you actually care about in
`~/.config/hypr/custom.lua` with the helper in `hypr/lucid-gate.lua`:

```lua
dofile(os.getenv("HOME") .. "/src/lucid-gate/hypr/lucid-gate.lua")
hl.bind("SUPER + SHIFT + D", gated("discord", "discord"))
```

## OpenCode

Installed at `~/.config/opencode/plugins/lucid-gate.ts` (source of truth in
`examples/opencode/lucid-gate.ts`).  It
uses the `prompt` hook: the admission is refused (with a human-readable reason)
and the text is kept in memory; after the gate opens, it is submitted again.
If quickshell is not running, prompts are not gated at all: the plugin reads
the shell's `~/.local/state/lucid-gate/shell-alive` heartbeat (written every two
seconds), and a stale or missing file means there is no lock screen to show, so
the prompt passes straight through. A gate that was already waiting when the
shell went away is cancelled instead of hanging.

`LUCID_GATE_DISABLE=1` turns it off. The gate covers the terminal window and
keeps the prompt in memory; granting it resubmits the exact prompt.

The hook is a transform hook, not a typed reject, so this deliberately throws.
That is the only supported way to stop an admission today.  If a future API
adds a rejection primitive, swap the throw for it; the replay half stays.

## Duolingo, embedded

Duolingo runs inside the gate card, not in a browser window. That needs a
Quickshell built with the upstream WebView patch (PR #351), because 0.3.2 has
no `Quickshell.WebView` of its own:

- `qt6-webengine` installed.
- Quickshell 0.3.2 built with `-DUSE_JEMALLOC=OFF` (QtWebEngine crashes inside
  jemalloc). The patched build lives in `~/src/quickshell-web` and installs to
  `/usr/local`.
- `bin/qs-web` is the launcher: it reads the XDG appearance portal once and
  passes `--blink-settings=preferredColorScheme=0|1` to Blink, so the page's
  `prefers-color-scheme` matches the desktop. Install it to `~/.local/bin`.
- `systemd/quickshell-webengine.conf` is the user-service drop-in that points
  `ExecStart` at that launcher.

A full build, from a clean checkout:

```sh
git clone --depth 1 --branch v0.3.2 https://github.com/quickshell-mirror/quickshell.git
cd quickshell && git apply ~/src/lucid-gate/patches/quickshell-webengine.patch
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DUSE_JEMALLOC=OFF
ninja -C build && sudo cmake --install build --prefix /usr/local
```

`GateWeb.qml` owns one persistent profile for the whole shell:

- cookies, local storage and cache live in `~/.local/share/lucid-gate/webengine`,
- `ForcePersistentCookies` + `StoreOnDisk`, so the login survives restarts,
- the profile is a singleton, so it outlives individual lesson views and is
  flushed normally at exit,
- email/password login works; Google/Apple OAuth tends to reject embedded
  engines.

`GateLesson.qml` injects a small probe into the page after every load:

- clicks the path's `START` bubble / next lesson (`/learn`),
- clicks only `START …` intro cards inside a lesson (`player-next`), never
  CHECK/CONTINUE during exercises,
- watches `[data-test="session-complete-slide"]` and, once a lesson has
  started, the completion wording; then calls `gate complete duolingo`
  immediately. No dwell timer, no Done button. The card then lingers for
  two seconds so Duolingo's own summary is readable before it closes.

Dark/light is read at shell start. Changing the system mode needs
`systemctl --user restart quickshell`; the embedded page then comes up in the
new scheme. The debug taps are `gate-duo probe`, `gate-duo evalJs "<js>"`,
`gate-duo lastEval`, and `gate-duo reload`.

## Progress from the account

Lessons done outside the gate still count. `GateProgress.qml` keeps a
background view on the shared profile and every 60 s reads the account's
`totalXp` from `duolingo.com/2017-06-30/users/<id>`:

- the first total it ever sees is the **baseline** — nothing from before is
  credited retroactively,
- each later increase that looks like a lesson (`delta / 20`, at least one)
  pays the normal 160 through `gate credit … --ref duolingo-xp-<xp>-<n>`, so a
  repeated poll can never pay twice,
- a lesson finished inside the gate stamps `internalAt` in
  `~/.local/state/lucid-gate/duolingo-progress.json`; XP arriving within ten
  minutes of that stamp is ignored so the same lesson is not paid twice.

`gate-core duo <xp>` reports a total by hand for debugging, `gate-core duo ""`
shows the stored checkpoint, and `gate-progress state` shows the poller.

## Configuration

`~/.config/lucid-gate/config.json` (created on install):

```json
{
  "starting_balance": 0,
  "default_cost": 100,
  "place_costs": { "opencode": 100, "discord": 120, "steam": 200 },
  "tasks": null
}
```

`tasks` replaces/extends the built-ins by `id`; a minimal override:

```json
{ "tasks": [{ "id": "stretch", "name": "Stretch", "min": 120, "reward": 30 }] }
```

Task kinds are `timer`, `browser`, `duolingo` and `instant`.  Pressing a card in
the gate, or starting the task from a card or the pill, begins it: a browser
task launches its `url`, a Duolingo task mounts the embedded lesson, and an
instant task is claimed immediately.

## CLI

```
gate status [--json]            balance, pending gates, running tasks
gate tasks
gate request --place P [--label L] [--cost N] [--ref R] [--wait] [--json]
gate run --place P -- cmd...    run cmd once the gate opens
gate start TASK [--gate G]
gate complete TASK
gate abandon SESSION
gate unlock GATE                spend Compute
gate cancel GATE
gate reset --yes
```

The daemon is started on demand by the CLI and exits after an hour idle.  It
listens on `$XDG_RUNTIME_DIR/lucid-gate.sock`, mode 0600, and writes
`$XDG_STATE_HOME/lucid-gate/state.json` in place so the shell's file watch
survives every write.

## Tests

```sh
python3 -m unittest discover -s tests -v
```

The tests run the real CLI and daemon against throwaway `HOME`/`XDG_*` dirs:
earning, spending, insufficient Compute, free unlock through a task, minimum
duration, `--ref` dedupe, `gate run` replay, and cancellation.

## Notes on the QML side

- `GateCore.qml` is a top-level singleton, like `Widgets.qml`, so both the
  widget body and the overlay can see the same state without a second process.
- `GateSurface.qml` is the reusable face.  `compact` is the running-task row
  the pill mounts; the gate mounts the Compute + marquee layout.
- The overlay freezes the asking window's rectangle when the gate appears and
  the face covers it exactly.  `Hyprland.activeToplevel` can be empty on a
  fresh shell, so it falls back to `hyprctl -j clients` and the most recent
  `focusHistoryID`; the gate stays hidden until either answers, so it never
  shows at a temporary position.
- The pill is a separate small layer window, not a shrunken full-screen one:
  a full-screen surface would swallow clicks in the browser even while it is
  only showing a corner card.
- Escape cancels the waiting gate.  It is the one deliberate escape hatch; the
  `gate` daemon also fails open if the ledger cannot be read, so a broken state
  file cannot lock the desktop.

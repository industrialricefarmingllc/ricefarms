# OpenCode sessions for Lucid

Publishes the root sessions open in every OpenCode TUI window and renders them
as a Lucid desktop widget. A busy session gets an animated Material loading
indicator with the DeepSeek mark cut out of it; done sessions show the DeepSeek
mark in the card's Matugen ink.

## What is installed

| Path | Purpose |
| --- | --- |
| `~/.config/opencode/plugins/lucid-sessions/tui.ts` | TUI plugin. One instance per OpenCode window. |
| `~/.config/opencode/cli.json` | Lists the plugin under `plugins`. |
| `~/.config/quickshell/lucidwidgets/OpencodeWidget.qml` | Lucid widget body. |
| `~/.config/quickshell/lucidwidgets/DeepSeekMark.qml` | The DeepSeek whale mark, tinted with the card's ink. |
| `~/.config/quickshell/lucidwidgets/opencode-sessions.py` | Merges the window snapshots and checks process liveness. |
| `~/.config/quickshell/Widgets.qml` | Catalogue entry (`opencode` / `list` + `grid`). |
| `~/.config/quickshell/lucidwidgets/WidgetPanel.qml` | Search keywords for the widget panel. |

Lucid updates replace `Widgets.qml` and `WidgetPanel.qml`. Keep this directory's
notes (or the `.bak.lucid-sessions.*` backups) around to re-apply the catalogue
entry and the keyword line after an update. The widget body and helper live in
`lucidwidgets/`, which Lucid updates less often; keep copies too.

## How it works

Each TUI process writes one atomic snapshot:

```
$XDG_RUNTIME_DIR/opencode-lucid-sessions/window-<pid>-<start-ticks>.json
```

The snapshot contains the window's open root-session tabs (or the routed session
when tabs are disabled), its title, `busy` / `attention` / `idle` status, the
workspace directory, and the Hyprland window address of the terminal that owns
the process. Snapshot files are removed when the plugin shuts down cleanly; the
helper ignores files whose PID/start-time no longer exists, so a killed TUI
cannot leave a phantom row.

`opencode-sessions.py` merges the live snapshots, deduplicates a session that is
open in more than one window, sorts working sessions first, and prints one JSON
object for the widget:

```json
{
  "version": 1,
  "generatedAt": 1794224981768,
  "sessions": [
    {
      "id": "ses_...",
      "title": "Open sessions in an opencode window",
      "status": "busy",
      "active": true,
      "attention": false,
      "unread": null,
      "directory": "/home/nicerice",
      "windowPid": 6265,
      "windowAddress": "0x562ff1a357d0",
      "windows": [27942],
      "updatedAt": 1794224981426
    }
  ]
}
```

`status` is `busy`, `attention` (an unread error / attention flag) or `idle`
(shown as **Done** in the widget). `doneAt` is the server's idle timestamp, so
finished sessions sort newest-done first.
The widget refreshes once a second and calls `hyprctl dispatch focuswindow` when
a row is clicked.

## Use

The widget is already on the desktop as `opencode/list`. It has two looks:

- **Sessions** — 320×320 by default, resizable vertically: name, state and folder.
- **Status grid** — 160×160: only each session's state icon, in a square grid
  whose rows and columns follow the number of sessions. The OpenCode O sits
  behind at 10% opacity, black in light mode and white in dark mode. Hovering lifts an icon and marquees its name along the
  bottom; click an icon to focus its window.

Both appear in the widget panel under **OpenCode**. The list has two options:
**Hide done sessions** and **Show the folder**; the grid honours **Hide done
sessions** too.

Each session card uses the Matugen surface colours from the shell
(`Theme.surfaceHigh`, brightening to `Theme.surfaceHighest` under the pointer),
matching the Social feed's post cards. The folder line shows `~` for a session in
`$HOME` and only the last folder name for any other directory.

To add another copy from the shell:

```sh
qs ipc call widgets add opencode list
```

## Checks

```sh
# the merged view the widget receives
python3 ~/.config/quickshell/lucidwidgets/opencode-sessions.py | python3 -m json.tool

# the raw per-window snapshots
ls -l "${XDG_RUNTIME_DIR:-$HOME/.cache}/opencode-lucid-sessions"
```

If a window is missing, the TUI plugin either has not reloaded `cli.json` yet or
that window predates the plugin. Touching `cli.json` makes the TUI reload plugins.

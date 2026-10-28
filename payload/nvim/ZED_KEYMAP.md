# Zed-style Neovim

This config keeps Neovim non-modal: it starts in Insert, `Esc` returns to
Insert, and the keymap follows the Zed/VSCode bindings in
`~/.config/zed/keymap.json`. Panels behave like Zed docks, and the AI agent is
the same OpenCode server Zed uses.

The config is modular:

```
init.lua                 bootstrap + module loading
lua/config/options.lua   editor options / UI
lua/config/autocmds.lua  autosave, format, insert-on-enter, diagnostics
lua/config/keymaps.lua   the keymap
lua/config/buffers.lua   tab/buffer management
lua/config/selection.lua syntax-node expand/shrink
lua/config/terminal.lua  bottom terminal + OpenCode dock
lua/config/git.lua       git panel, unified diff, hunk helpers
lua/config/ai.lua        OpenCode integration
lua/config/remote.lua    :SSH / :Dev / remote-nvim
lua/plugins/*.lua        lazy.nvim specs
```

## First run

```sh
nvim
:Lazy sync          # install/update plugins
:Mason              # optional: see language-server installs
:checkhealth
```

Language servers and formatters are installed by Mason on first use. Some
servers (TypeScript, Svelte, Tailwind) require `npm`; the local machine has it.
The first normal launch may spend a few minutes installing them; watch progress
with `:Mason`. If you need a quick, quiet start, launch with
`NVIM_NO_MASON=1 nvim` to skip the automatic installers.

## Keymap

`Ctrl` is written as `C-`, `Alt` as `A-`, `Shift` as `S-`.

### Files and buffers

| Key | Action |
| --- | --- |
| `C-P` | File finder (in a non-editor panel) |
| `C-E` | File finder |
| `C-R` | Recent files |
| `C-N` | New file |
| `C-S-N` | New split |
| `C-S` | Save |
| `C-S-S` | Save as |
| `C-A-S` | Save all |
| `C-W` | Save all and quit Neovim (`:wqa`) |
| `C-F4` | Close the current editor (saves first) |
| `C-S-T` | Reopen closed editor |
| `C-Tab` / `C-S-Tab` | Next / previous editor |
| `C-S-E` | Project panel toggle/focus |
| `C-P` | Outline panel (in an editor) |
| `C-S-B` | Outline panel |
| `C-S-G` | Git panel (changed files) |
| `C-S-M` | Diagnostics panel |
| `C-U` | Command palette |
| `C-A-S-O` | Open remote SSH project |

`C-S-P` is intentionally unbound, matching your Zed keymap. The command
palette is `C-U`.

### Editing

| Key | Action |
| --- | --- |
| `C-Z` / `C-Y` / `C-S-Z` | Undo / redo |
| `C-A` | Select all |
| `C-C` / `C-X` / `C-V` | Copy / cut / paste (line-wise when nothing is selected) |
| `C-S-K` (`A-K`) | Delete line |
| `A-Up` / `A-Down` | Move line up/down |
| `C-A-S-Up` / `C-A-S-Down` | Duplicate line up/down |
| `C-Enter` / `C-S-Enter` | Insert line below/above |
| `Tab` / `S-Tab` | Indent / outdent selection |
| `C-/` | Toggle line comment |
| `C-S-A` | Toggle block comment |
| `A-S-F` | Format document/selection |
| `F2` | Rename symbol |
| `C-.` | Code action / quick fix |
| `C-Space` | Show completions |
| `C-S-Space` | Signature help |
| `A-S-O` | Organize imports |
| `A-Z` | Toggle soft wrap |
| `Esc` | Back to Insert, clear search, clear extra cursors |

`C-Space` is the completion key; `Tab` selects the next completion item and
`Enter` accepts it (Zed's behaviour).

Insert-mode `C-O` is deliberately left native: it is Neovim's "run one normal
command" prefix, so `C-O :` opens the command line without leaving Insert. This
is the escape hatch for any Ex command that is not on a key.

### Selection / multi-cursor

| Key | Action |
| --- | --- |
| `C-S-D` or `A-S-Right` | Expand selection to syntax node |
| `A-S-Left` | Shrink selection |
| `C-D` | Add next occurrence as a cursor |
| `C-F2` | Add a cursor at every occurrence |
| `S-A-Up` / `S-A-Down` | Add cursor above/below |
| `Esc` | Clear cursors and return to Insert |

`C-S-L` is Agent Focus in your Zed keymap, so "select all occurrences" is on
`C-F2` (also a Zed default).

### Find / navigation

| Key | Action |
| --- | --- |
| `C-F` | Find in file (Telescope buffer finder) |
| `C-H` | Replace in file (grug-far, current file) |
| `C-S-F` | Find in project |
| `C-S-H` | Replace in project |
| `C-G` | Go to line |
| `C-O` | Project symbols (`LSP workspace symbols`) in Normal mode |
| `C-A-O` | Project symbols while typing |
| `F3` / `S-F3` | Next / previous search match |
| `A-Left` / `A-Right` | Jump back / forward |
| `F8` / `S-F8` | Next / previous diagnostic |
| `A-Enter` | Diagnostic details at cursor |

### LSP

| Key | Action |
| --- | --- |
| `F12` | Go to definition (same window) |
| `A-F12` | Go to definition in a split |
| `C-F12` | Go to type definition |
| `S-F12` | Go to implementation |
| `A-S-F12` | Find references |
| `C-I` (normal) / `C-S-I` or `A-I` (typing) | Hover (type/signature/docs) |
| `A-S-H` | Incoming calls |
| `C-:` | Toggle inlay hints |

`C-I` is not mapped in Insert because Neovim treats it as the same keycode as
`Tab` (`<C-I>` == `<Tab>`), so mapping it would steal indentation and completion
navigation. While typing, use `C-S-I` or `A-I` for hover. Hover shows the LSP
type/signature/docs for the symbol under the cursor. Signature help is a
separate key: `C-S-Space`.

### Panes and terminal

| Key | Action |
| --- | --- |
| `C-\` or `C-S-Q` | Split right |
| `C-S-W` | Focus pane left |
| `C-S-R` | Focus pane right |
| `C-A-Left/Right/Up/Down` | Move pane |
| `C-A-H/J/K/L` | Focus pane |
| `A-1` … `A-9` | Focus pane by index |
| `` C-` `` | Toggle terminal |
| `C-~` | New terminal |
| `Esc` in terminal | Sent to the shell (not swallowed) |

Use `` C-` `` to hide the terminal; terminal `Esc` behaves like a real terminal.

### Git

| Key | Action |
| --- | --- |
| `C-S-G` | Git panel (changed files; `Tab` stages/unstages) |
| `C-Q` | Unified diff for the current file (Fugitive) |
| `C-J` / `A-Y` | Stage hunk and go to next hunk |
| `A-S-Y` | Unstage hunk and go to next hunk |
| `C-'` | Restore (discard) hunk |
| `A-.` / `A-,` | Next / previous hunk |
| `A-G B` | Blame line |
| `A-G R` | Side-by-side review (`DiffviewOpen`) |
| `A-G M` | Modified files picker |
| `C-S-C` | Copy relative path |

Inside the Git panel: `Tab` stage/unstage, `Enter` open the file, and the
preview pane shows the unified diff. Use `:GitCommit`, `:GitStageAll`, and
`:GitUnstageAll` for the other panel actions (or bind them to extra keys if you
want them in the picker itself).

Git commands: `:GitStatus`, `:GitDiff`, `:GitReview`, `:GitHistory`,
`:GitCommit`, `:GitAmend`, `:GitStageAll`, `:GitUnstageAll`, `:GitPush`,
`:GitPull`.

Zed's `diff_view_style` is unified. This config uses **Fugitive's unified
`git diff`** for `C-Q` and **Diffview** (side-by-side) for full history and
merge conflict review.

### AI (OpenCode)

| Key | Action |
| --- | --- |
| `C-S-O` | Toggle the OpenCode agent dock |
| `C-S-L` / `C-A-I` | Focus the agent dock |
| `C-S-.` | Ask OpenCode about the selection (`@this`) |
| `:AI` | OpenCode action picker |
| `:AIAsk <prompt>` | Prompt OpenCode |
| `:AICommit` | Generate a commit message from staged changes |
| `:AIToggle`, `:AIFocus` | Same as the keys |

The agent runs `opencode` in a right-hand toggleterm dock. OpenCode edits are
reviewed as a diff, exactly like the Zed agent: `da` accept, `dr` reject,
`dp`/`do` accept/reject one hunk, `]c`/`[c` next/previous change.

Requirements: `opencode` on `PATH`. Local is v2.0.32. In a remote session the
binary must exist on the remote host; otherwise the dock reports it is missing.

### Remote SSH

The existing `dev` shortcut is preserved and extended:

| Command | Action |
| --- | --- |
| `:Dev` | Connect to `dev` |
| `:SSH dev` | Same |
| `:SSH` | Pick a host from `~/.ssh/config` |
| `:SSHStop` | Stop the remote server |
| `:SSHInfo` | Show remote session information |
| `:SSHCleanup` | Remove the remote setup |
| `C-A-S-O` | Open remote project picker |

`:ssh` (lowercase) is rewritten to `:SSH` on the command line, as before.

The remote UI opens in a **new kitty window**. Keep the original nvim window
open: it owns the tunnel and the remote server. If you close it, the remote
server stops (remote-nvim limitation). The config is synced to the remote on
connect; the first connect may take a while while plugins and Mason servers
install. Clipboard on remote uses OSC52, so yanks go to your local clipboard
and paste works with the terminal's paste shortcut (`Ctrl+Shift+V`).

## What is not covered

- **Inline edit predictions** (Zed's `edit_predictions.provider =
  "open_ai_compatible_api"`). That provider is not exposed to Neovim without
  its endpoint/credentials. The OpenCode agent handles chat, edits, and
  refactors instead. If you want predictions, a plugin such as Supermaven or
  Copilot can be added separately.
- **Collaboration** (Zed channels, calls, shared buffers).
- **Debugger** (Zed's `F5`/`F9`/`F10`/`F11`). `nvim-dap` can be added later;
  the rest of the config is ready for it.
- Zed's **multibuffer excerpts**: diagnostics, references, and symbols open in
  Trouble/Telescope panels instead.
- Zed's **unified agent diff** is handled by opencode.nvim's `diffpatch` view,
  not a custom UI.

## Useful commands

```
:Lazy                 plugin manager
:Mason                language server/tool manager
:checkhealth          diagnostics
:Trouble diagnostics  diagnostics panel
:Neotree              project panel
:DiffviewOpen         review working-tree diff
:DiffviewFileHistory %  history for the current file
:Format               format now
:FormatDisable        disable autoformat for this buffer
:FormatEnable         re-enable it
```

## Customization

- All keymaps are in `lua/config/keymaps.lua`; global workspace bindings are
  in `M.setup()`, editor bindings in `apply_editor()`.
- The Zed-specific editor overrides are the first block of `apply_editor()`;
  change those if you want `C-P` to stay a file finder inside editors.
- The agent dock and terminal live in `lua/config/terminal.lua`.
- Remote-nvim's kitty launcher is in `lua/plugins/remote.lua`.

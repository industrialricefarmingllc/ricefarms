# quick-translate

A small translation popup for [Lucid](https://github.com/Sn3akyy1/lucid) and
Quickshell. **Super+T** opens it in the top-right corner, **Escape** or
**Super+T** again hides it, and it forgets everything between openings except
the target language.

It starts as a plain ask box — mark, sentence field, send button, three
language chips — and morphs into a conversation when you send the first line.
The motion follows the Material 3 Expressive curves the shell already uses:
the card grows out of its top-right anchor, the composer travels from the top
row to the bottom, the mark changes shape, and the loading indicator is the
M3 Expressive shape sequence.

The surface follows the shell rather than approximating it: the background is
Lucid's `bgOpaque`, the highlight is Lucid's `accent`, the containers use the
same `containerFill` maths, the corners are the same superellipse with the
`SquircleF` value from Settings, and the card sits on the `Top` layer so Lucid's
full-screen `lucid-overlay` soft-light wallpaper wash passes over it exactly as
it does over a window. Light and dark mode, wallpaper changes and settings
changes all arrive live through watched files.

```
┌───────────────────────────────────┐
│ ◉  Translate                      │
│    into Français               ×  │
│ ( Français ) ( Lëtzebuergesch ) ( Русский )
│ ───────────────────────────────── │
│                 Where is the…  ▐  │
│  ▐  Où se trouve la gare ?        │
│                                   │
│ [ Type a sentence…          ] (↑) │
└───────────────────────────────────┘
```

The top edge sits below the bar's reserved strip plus `general:gaps_out`, and
the right edge sits `gaps_out` from the screen edge. It follows the focused
monitor when it opens. The palette, surface seed, theme mode and UI/motion/
squircle settings are watched, so the widget changes with the wallpaper and the
shell settings without a restart.

## Requirements

- Arch Linux + Hyprland (developed against Hyprland 0.56 / Quickshell 0.3.2)
- [Quickshell](https://quickshell.org) (`qs`)
- [OpenCode](https://opencode.ai) signed in to the **OpenCode Go** provider
- Lucid is recommended for the palette and Google Sans Flex. Without it the
  widget falls back to a neutral dark palette and Noto Sans.

## Install

```sh
git clone <this-repo> ~/src/quick-translate
cd ~/src/quick-translate
./install.sh
```

The installer:

1. creates `~/.config/quick-translate/`,
2. adds a marked `SUPER+T` bind and a `-n` daemon start to
   `~/.config/hypr/custom.lua` (or a `source =`d `quick-translate.conf` on a
   `.conf` setup),
3. on a Lua config, adds a marked `super_tap_disarm` bind for `SUPER+T` so
   Lucid's bare-Super launcher tap does not also fire on the Super release,
4. reloads Hyprland,
5. starts the Quickshell daemon.

Both Hyprland files are backed up before editing.

Run `./install.sh --no-hypr` to leave the compositor alone, or
`./install.sh --no-start` to install without starting it now.

## Keys

| Key | Action |
|---|---|
| `Super+T` | open / close |
| `Esc` | close |
| `Enter` | send the sentence |
| `Shift+Enter` | newline in the sentence field |
| `>…` | meta-prompt: ask about the translation, or refine it |
| `↓` | focus the language row, keeping the current language and pulsing its chip |
| `Tab` / `Shift+Tab` | cycle languages while the row has focus |
| `←` / `→` | choose the language while the row has focus |
| `↑` / `Enter` | return from the chips to the composer |

The language row deliberately does **not** take `Tab` while you are typing.
Press `↓` to activate it — the current language stays selected and its chip
gets a small Material 3 Expressive shape pulse — or click a chip. From then on
`Tab` / `Shift+Tab` cycle the languages, and `↑` or `Enter` returns to the
composer.

## Meta prompts with `>`

A sentence beginning with `>` is a meta-message about the conversation:

- `>less formal` — re-translates the previous source sentence with that
  instruction and appends a new **Refined · Français** bubble. The refined
  translation becomes the current translation for later refinements and normal
  follow-up turns.
- `>why did you use “gare” rather than “station”?` — answers in **English**,
  in an **English** bubble. It does not change the translation.
- `>could you make it more polite?` — recognised as a refinement, not a
  question, and re-translated.
- `>what does this word mean?` — answered in English.
- If there is no previous translation yet, it answers in English and says there
  is nothing to refine.

The model is asked to return an internal `ANSWER:` or `TRANSLATION:` control
prefix; the widget strips it and styles the result. Translation history stays
clean: English questions/answers are kept out of the translation prompt, while a
refinement updates the last translation in that history. Opening or closing the
widget clears the whole meta conversation, like the rest of the chat state.

Meta requests are slightly more expensive than translations because they carry
the previous source, translation and recent Q&A: ~160–200 tokens, still with
zero reasoning tokens.

## Target languages

- **Français** — French
- **Lëtzebuergesch** — Luxembourgish
- **Русский** — Russian
- **Deutsch** — German

Only the language is persisted, in `~/.config/quick-translate/state.json`.
Opening, closing, and even a crash discard the conversation and the draft.

## Translation and token cost

The widget talks to the OpenCode Go provider directly:

- at startup it reads the active Go credential from the local OpenCode service
  (`opencode api get /api/credential`) and keeps it in memory only;
- a long-lived worker, `scripts/translate_server.py`, holds one keep-alive
  connection to the provider and preconnects when the widget daemon starts;
- each request is one JSON line over the worker's stdin/stdout and posts to the
  Responses API with:
  - model `gpt-6-luna`,
  - `reasoning.effort: "none"` — no thinking steps,
  - `x-opencode-session: quick-translate`,
  - the credential passed through the child's environment, never argv or disk;
- the response's `usage` is returned to the widget and shown in `debug`.

The normal prompt is small and reverse-aware: translate the final user message
into the selected language, or **into English if it is already in that
language**. It asks for an internal `TARGET:` / `TRANSLATION:` pair; the widget
strips the labels and uses the target for the bubble label. The last few turns
are included for context, but the final user message is what gets translated.
No tools, no code context, no OpenCode session history.

Reverse is automatic: with Français selected, an English sentence becomes
French and a French sentence becomes English. The target chips still select the
non-English language; English is not a fourth chip, it is the reverse output.

Measured against the provider on this machine:

| Request | Input | Output | Reasoning | Total | Provider time |
|---|---:|---:|---:|---:|---:|
| “Good morning.” → French | 61 | 14 | 0 | **75** | 1.3 s |
| “Bonjour, comment allez-vous ?” → English (reverse) | 64 | 18 | 0 | **82** | 3.3 s |
| `>less formal` (refinement) | 144 | 15 | 0 | **159** | 6.6 s (provider spike) |
| `>why “gare”…?` (English answer) | 155 | 47 | 0 | **202** | 3.1 s |

That is roughly **$0.00001** per short translation and **$0.00002–0.00004**
for a meta request.

The first request was slower before the worker kept the socket open: a new
HTTPS connection to `opencode.ai` took about **3.7 s** on this route, and the
provider's first request on a fresh connection was another ~1–3 s. With the
persistent worker, the connection/TLS cost is out of the per-request path.

The remaining latency is the provider itself. Five consecutive warm requests
measured **1.4 s, 1.5 s, 2.8 s, 3.2 s and 5.1 s** (median ~2.3 s). Streaming was
also tested: the first text delta arrived at roughly the same time as the
complete response (1.95/1.98 s, 3.78/3.78 s, 3.39/4.67 s), so streaming does not
improve these short translations. The first request after a daemon restart can
still be ~2.9 s while the provider warms up.

The local `opencode api` generate route was sometimes much slower under the same
load (80 s in testing), which is why the direct persistent worker is the
default. Lower than the provider's ~1.4 s floor would need a faster model or a
closer endpoint.

`./quick-translate debug` reports the latest `lastUsage`, `lastLatencyMs`
(provider time, not including any startup handshake), `lastKind`
(`assistant` / `refined` / `answer` / `instruction`), and the current
`lastTranslation` / `metaTurns`.

If the credential probe fails, the widget falls back to the local
`opencode api post /api/experimental/generate` route with the same model,
`variant: "none"`, and the same minimal prompt. The widget resolves `opencode`
from `PATH` and falls back to `~/.bun/bin/opencode` for that route and for the
credential probe.

## IPC and scripting

The daemon answers on the `quick-translate` target:

```sh
qs -p ~/src/quick-translate ipc call quick-translate toggle
qs -p ~/src/quick-translate ipc call quick-translate status
qs -p ~/src/quick-translate ipc call quick-translate language ru
qs -p ~/src/quick-translate ipc call quick-translate language de
qs -p ~/src/quick-translate ipc call quick-translate ask "Where is the station?"
qs -p ~/src/quick-translate ipc call quick-translate debug
```

The bundled wrapper is easier:

```sh
./quick-translate toggle
./quick-translate language fr
./quick-translate ask "Good morning"
./quick-translate status
./quick-translate debug
./quick-translate start|stop|restart
```

`ask` opens the widget if needed, sends the text through the normal flow, and
leaves the result on screen — useful for hotkey scripts and for testing.

`debug` returns JSON with the card geometry, focus, turn count, and language.

## How the placement works

The widget is a transparent full-screen layer surface on the focused monitor.
Only the painted card is in the input mask, so clicks outside it reach the
application underneath. The card is positioned from:

- `reserved[1]` (the bar's top strip) + the first value of
  `general:gaps_out` for the top edge,
- `general:gaps_out`'s second value for the right edge,
- `reserved[2]` as well if something reserves the right edge,
- plus a deliberate extra 20 px on the top and right for breathing room.

If Hyprland briefly reports `reserved = 0` while the bar is remapping, the
widget falls back to `barHeight + barTopMargin + shellGap` from Lucid's prefs,
then re-reads after 400 ms.

Those values are re-read on every open, so a moving/hiding bar or a gap change
is respected without restarting. The card's height is clamped to the screen.
The compositor-margin logic is in `TranslateWindow.qml` under
`refreshGeometry()`.

## Theme and soft-light wash

`components/Theme.qml` reads:

- `~/.cache/quickshell/matugen.json` (Lucid's generated palette),
- `~/.cache/quickshell/surface-seed.json` (the wallpaper's dominant hue used
  by Lucid's surface tint),
- `~/.cache/quickshell/theme_mode` (`light` / `dark`),
- `~/.config/quickshell/lucidprefs/prefs.json` (`uiScale`, `fontScale`,
  `motionScale`, `cornerScale`, `squircleF`, `surfaceDarkness`, `surfaceTint`,
  `accentPunch`),
- `~/.config/quickshell/assets/fonts/GoogleSansFlex.ttf` when present.

It reproduces Lucid's tone/container maths, so the widget's `bgOpaque`,
`accent`, `accentContainer`, `fgAccentContainer`, `text`, `subtext` and
`outline` resolve to byte-for-byte the same values as the bar and cards. This
was checked against `theme-dump.qml` in both the current dark palette and a
temporary light palette.

Typography is Lucid's too: Google Sans Flex with the shell's `bodyLarge` /
`labelLarge` / `titleMedium` sizes and weights. Cyrillic falls back to the same
system font the shell uses.

The surface is a `SquircleRect` using the copied `squircle_rect.frag.qsb`
shader and Lucid's `Prefs.squircleF` (0.8 here), so the corner is the same
superellipse the bar and widgets use, not a circular `Rectangle.radius`. The
corner-size dial (`cornerScale`) and `pill()` follow Lucid too.

The widget deliberately lives on the `Top` layer, below **lucid-overlay**. That
full-screen overlay is Lucid's 25% soft-light wallpaper wash; it passes over
this card exactly as it does over kitty, GTK apps and the bar. There is no
second wash in the widget, so it cannot double-blend. If Lucid's overlay is
absent, the widget still works but has no wash.

The compact box centres the input text vertically; the language rail starts at
the composer's left edge and leaves equal gaps above and below it. The expanded
composer keeps the card's 16 px bottom padding.

It does not import Lucid's singleton tree, so the widget keeps working when
the shell is updated and does not add load to the main `qs` process.

## Repository layout

```
shell.qml                  Quickshell entry, one hidden window
TranslateWindow.qml        placement, morph, chat, request, IPC
components/Theme.qml       palette and M3 metrics from Lucid's cache
components/LanguageRail.qml  keyboard-navigable language chips
components/MessageBubble.qml  user/assistant/answer/refined/error turns
components/LoadingMorph.qml   M3 Expressive loading shape
components/MaterialShape.qml  one morphable M3 shape
components/Icon.qml + Icons.js  Material Symbols paths used here
components/Shapes.js + ShapeRadii.js  androidx M3 shape outlines
components/squircle/       Lucid's squircle shader and mask
scripts/translate_server.py  persistent Go Responses worker (runtime)
scripts/translate.py         one-shot diagnostic call + usage
hypr/quick-translate.lua   the bind, for manual installs
hypr/quick-translate.conf  the .conf equivalent
install.sh / uninstall.sh
quick-translate            CLI wrapper around qs ipc
```

## Uninstall

```sh
./uninstall.sh
```

That removes the Hyprland block and stops the daemon. The remembered language
is left in `~/.config/quick-translate/state.json`; delete that directory if you
want it gone too.

## Notes

- The widget is a separate Quickshell daemon. It does not modify
  `~/.config/quickshell` and survives a Lucid update.
- The selected language and the mark use Lucid's bright `accent` (not a tonal
  container), matching the launcher's selected mode pill and active bar
  elements. The user bubble and other containers keep Lucid's
  `accentContainer`.
- `SUPER+T` is a chord, so the installer also inserts a
  `super_tap_disarm` bind into `hyprland.lua`. Without it, releasing Super
  after the chord also opens Lucid's launcher. If Lucid regenerates
  `hyprland.lua`, rerun `./install.sh` to put the marked block back.
- The squircle shader is Lucid's own `squircle_rect.frag.qsb`, copied beside
  the widget. If you change Qt's shader format/version and the shader stops
  loading, rebuild it with `qsb squircle_rect.frag -o squircle_rect.frag.qsb`.
- Lucid's shipped `keybinds.json` uses `Super+T` for the theme picker. If you
  load that file, move the theme picker in **Settings → Keybinds**; the
  installer prints a reminder when it sees the conflict.
- The shape outlines in `components/ShapeRadii.js` come from AndroidX's
  Material 3 shape library; the glyphs in `components/Icons.js` come from
  Google's Material Symbols. Both are Apache-2.0. The rest is MIT (see
  `LICENSE`).

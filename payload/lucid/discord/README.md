# Lucid Discord theme

A **colour-only** Equicord theme: it overrides Discord's own CSS custom
properties and leaves the base UI (layout, spacing, components, roundness)
exactly as Discord ships it.

`apply-theme.sh` used to write a Midnight theme only when Vesktop was installed
(`~/.config/vesktop/themes`). This directory replaces that with a normal matugen
template, so the same palette reaches every Discord client Equicord is patched
into — for wallpapers and for fixed themes alike.

## Files

- `lucid-colors.css.in` — the whole theme. Declares a small `--lucid-*` palette
  from matugen placeholders, then maps it onto Discord's surface / text /
  accent / border tokens.
- `header.css` — the Equicord theme metadata block (`@name Lucid`).
- `build-template.sh` — concatenates the two into
  `~/.config/matugen/templates/lucid-discord.css`.

Borders use `color-mix(…, 10%, transparent)`: 10% opacity, not a solid outline.

The main body uses `surface_container` — Lucid's `Theme.bgOpaque`, the same role
`app-surface-sync.sh` writes as kitty's background — rather than the raw matugen
`surface` role, which sits two levels lower. The ladder above it is shifted too:
raised surfaces use `surface_container_highest`, and the topmost use
`surface_bright`. The server list (`surface_container_lowest`) and the app frame
/ top bar (`surface_container_low`) are left at their original levels.

The font stack is `Whitney` (Discord's pre-gg-sans font) when installed, then
**Nebula Sans** — an SIL-OFL drop-in Whitney SSm replacement installed at
`~/.local/share/fonts/nebula-sans` — then Discord's stock stack.

## How it renders

`~/.config/matugen/config.toml` has two template blocks:

```
[templates.equicord]
output_path = '~/.config/Equicord/themes/lucid-discord.css'

[templates.equicord_alt]
output_path = '~/.config/EquicordData/themes/lucid-discord.css'
```

- wallpaper changes: `set-wallpaper.sh` runs matugen with that config
- fixed themes: `apply-theme.sh` renders the templates with the theme palette

Either way the theme file is rewritten in place. Equicord watches the themes
folder and re-injects the file with a cache-busting query, so it updates live
once the theme is enabled (Settings → Themes → Lucid).

## Editing

Change colours in `lucid-colors.css.in`, then run:

```sh
~/.config/lucid/discord/build-template.sh
```

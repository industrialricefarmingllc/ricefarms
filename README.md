# rice replica

one click rice. Entirely slopped up because lazy. Most likely won't work flawlessly. Do your own thinking.

- **a)** tty1/kmscon  tty7/hyprland split + hotkeyed switch on **F15**
  (QMK Skeletyl `F15=evdev185`, `desktop-hotkey-daemon` watching evdev,
  `desktop-toggle` via logind `SwitchTo`, SUID `chvt-fast`,
  `kmscon-modepin.so` DP-1 @120Hz pin, autologin drop-ins, on-demand
  `getty@tty7` launched from `~/.zprofile` → `start-hyprland`),
  login-free boot (getty/kmscon/sddm autologin, wheel NOPASSWD via
  `/etc/sudoers.d` drop-in + `visudo` check, `loginctl enable-linger`),
  key repeat **125/125** (kmscon delay, Hyprland, sway, KDE `kcminputrc`)
- **b)** Hyprland (Lua live config) + **lucid** Quickshell shell +
  **e-ink shader** (`reading_mode.glsl`, SUPER+K) + **Lucid launcher**
  (pibble is retired as a launcher and kept as source only) +
  **quick-translate** (SUPER+T) + **hypr-edge-swipe** touch gestures
  (vendored source, rebuilt with `make`) + full hotkey map +
  **liquid-glass-hypr** plugin (rebuilt from vendored source at pinned
  commit) + Lucid's `lucid-{glass,monitors,settings,specials,startup}.lua`
  state + `/usr/local/bin` helpers (`hypr-inputs-ready`,
  `minimize/restore-all`, `pin/unpin-all`, `liquid-glass-toggle` (alias
  `lg`; kitty falls back to an opaque matugen background when glass is off),
  `gpu-tty-foot`; source username rewritten to target at install)
- **c)** kitty (including `font-mode.conf`, `lucid-glass.conf` and
  `lucid-surface.conf`), **bucklespring** (`kalih-box-white`,
  `-s 25 -g 50`; built from upstream with `make libinput=1` so it works in
  native Wayland apps) + custom audio stack (PipeWire/Wireplumber/VAC/Carla),
  neovim (split `lua/config` + `lua/plugins` tree), **zed custom build**
  (pinned commit, whole `/usr/lib/zed` copied), all `~/*.sh` HOME scripts +
  `~/.local/bin` helpers (including `lucid-auto-brightness`, `steam-hidpi`,
  `zed-x11`, `zed-soft`, `neoread`) + the `bulk` cgroup runner
- **d)** all dotfiles (zsh + **oh-my-zsh** pinned stock clone, theme
  `afowler`, `plugins=(git)` — same `.zshrc`, verified identical;
  **opencode local config** (`~/.config/opencode` + `~/.opencode`,
  node deps via `bun install`),
  bash/X/pam/git/tmux-conf, `kcminputrc` repeat, systemd user units
  (including `auto-brightness`, `bulk.slice`, `session.slice` weights and
  the bucklespring audio-follow drop-in), GTK rc/settings,
  Helium browser flags, `skwd-wall-v2` config,
  foot/dunst/btop/opencode/sway/waybar)

## Secrets policy (standing rule)

**API keys and service passwords are never committed — under any
circumstances.** The opencode config ships `${CONTEXT7_API_KEY}` as a
placeholder; `--export` redacts known secret patterns on every run and
excludes opencode's generated `service.json` local API password, so
credentials can't slip back in. The test suite fails on any live key in
`payload/` or git history. After
installing, insert your real key into
`~/.config/opencode/opencode.json` on the target (and never commit it).
SSH private keys are likewise never exported (`~/.ssh` is not in the
export allowlist).
- **e)** matugen (config + templates, including the kitty font/glass
  templates) + wallpapers from `~/Pictures/wallpapers/matugen` +
  **skwd-wall** backend config (`skwd-deck` / `skwd-wall-v2` AUR packages;
  awww is the fallback when skwd is absent)
- **f)** tmux setup (continuum/resurrect/opencode/tpm plugins + snapshot)

## Usage

On the TARGET machine (fresh Arch, same username ideally):

```bash
git clone <this-repo> ~/src/ricefarms
cd ~/src/ricefarms
# copy payload-large/ alongside (usb/rsync) — see below
./install.sh --yes
```

Subset / preview:

```bash
./install.sh --yes --dry-run                 # preview everything
./install.sh --yes --only a,b                # just tty + hyprland stack
./install.sh --yes --only c,d,e,f            # just apps/dots/matugen/tmux
```

On the SOURCE machine (re-snapshot after rice changes):

```bash
./install.sh --export
```

## Large binaries (payload-large/, Git LFS)

Wallpapers + zed binaries are too big for plain git (GitHub hard-rejects
files >100MB), so they live in `payload-large/` tracked via **Git LFS**.
A plain clone replicates everything — no USB/rsync needed:

```bash
git clone <this-repo> ~/src/ricefarms   # smudge filter fetches LFS files
cd ~/src/ricefarms && git lfs pull      # if your clone skipped them
./install.sh --yes
```

- `wallpapers-matugen.tar.zst` (~700M → `~/Pictures/wallpapers/matugen`)
- `bucklespring-kalih-box-white.tar.zst` (~17M → `~/.local/share/bucklespring`)
- `zed-custom.tar.zst` (~350M → `/usr/lib/zed` + `/usr/bin/zeditor`)

Without them the installer warns and falls back (rebuild zed from pinned
commit in `payload/zed-pin.txt` — ~30min; rsync wallpapers manually).

## Tests

Every installer function/phase has unit tests (mocked `sudo`/`systemctl`,
temp payload+home, no network):

```bash
bash tests/test_install.sh   # 224 tests, must all pass
```

## Layout

```
install.sh            one-click installer (export + install, idempotent)
payload/              vendored configs + sources (git-tracked, ~20M)
payload-large/        tarballs (Git LFS, ~1.1G, see README inside)
tests/test_install.sh unit tests for every part
COORDINATION.md       build notes / source inventory
```

## Notes / gotchas

- Arch-only (CachyOS repos on source). `phase_packages` is best-effort
  elsewhere.
- Needs `%wheel ALL=(ALL) NOPASSWD: ALL` (source has it) for
  `desktop-toggle`'s `chvt`/`systemctl`/`loginctl` calls; installer prints a
  hint if `/etc/sudoers.d/10-ricefarms-nopasswd` is missing.
- `lucid-capture.so` is intentionally NOT shipped (source has it DISABLED
  after a 2026-09-03 SEGV) — installer rebuilds from source, failure is
  non-fatal.
- **pibble is retired as a launcher** (2026-10-27): its source is still
  installed under `~/src/pibble`, but there is no autostart, no
  `~/.local/bin/pibble` symlink and no keybinds. The Lucid launcher (bare
  SUPER) replaces it.
- **skwd-wall** (`skwd-deck`, `skwd-wall-v2`, `skwd-paper`) is installed
  from the AUR and owns the wallpaper when enabled; `awww` remains the
  fallback and is skipped when `skwd-walld` is active.
- **hypr-edge-swipe** is vendored source and rebuilt on the target. It needs
  `hyprland` headers matching the running compositor (`pkg-config hyprland`).
- The source kernel is `linux-surface` with `iptsd` (Surface ALS). `iptsd`
  is in the package list; the patched kernel is not auto-installed — add the
  Surface repo/kernel on non-Surface targets.
- ELF helpers in `~/.local/bin` (`steamie`, `loupe`, `stacktest`,
  `dndprobe`, `spotatui`) are recorded in `payload/local-bin/ELFS_SKIPPED.txt`,
  not vendored — rebuild/copy them manually.
- Reboot (or re-login) after install for kmscon/systemd changes. From tty1,
  press **F15** (or Ctrl+Alt+T) to jump to Hyprland on tty7.

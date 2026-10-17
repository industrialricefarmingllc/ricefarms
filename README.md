# ricefarms — 1:1 rice replicator

One-click installer that replicates this machine's full setup onto another
Arch Linux system:

- **a)** tty1/kmscon ↔ tty7/hyprland split + hotkeyed switch on **F15**
  (QMK Skeletyl `F15=evdev185`, `desktop-hotkey-daemon` watching evdev,
  `desktop-toggle` via logind `SwitchTo`, SUID `chvt-fast`,
  `kmscon-modepin.so` DP-1 @120Hz pin, autologin drop-ins, on-demand
  `getty@tty7` launched from `~/.zprofile` → `start-hyprland`)
- **b)** Hyprland (Lua live config) + **lucid** Quickshell shell +
  **e-ink shader** (`reading_mode.glsl`, SUPER+K) + **pibble** app launcher
  + full hotkey map
- **c)** kitty, **bucklespring** (`kalih-box-white`, `-s 25 -g 50`) + custom
  audio stack (PipeWire/Wireplumber/VAC/Carla), neovim + config,
  **zed custom build** (pinned commit, whole `/usr/lib/zed` copied),
  all `~/*.sh` HOME scripts + `~/.local/bin` helpers
- **d)** all dotfiles (zsh/bash/X/pam/git/tmux-conf, systemd user units,
  foot/dunst/btop/opencode/sway/waybar)
- **e)** matugen (config + 11 templates) + wallpapers from
  `~/Pictures/wallpapers/matugen`
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

## Large binaries (payload-large/, NOT in git)

GitHub can't hold these, so they live in `payload-large/` (gitignored).
Copy the directory to the target at the same relative path
(`<repo>/payload-large/`) via USB/rsync:

- `wallpapers-matugen.tar.zst` (~700M → `~/Pictures/wallpapers/matugen`)
- `bucklespring-kalih-box-white.tar.zst` (~17M → `~/.local/share/bucklespring`)
- `zed-custom.tar.zst` (~350M → `/usr/lib/zed` + `/usr/bin/zeditor`)

Without them the installer warns and falls back (rebuild zed from pinned
commit in `payload/zed-pin.txt` — ~30min; rsync wallpapers manually).

## Tests

Every installer function/phase has unit tests (mocked `sudo`/`systemctl`,
temp payload+home, no network):

```bash
bash tests/test_install.sh   # 105 tests, must all pass
```

## Layout

```
install.sh            one-click installer (export + install, idempotent)
payload/              vendored configs (git-tracked, ~11M)
payload-large/        tarballs (gitignored, ~810M, see README inside)
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
- ELF helpers in `~/.local/bin` (`steamie`, `loupe`, `stacktest`,
  `dndprobe`) are recorded in `payload/local-bin/ELFS_SKIPPED.txt`, not
  vendored — rebuild/copy them manually.
- Reboot (or re-login) after install for kmscon/systemd changes. From tty1,
  press **F15** (or Ctrl+Alt+T) to jump to Hyprland on tty7.

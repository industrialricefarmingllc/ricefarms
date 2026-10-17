# ricefarms — coordination file (context offload)

Goal: 1:1 replicate to another system via one-click `install.sh` + unit tests for every part.
Repo: `~/src/ricefarms`
Date: 2026-10-17
Source host: ricefarms (Arch, user nicerice, HOME /home/nicerice)

## Scope (user)
a) tty1/kmscon - tty7/hyprland setup incl. F15 hotkeyed switch
b) lucid shell, e-ink shader, pibble launcher, hotkey controls from hyprland
c) kitty, bucklespring + custom audio, neovim + config, zed (copy whole build), all scripts in HOME
d) all dotfiles
e) wallpapers from matugen folder + matugen in general
f) tmux setup (added)

## Findings (from 4 explore agents, verified)
- kmscon: /etc/kmscon/kmscon.conf (47 lines), drop-ins modepin.conf (LD_PRELOAD /usr/local/lib/kmscon-modepin.so, src /usr/local/src/kmscon-dp1-only.c), restart.conf, kmsconvt@tty1.service.d/autologin.conf (login -p -f nicerice)
- TTY split: autovt@tty1 -> kmsconvt, autovt@tty2/3 -> getty, getty.target.wants: getty@tty2,3 + kmsconvt@tty1. getty@tty7 disabled, started on-demand by desktop-toggle. Autologin overrides on tty1/2/3/7. logind.conf stock + hibernate-power-key.conf. No DM (sddm disabled, no greetd/ly). Hyprland launched via ~/.zprofile on tty7 -> start-hyprland.
- F15: QMK Skeletyl F15=evdev185. No hwdb/keyd. Daemon: ~/.config/systemd/user/desktop-hotkey.service -> /usr/local/bin/desktop-hotkey-daemon (python, watches evdev, F15_CODE 185, config ~/.config/desktop-toggle/config). Hyprland binds F15/code185 + CTRL_ALT_T -> /usr/local/bin/desktop-toggle; ALT_F15 -> --stop. Switcher /usr/local/bin/desktop-toggle + SUID /usr/local/bin/chvt-fast (VT_ACTIVATE). Uses logind SwitchTo, flock, hyprctl, ensure_drm_master. Symlinks desktop/sway-toggle/wayland-toggle. ~/desktop-toggle.sh older copy. wheel NOPASSWD.
- Hyprland live config is Lua: ~/.config/hypr/hyprland.lua (826L) + custom.lua (488L) + shader.lua (236L) + colors.lua + hyprland.conf (419L legacy) + custom.conf + colors.conf + hyprpaper.conf + current_wallpaper + shaders/{main,matugen-agx,reading_mode}.glsl + scripts/*. Autostart: pibble start, quickshell (lucid), awww-daemon, liquid-glass plugin, bucklespring, vac. Lucid refs: qs ipc moji/snap/settings/powerMenu.
- Lucid = Quickshell shell: ~/.config/quickshell/shell.qml + lucid*/ + Prefs/Theme.qml, ~/.config/lucid/{apply-theme,gen-pywal,themes/*}, ~/.config/systemd/user/quickshell.service (ExecStart /usr/bin/qs). Quickshell 0.3.1. lucid-capture: ~/src/lucid-capture/lucid-capture.so + src + hyprpm.toml + Makefile (HyprGlass fork, DISABLED due SEGV).
- E-ink shader: native decoration:screen_shader, no hyprshade. shaders/main.glsl (58L), reading_mode.glsl (177L E-INK), matugen-agx.glsl (69L), shader.lua manager (SUPER+K reading, SUPER+G AgX, SUPER+ALT+S off). Cache: current_shader=Main, reading_mode=off.
- Pibble: ~/src/pibble/ (pibble bash 319L, shell.qml, config/, launcher/, services/, flyouts/, ...). No compile, qs -p. ~/.local/bin/pibble symlink. Autostart exec-once pibble start. Binds: SUPER tap (bindr), $mod R, $mod W wallpapers, F15 close-then-toggle.
- Hotkeys: extract all bind= from hyprland.conf/lua + custom.* + shader.lua (see agent output).
- Kitty: ~/.config/kitty/kitty.conf (36L) + matugen-colors.conf (71L auto-gen). font Noto Sans Mono 9, bg opacity 0 (liquid-glass provides bg).
- Bucklespring: manual make install (/usr/bin/buckle + /usr/local/bin/buckle identical 51800B). Service ~/.config/systemd/user/bucklespring.service (kalih-box-white, -s 25 -g 50). Hypr exec-once fallback. Banks ~/.local/share/bucklespring/{boxjade 2.1M, kalih-box-white 17M 505 files ACTIVE, to-the-past 6.6M}. No /etc config.
- Custom audio ~/audio-stack/ (README diagram, carla-vst.sh, vac-up/down.sh, chain-connect.sh, vac-gui.py 284L, carla/ empty). PipeWire: ~/.config/pipewire/pipewire.conf.d/10-lowlatency.conf, ~/.config/wireplumber/wireplumber.conf.d/50-rode-vac.conf, ~/.config/vac-gui/whitelist.json. Units vac.service, vac-enforcer.service.
- Neovim: pacman cachyos-extra-v3 0.12.5-1.1, /usr/bin/nvim. Config ~/.config/nvim/init.lua (530L, lazy.nvim, remote-nvim + telescope only, transparent, VSCode-like, ~150 keymaps) + lua/lualine/themes/empty + colors/empty + lazy-lock.json. Data ~/.local/share/nvim 15M.
- Zed: ~/src/zed git clone 1.4G main ahead25 ee5cdf5, toolchain 1.98.1, version 1.25.0, no target/. Custom build logs ~/.cache/zed-build-*.log. Installed: NO ~/.local/bin/zed, NO /opt/zed; pacman zed 1.18.1-1 provides /usr/bin/zeditor (3.2M stub) + /usr/lib/zed/zed-editor (351M) BUT zeditor --version shows local commit ee5cdf5 (overwrote pacman files). Backup ~/.cache/zed-pacman-backup/{zed-editor-1.18.1 365M, zeditor-1.18.1 3M}. Desktop ~/.local/share/applications/dev.zed.Zed.desktop (ZED_BUILD_REMOTE_SERVER=never). Config ~/.config/zed/{settings.json,keymap.json,development_credentials,AGENTS.md} + extensions.
- HOME scripts: ~60 *.sh top-level (see agent list) + ~/.local/bin/* (21 entries incl pibble symlink, hypr-set-wallpaper, carbonyl, tobii, steamie ELF 14M, loupe ELF 8M, dndprobe/stacktest + .c, kzones-shift-daemon.py, osc52, pnpm11, plasma shims).
- Dotfiles: ~/.config/* 73 entries, no stow, no dotfiles repo, only Singleton symlinks. Key: .zshrc 14863B (tmux continuum per-TTY main_$tty), .zshenv 302B, .zprofile 2761B (tty7 -> start-hyprland), .bashrc/.bash_profile/.profile/.Xresources/.pam_environment/.gitignore/.ignore/.tmux.conf 15255B + bak.
- Matugen: ~/.config/matugen/config.toml (prefer saturation, wallpaper set=false via awww wipe 1.2, 11 templates) + templates/* (11 files). Wallpapers ~/Pictures/wallpapers/{matugen ~50 files CURRENT, catppuccin-mocha ~150, gruvbox, nightfox, nord, pywal, tokyo-night} + ~/.config/hypr/wallpapers/default-{dark,light}.jpg + surface-dots/wallpapers.conf. State: current_wallpaper=wallhaven-dgrx2l.jpg, theme dark. Scripts ~/matugen-sync-dev.sh 221L + ~/matugen-watch-dev.sh 93L. No matugen unit (hypr + path + zsh triggers). Units: kitty-theme-sync.path/service, lg-rules.path/service/timer, quickshell.service, etc. Hypr wallpaper: awww-daemon (hyprpaper disabled, hyprpaper.conf compat only), scripts/wallpaper-{matugen,restore,engine,sync-theme-oneshot}.sh + theme-toggle.sh + apply-gtk-mode.sh + agx-smooth-transition.sh + watch-theme-mode.sh.
- Packages: Arch+CachyOS repos. Rice pkgs: awww, dunst, foot, hyprland 0.56.2, hyprpaper, hypr* utils, kitty 0.48.2, kmscon 10.0.3, matugen 4.2.0, neovim 0.12.5, quickshell 0.3.1, sway, tmux 3.7c, waybar, zed 1.18.1, zsh 5.9.2, paru, helium-browser-bin, nvidia-580xx-dkms. bucklespring + opencode NOT pacman.
- Tmux: ~/.tmux.conf 260L (tmux-256color, Tc/RGB kitty, extended-keys, OSC52, prefix C-z, mouse, continuum-restore, resurrect-capture-pane, tpm plugins), ~/.tmux/plugins/{tpm,sensible,continuum,resurrect,resurrect-opencode,auto-resize}, ~/.local/share/tmux/resurrect/*, ~/.config/tmux ABSENT.

## Repo design (DECIDED)
Layout:
  ricefarms/
    install.sh            <- ONE-CLICK installer, idempotent, --yes --dry-run --only a,b,c,d,e,tmux --export
    tests/test_install.sh <- shunit2-style, no network, unit-tests every function via mocking
    payload/              <- vendored small configs (generated by install.sh --export on SOURCE)
      etc/kmscon/kmscon.conf, etc/systemd/system/... drop-ins, etc/sudoers.d/..., usr-local-bin/{desktop-toggle,desktop-hotkey-daemon,chvt-fast-src,...}
      hypr/ (hyprland.lua, custom.lua, shader.lua, *.conf, shaders/, scripts/)
      quickshell/ (lucid shell.qml + lucid*/), lucid/, lucid-capture/ (src, NOT .so — rebuilt)
      pibble/ (full dir, no build needed)
      kitty/, nvim/, zed-config/, matugen/, wallpapers-matugen/ (FULL ~50 files), hypr-wallpapers/
      zsh/{.zshrc,.zshenv,.zprofile}, bash/{.bashrc,.bash_profile,.profile}, Xresources, pam_environment, tmux/{.tmux.conf}, gitignore
      local-bin/ (scripts, NOT ELFs — ELFs rebuilt/copied as tarballs), home-scripts/ (~60 *.sh)
      systemd-user/ (*.service/path/timer), pipewire/, wireplumber/, vac-gui/, bucklespring.service
      audio-stack/ (scripts + README, NOT carla project)
      manifests/packages-arch.txt, zed-pin.txt (commit ee5cdf5), fonts.txt
      bucklespring-sounds-manifest.txt (banks listed; tarballs external due size — installer rsyncs or rebuilds)
    README.md
    COORDINATION.md (this file)

Installer modes:
  install.sh --export   : run ON SOURCE to snapshot live files into payload/ (rsync -a, no deletion)
  install.sh (default)  : run ON TARGET, copies payload -> /, $HOME, enables units, installs pkgs, builds zed/lucid-capture/modepin/chvt-fast, restores wallpapers+matugen, starts services
  install.sh --only <csv>: subset (a,tty | b,hypr | c,apps | d,dots | e,matugen | f,tmux | all)
  install.sh --dry-run, --yes (skip confirm), --source-dir (payload path)

Phases (functions, each unit-tested):
  log/info/warn/die, require_root_or_sudo, detect_arch, confirm, backup_file,
  phase_packages (paru/pacman rice list),
  phase_tty_kmscon (a), phase_hypr_lucid_pibble_shader (b), phase_apps (c: kitty/buckle/audio/nvim/zed/home-scripts),
  phase_dotfiles (d), phase_matugen_wallpapers (e), phase_tmux (f),
  enable_units, build_* (zed, lucid-capture, modepin, chvt-fast, buckle), verify

Tests: tests/test_install.sh sources install.sh with RICEFARMS_NOEXEC=1, mocks pacman/systemctl, asserts each phase function exists + dry-run copies correct files + binds present + shader files + F15 daemon + tmux plugins. Must run offline: `bash tests/test_install.sh`.

## TODO
- [x] Explore (agents done)
- [ ] Inventory exact file sizes/paths for payload decisions
- [ ] Write install.sh (single file, functions per phase)
- [ ] Run install.sh --export on SOURCE to populate payload/
- [ ] Write tests/test_install.sh covering EVERY function
- [ ] Run tests, fix failures
- [ ] git init + initial commit in ~/src/ricefarms

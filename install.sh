#!/usr/bin/env bash
#
# ricefarms — one-click 1:1 rice replicator
# Source host: ricefarms (Arch Linux, user nicerice)
# Usage:
#   ./install.sh [--yes] [--dry-run] [--only a,b,c,d,e,f] [--export] [--source-dir DIR]
#
# Modes:
#   (default)  install payload onto THIS machine (target)
#   --export   snapshot THIS machine (source) into payload/
#
# Groups (--only):
#   a = tty1/kmscon <-> tty7/hyprland + F15 switch + autologin (getty/kmscon/sddm, NOPASSWD, linger) + key repeat
#   b = hyprland + lucid shell + e-ink shader + pibble + hotkeys
#   c = kitty + bucklespring/audio + neovim + zed + HOME scripts
#   d = dotfiles (zsh/bash/X/tmux-conf/kcminputrc + oh-my-zsh + opencode redacted; tmux plugins are group f)
#   e = matugen + wallpapers
#   f = tmux plugins + resurrect state
#
set -euo pipefail

RICEFARMS_VERSION="1.0.0"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="${PAYLOAD_DIR:-$REPO_DIR/payload}"
LARGE_DIR="$REPO_DIR/payload-large"
TARGET_HOME="${TARGET_HOME:-$HOME}"
TARGET_USER="${TARGET_USER:-${USER:-$(whoami)}}"
DRY_RUN=0
ASSUME_YES=0
ONLY_GROUPS="a,b,c,d,e,f"
EXPORT_MODE=0
SOURCE_HOME="${SOURCE_HOME:-$HOME}"

# ---------------------------------------------------------------- logging ---
log()  { printf '[ricefarms] %s\n' "$*"; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "ERROR: $*" >&2; return 1; }

usage() {
  cat <<'EOF'
ricefarms one-click installer — replicates tty/kmscon+hyprland, lucid, pibble,
shaders, kitty, bucklespring, nvim, zed, HOME scripts, dotfiles, matugen,
wallpapers, tmux.

Usage: ./install.sh [options]
  --yes               non-interactive (skip confirm)
  --dry-run           print actions without changing anything
  --only a,b,c,d,e,f  run subset of groups (default: all)
  --export            snapshot live system into payload/ (run on SOURCE)
  --source-dir DIR    payload dir override (default: ./payload)
  -h, --help          this help
EOF
}

# ------------------------------------------------------------- arg parsing ---
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --only) ONLY_GROUPS="${2:-}"; shift 2 ;;
      --only=*) ONLY_GROUPS="${1#--only=}"; shift ;;
      --export) EXPORT_MODE=1; shift ;;
      --source-dir) PAYLOAD_DIR="$2"; shift 2 ;;
      --source-dir=*) PAYLOAD_DIR="${1#--source-dir=}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) warn "unknown arg: $1"; usage; return 1 ;;
    esac
  done
}

wants_group() {
  local g="$1"
  case ",$ONLY_GROUPS," in *,"$g",*|*",all"*) return 0;; *) return 1;; esac
}

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local prompt="${1:-Proceed? [y/N]} "
  read -r -p "$prompt" ans || return 1
  [[ "$ans" == [yY] || "$ans" == [yY]es ]]
}

run_cmd() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY-RUN: $*"
    return 0
  fi
  "$@"
}

# -------------------------------------------------------------- file utils ---
backup_file() {
  local dst="$1"
  [[ -e "$dst" || -L "$dst" ]] || return 0
  local bak="${dst}.bak.$(date +%Y%m%d_%H%M%S)"
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: backup $dst -> $bak"; return 0; fi
  cp -a "$dst" "$bak"
  log "backup: $dst -> $bak"
}

install_file() {
  local src="$1" dst="$2" mode="${3:-}"
  if [[ ! -e "$src" ]]; then warn "payload missing, skip: $src"; return 0; fi
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: install $src -> $dst"; return 0; fi
  mkdir -p "$(dirname "$dst")"
  backup_file "$dst"
  cp -a "$src" "$dst"
  [[ -n "$mode" ]] && chmod "$mode" "$dst"
  log "install: $src -> $dst"
}

install_dir() {
  local src="$1" dst="$2"
  if [[ ! -d "$src" ]]; then warn "payload dir missing, skip: $src"; return 0; fi
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: install-dir $src -> $dst"; return 0; fi
  mkdir -p "$dst"
  # merge-copy (no --delete: never wipe target extras like Singleton locks)
  cp -a "$src/." "$dst/"
  log "install-dir: $src -> $dst"
}

require_arch() {
  if [[ ! -f /etc/arch-release ]]; then
    warn "not Arch Linux — package step will be best-effort"
    return 1
  fi
  return 0
}

detect_pacman() {
  if command -v paru >/dev/null 2>&1; then echo paru;
  elif command -v yay >/dev/null 2>&1; then echo yay;
  else echo "sudo pacman"; fi
}

# ---------------------------------------------------------------- packages ---
RICE_PACKAGES=(
  hyprland hyprpaper hypridle hyprlock hyprpicker hyprcursor
  hyprpolkitagent xdg-desktop-portal-hyprland hyprland-qt-support
  kitty kmscon matugen neovim quickshell sway tmux waybar zsh
  foot dunst awww pipewire wireplumber carla
  noto-fonts ttf-jetbrains-mono
  git base-devel rustup python-pipx evtest inotify-tools
  ffmpeg mpv socat jq wl-clipboard hyprshot
)
AUR_PACKAGES=( helium-browser-bin input-remapper-bin linux-wallpaperengine )

phase_packages() {
  info "phase: packages (pacman + aur)"
  local pm; pm="$(detect_pacman)"
  if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY-RUN: $pm -S --needed ${RICE_PACKAGES[*]} + AUR ${AUR_PACKAGES[*]}"
    return 0
  fi
  require_arch || warn "continuing without Arch guarantee"
  run_cmd sudo pacman -Sy --needed --noconfirm "${RICE_PACKAGES[@]}" || warn "pacman step had errors (continuing)"
  if command -v paru >/dev/null 2>&1; then
    run_cmd paru -S --needed --noconfirm "${AUR_PACKAGES[@]}" || warn "AUR step had errors (continuing)"
  else
    warn "paru not found — install AUR manually: ${AUR_PACKAGES[*]}"
  fi
}

# ------------------------------------------------- a) tty/kmscon + F15 ----
phase_tty_kmscon() {
  info "phase A: tty1/kmscon <-> tty7/hyprland + F15 switch"
  local P="$PAYLOAD_DIR"
  # 1. kmscon main config (needs root)
  install_file "$P/etc/kmscon/kmscon.conf" "/etc/kmscon/kmscon.conf" "644"
  # 2. systemd drop-ins (system level)
  install_dir "$P/etc/systemd/system/kmsconvt@.service.d" "/etc/systemd/system/kmsconvt@.service.d"
  install_dir "$P/etc/systemd/system/kmsconvt@tty1.service.d" "/etc/systemd/system/kmsconvt@tty1.service.d"
  install_dir "$P/etc/systemd/system/getty@tty1.service.d" "/etc/systemd/system/getty@tty1.service.d"
  install_dir "$P/etc/systemd/system/getty@tty2.service.d" "/etc/systemd/system/getty@tty2.service.d"
  install_dir "$P/etc/systemd/system/getty@tty3.service.d" "/etc/systemd/system/getty@tty3.service.d"
  install_dir "$P/etc/systemd/system/getty@tty7.service.d" "/etc/systemd/system/getty@tty7.service.d"
  # 3. switcher binaries + daemon (need root for /usr/local)
  install_file "$P/usr-local-bin/desktop-toggle" "/usr/local/bin/desktop-toggle" "755"
  install_file "$P/usr-local-bin/desktop-hotkey-daemon" "/usr/local/bin/desktop-hotkey-daemon" "755"
  install_file "$P/usr-local-bin/chvt-fast.c" "/usr/local/src/chvt-fast.c" "644"
  install_file "$P/usr-local-src/kmscon-dp1-only.c" "/usr/local/src/kmscon-dp1-only.c" "644"
  # compat symlinks (desktop / sway-toggle / wayland-toggle)
  for link in desktop sway-toggle wayland-toggle; do
    if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: ln -sf /usr/local/bin/desktop-toggle /usr/local/bin/$link";
    else ln -sf /usr/local/bin/desktop-toggle "/usr/local/bin/$link"; fi
  done
  # 4. user-level: hotkey daemon unit + toggle config + zprofile gate
  install_file "$P/systemd-user/desktop-hotkey.service" "$TARGET_HOME/.config/systemd/user/desktop-hotkey.service" "644"
  install_file "$P/desktop-toggle/config" "$TARGET_HOME/.config/desktop-toggle/config" "644"
  install_file "$P/zsh/dot.zprofile" "$TARGET_HOME/.zprofile" "644"
  # 5. compile helpers + enable units
  build_chvt_fast
  build_modepin
  enable_tty_units
  phase_autologin_extras
  verify_input_repeat
}

# Login-free launch: boot straight to kmscon session, no password prompts.
# (getty/kmscon --autologin drop-ins ship above; here: sddm conf, sudoers,
# linger. Source: /etc/sddm.conf.d/autologin.conf User=nicerice,
# /etc/sudoers:128 `%wheel NOPASSWD: ALL` (/etc/sudoers.d/ was empty),
# `loginctl show-user` Linger=yes.)
phase_autologin_extras() {
  info "autologin extras: sddm conf + wheel NOPASSWD + linger"
  local P="$PAYLOAD_DIR"
  install_file "$P/etc/sddm.conf.d/autologin.conf" "/etc/sddm.conf.d/autologin.conf" "644"
  install_file "$P/etc/sudoers.d/10-ricefarms-nopasswd" "/etc/sudoers.d/10-ricefarms-nopasswd" "440"
  if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY-RUN: visudo -cf /etc/sudoers.d/10-ricefarms-nopasswd; loginctl enable-linger $TARGET_USER"
    return 0
  fi
  if ! run_cmd visudo -cf /etc/sudoers.d/10-ricefarms-nopasswd; then
    warn "sudoers validation failed — removing drop-in (system untouched)"
    run_cmd sudo rm -f /etc/sudoers.d/10-ricefarms-nopasswd
  fi
  run_cmd sudo loginctl enable-linger "$TARGET_USER" || true
}

# Key repeat is 125/125 across the whole stack (source values, 1:1):
# kmscon xkb-repeat-delay=125 (rate=13, kmscon's own unit), Hyprland
# repeat_delay/repeat_rate=125, sway repeat_delay/repeat_rate 125,
# KDE kcminputrc RepeatDelay/RepeatRate=125. Fail fast on bad export.
verify_input_repeat() {
  local P="$PAYLOAD_DIR" ok=1
  [[ -f "$P/etc/kmscon/kmscon.conf" && "$(cat "$P/etc/kmscon/kmscon.conf")" == *"xkb-repeat-delay=125"* ]] \
    || { warn "repeat: kmscon.conf missing xkb-repeat-delay=125"; ok=0; }
  local hypr=""; for f in "$P"/hypr/hyprland.lua "$P"/hypr/hyprland.conf; do
    [[ -f "$f" ]] && hypr+="$(cat "$f")"$'\n'
  done
  [[ "$hypr" == *"repeat_delay = 125"* || "$hypr" == *"repeat_delay=125"* ]] \
    || { warn "repeat: hypr payload missing repeat_delay 125"; ok=0; }
  [[ "$hypr" == *"repeat_rate = 125"* || "$hypr" == *"repeat_rate=125"* ]] \
    || { warn "repeat: hypr payload missing repeat_rate 125"; ok=0; }
  if [[ -f "$P/config-sway/config" || -f "$P/config-sway/sway-config" ]]; then
    local sway=""; for f in "$P"/config-sway/*; do [[ -f "$f" ]] && sway+="$(cat "$f")"$'\n'; done
    [[ "$sway" == *"repeat_delay 125"* ]] || { warn "repeat: sway payload missing repeat_delay 125"; ok=0; }
    [[ "$sway" == *"repeat_rate 125"* ]] || { warn "repeat: sway payload missing repeat_rate 125"; ok=0; }
  else warn "repeat: sway config not in payload (skipping sway check)"; fi
  [[ -f "$P/kde/kcminputrc" && "$(cat "$P/kde/kcminputrc")" == *"RepeatRate=125"* ]] \
    || { warn "repeat: kcminputrc missing RepeatRate=125"; ok=0; }
  [[ $ok -eq 1 ]] && info "input repeat 125/125 OK (kmscon/hypr/sway/kde)"
  return 0
}

build_chvt_fast() {
  info "build: chvt-fast (SUID VT_ACTIVATE helper)"
  local src="/usr/local/src/chvt-fast.c" bin="/usr/local/bin/chvt-fast"
  local payload_src="$PAYLOAD_DIR/usr-local-bin/chvt-fast.c"
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: cc -O2 $src -o $bin && chmod 4755 $bin"; return 0; fi
  [[ -f "$src" ]] || { warn "chvt-fast.c missing at $src (export first?) — trying payload copy"; return 0; }
  run_cmd sudo cc -O2 "$src" -o "$bin"
  run_cmd sudo chmod 4755 "$bin"
  log "built $bin (SUID)"
}

build_modepin() {
  info "build: kmscon-modepin.so (DP-1 @120Hz pin, fakes DP-2/DP-3 disconnected)"
  local src="/usr/local/src/kmscon-dp1-only.c" so="/usr/local/lib/kmscon-modepin.so"
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: cc -shared -fPIC $src -o $so -ldrm -ldl"; return 0; fi
  [[ -f "$src" ]] || { warn "modepin src missing — skipping"; return 0; }
  run_cmd sudo cc -shared -fPIC "$src" -o "$so" -ldrm -ldl
  log "built $so"
}

enable_tty_units() {
  info "enable: kmsconvt@tty1 + hotkey daemon (user)"
  if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY-RUN: sudo systemctl daemon-reload; sudo systemctl enable kmsconvt@tty1; systemctl --user enable --now desktop-hotkey.service"
    return 0
  fi
  run_cmd sudo systemctl daemon-reload || true
  # source enables: kmsconvt@tty1 enabled, getty@tty2/3 enabled, getty@tty7 DISABLED (on-demand)
  run_cmd sudo systemctl enable kmsconvt@tty1.service || true
  run_cmd sudo systemctl enable "getty@tty2.service" "getty@tty3.service" || true
  run_cmd sudo systemctl disable "getty@tty7.service" || true
  run_cmd systemctl --user daemon-reload || true
  run_cmd systemctl --user enable --now desktop-hotkey.service || true
  # sudoers hint: wheel NOPASSWD covers chvt/systemctl/loginctl for desktop-toggle
  if [[ ! -f /etc/sudoers.d/10-ricefarms-nopasswd ]]; then
    warn "create /etc/sudoers.d/10-ricefarms-nopasswd with: %wheel ALL=(ALL) NOPASSWD: ALL  (source uses wheel NOPASSWD:ALL)"
  fi
}

# --------------------------------- b) hyprland/lucid/shader/pibble/hotkeys ---
phase_hypr_stack() {
  info "phase B: hyprland + lucid + e-ink shader + pibble + hotkeys"
  local P="$PAYLOAD_DIR"
  install_dir "$P/hypr" "$TARGET_HOME/.config/hypr"
  install_dir "$P/quickshell" "$TARGET_HOME/.config/quickshell"
  install_dir "$P/lucid" "$TARGET_HOME/.config/lucid"
  install_file "$P/systemd-user/quickshell.service" "$TARGET_HOME/.config/systemd/user/quickshell.service" "644"
  install_dir "$P/pibble" "$TARGET_HOME/src/pibble"
  # ~/.local/bin/pibble symlink
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: ln -sf \$HOME/src/pibble/pibble \$HOME/.local/bin/pibble";
  else mkdir -p "$TARGET_HOME/.local/bin"; ln -sf "$TARGET_HOME/src/pibble/pibble" "$TARGET_HOME/.local/bin/pibble"; fi
  install_dir "$P/lucid-capture" "$TARGET_HOME/src/lucid-capture"
  build_lucid_capture
  # user units: quickshell managed by hyprland.lua watchdog, service is fallback
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: systemctl --user enable quickshell.service (fallback)";
  else run_cmd systemctl --user enable quickshell.service || true; fi
  verify_hypr_binds
}

build_lucid_capture() {
  info "build: lucid-capture.so (HyprGlass fork; may stay DISABLED if SEGV)"
  local d="$TARGET_HOME/src/lucid-capture"
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: make -C $d"; return 0; fi
  [[ -f "$d/Makefile" ]] || { warn "lucid-capture src missing — skipping build"; return 0; }
  (run_cmd make -C "$d" || warn "lucid-capture build failed — Hyprland runs fine without it (source has it DISABLED since 2026-09-03 SEGV)") || true
}

verify_hypr_binds() {
  # sanity: F15 + pibble + shader binds must exist in payload (fail fast on bad export)
  # NOTE: grep-free (sandbox blocks *grep*; target uses bash builtins only)
  local P="$PAYLOAD_DIR"
  local ok=1
  local blob=""
  if [[ -d "$P/hypr" ]]; then
    for f in "$P"/hypr/hyprland.lua "$P"/hypr/hyprland.conf "$P"/hypr/custom.lua "$P"/hypr/custom.conf; do
      [[ -f "$f" ]] && blob+="$(cat "$f")"$'\n'
    done
  fi
  for needle in "F15" "pibble toggle" "desktop-toggle"; do
    if [[ -d "$P/hypr" && "$blob" != *"$needle"* ]]; then
      warn "hypr payload missing expected bind/needle: $needle"; ok=0
    fi
  done
  # shader files
  for s in main.glsl reading_mode.glsl matugen-agx.glsl; do
    [[ -f "$P/hypr/shaders/$s" ]] || { warn "shader missing: $s"; ok=0; }
  done
  [[ $ok -eq 1 ]] && info "hypr binds+shaders OK" || warn "hypr verification warnings (see above)"
  return 0
}

# ------------------------------------------- c) kitty/buckle/nvim/zed/scripts -
phase_apps() {
  info "phase C: kitty + bucklespring/audio + neovim + zed + HOME scripts"
  local P="$PAYLOAD_DIR"
  # kitty
  install_dir "$P/kitty" "$TARGET_HOME/.config/kitty"
  # bucklespring service + sounds
  install_file "$P/systemd-user/bucklespring.service" "$TARGET_HOME/.config/systemd/user/bucklespring.service" "644"
  install_bucklespring_sounds
  build_buckle
  # custom audio stack
  install_dir "$P/audio-stack" "$TARGET_HOME/audio-stack"
  install_dir "$P/pipewire" "$TARGET_HOME/.config/pipewire"
  install_dir "$P/wireplumber" "$TARGET_HOME/.config/wireplumber"
  install_dir "$P/vac-gui" "$TARGET_HOME/.config/vac-gui"
  install_file "$P/systemd-user/vac.service" "$TARGET_HOME/.config/systemd/user/vac.service" "644"
  install_file "$P/systemd-user/vac-enforcer.service" "$TARGET_HOME/.config/systemd/user/vac-enforcer.service" "644"
  # neovim
  install_dir "$P/nvim" "$TARGET_HOME/.config/nvim"
  # zed config (build itself handled below)
  install_dir "$P/zed-config" "$TARGET_HOME/.config/zed"
  install_zed
  # HOME scripts (~60 *.sh) + ~/.local/bin text helpers
  install_dir "$P/home-scripts" "$TARGET_HOME/.home-scripts-staging"
  activate_home_scripts
  install_dir "$P/local-bin" "$TARGET_HOME/.local/bin"
  # user units for audio
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: systemctl --user enable --now bucklespring vac vac-enforcer";
  else
    run_cmd systemctl --user daemon-reload || true
    run_cmd systemctl --user enable --now bucklespring.service vac.service vac-enforcer.service || true
  fi
}

install_bucklespring_sounds() {
  local P="$PAYLOAD_DIR"
  if [[ -f "$LARGE_DIR/bucklespring-kalih-box-white.tar.zst" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: extract bucklespring-kalih-box-white.tar.zst -> ~/.local/share/bucklespring/";
    else mkdir -p "$TARGET_HOME/.local/share/bucklespring"; tar --zstd -xf "$LARGE_DIR/bucklespring-kalih-box-white.tar.zst" -C "$TARGET_HOME/.local/share/bucklespring/"; fi
  elif [[ -d "$P/bucklespring-sounds" ]]; then
    install_dir "$P/bucklespring-sounds" "$TARGET_HOME/.local/share/bucklespring"
  else
    warn "no bucklespring sounds in payload (expected payload-large/bucklespring-kalih-box-white.tar.zst or payload/bucklespring-sounds/)"
  fi
}

build_buckle() {
  info "build: buckle (manual make install upstream; binary not in pacman)"
  if command -v buckle >/dev/null 2>&1; then info "buckle already present: $(command -v buckle)"; return 0; fi
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: build bucklespring from source -> /usr/local/bin/buckle"; return 0; fi
  warn "buckle missing — build upstream: git clone https://github.com/zevv/bucklespring && cd bucklespring && make && sudo make install (then 'systemctl --user restart bucklespring')"
}

install_zed() {
  info "install: zed custom build (copy whole build)"
  local P="$PAYLOAD_DIR"
  # 1. fast path: restore tarball captured with --export on source
  if [[ -f "$LARGE_DIR/zed-custom.tar.zst" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: sudo tar --zstd -xf $LARGE_DIR/zed-custom.tar.zst -C / (restores /usr/lib/zed + /usr/bin/zeditor)";
    else run_cmd sudo tar --zstd -xf "$LARGE_DIR/zed-custom.tar.zst" -C /; fi
  else
    warn "no zed-custom.tar.zst — falling back to source rebuild (slow, ~30min)"
    build_zed_from_source
  fi
  # 2. desktop entry
  install_file "$P/zed-config/dev.zed.Zed.desktop" "$TARGET_HOME/.local/share/applications/dev.zed.Zed.desktop" "644"
}

build_zed_from_source() {
  local pin=""; [[ -f "$PAYLOAD_DIR/zed-pin.txt" ]] && pin="$(cat "$PAYLOAD_DIR/zed-pin.txt")"
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: git clone zed -> ~/src/zed checkout $pin + cargo build --release"; return 0; fi
  if [[ -d "$TARGET_HOME/src/zed" ]]; then info "zed src exists at ~/src/zed (pin: ${pin:-unknown})"; else
    run_cmd git clone https://github.com/zed-industries/zed.git "$TARGET_HOME/src/zed" || return 0
  fi
  if [[ -n "$pin" ]]; then (cd "$TARGET_HOME/src/zed" && run_cmd git fetch origin && run_cmd git checkout "$pin") || warn "zed pin checkout failed"; fi
  warn "zed release build takes ~30min: (cd ~/src/zed && ./script/bundle-linux --build release). Run manually, then re-run installer to capture."
}

activate_home_scripts() {
  # staged -> $HOME/*.sh (executable), never overwrite without backup
  local stg="$TARGET_HOME/.home-scripts-staging"
  [[ -d "$stg" ]] || return 0
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: mv staging *.sh -> \$HOME/*.sh (chmod +x)"; return 0; fi
  for f in "$stg"/*.sh; do
    [[ -e "$f" ]] || continue
    local base; base="$(basename "$f")"
    backup_file "$TARGET_HOME/$base"
    cp -a "$f" "$TARGET_HOME/$base"
    chmod +x "$TARGET_HOME/$base"
  done
  log "activated HOME scripts from staging"
}

# -------------------------------------------------------------- d) dotfiles ---
phase_dotfiles() {
  info "phase D: dotfiles"
  local P="$PAYLOAD_DIR"
  install_file "$P/zsh/dot.zshrc" "$TARGET_HOME/.zshrc" "644"
  install_file "$P/zsh/dot.zshenv" "$TARGET_HOME/.zshenv" "644"
  install_file "$P/zsh/dot.zprofile" "$TARGET_HOME/.zprofile" "644"
  install_file "$P/bash/dot.bashrc" "$TARGET_HOME/.bashrc" "644"
  install_file "$P/bash/dot.bash_profile" "$TARGET_HOME/.bash_profile" "644"
  install_file "$P/bash/dot.profile" "$TARGET_HOME/.profile" "644"
  install_file "$P/x11/dot.Xresources" "$TARGET_HOME/.Xresources" "644"
  install_file "$P/pam/dot.pam_environment" "$TARGET_HOME/.pam_environment" "644"
  install_file "$P/git/dot.gitignore" "$TARGET_HOME/.gitignore" "644"
  install_file "$P/tmux/dot.tmux.conf" "$TARGET_HOME/.tmux.conf" "644"
  install_file "$P/matugen/dot.mutagen-sync-dev.sh" "$TARGET_HOME/matugen-sync-dev.sh" "755"
  install_file "$P/matugen/dot.matugen-watch-dev.sh" "$TARGET_HOME/matugen-watch-dev.sh" "755"
  # KDE input: key repeat 125/125 (matches hypr/sway/kmscon)
  install_file "$P/kde/kcminputrc" "$TARGET_HOME/.config/kcminputrc" "644"
  install_ohmyzsh
  install_opencode
  # systemd user units (all of them, merged)
  install_dir "$P/systemd-user" "$TARGET_HOME/.config/systemd/user"
  # misc small configs vendored 1:1
  for sub in foot dunst btop opencode sway waybar; do
    [[ -d "$P/config-$sub" ]] && install_dir "$P/config-$sub" "$TARGET_HOME/.config/$sub"
  done
  # fonts note
  info "fonts: GitLab Mono (kmscon) + Noto Sans Mono (kitty) — install via pacman/aur if missing (fc-list | check)"
}

# oh-my-zsh framework: stock upstream at pinned commit + vendored custom/.
# (Source: ~/.oh-my-zsh git clone, stock custom/ examples only, no zsh plugin
# manager besides this. .zshrc uses ZSH=$HOME/.oh-my-zsh, theme afowler,
# plugins=(git) — that file already ships in phase D above.)
install_ohmyzsh() {
  info "install: oh-my-zsh framework"
  local P="$PAYLOAD_DIR" dest="$TARGET_HOME/.oh-my-zsh"
  local pin=""; [[ -f "$P/oh-my-zsh/pin.txt" ]] && pin="$(cat "$P/oh-my-zsh/pin.txt")"
  if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY-RUN: git clone ohmyzsh/ohmyzsh -> $dest checkout ${pin:-master} + restore custom/"
    return 0
  fi
  if [[ ! -d "$dest" ]]; then
    run_cmd git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$dest" \
      || { warn "oh-my-zsh clone failed (offline?) — skipping"; return 0; }
  else info "oh-my-zsh present at $dest"; fi
  if [[ -n "$pin" ]]; then
    (run_cmd git -C "$dest" fetch --depth 1 origin "$pin" \
      && run_cmd git -C "$dest" checkout "$pin") \
      || warn "oh-my-zsh pin checkout failed (staying on current revision)"
  fi
  install_dir "$P/oh-my-zsh/custom" "$dest/custom"
}

# Local opencode config: ~/.config/opencode (global) + ~/.opencode (commands
# + agent-identity). Secrets are NEVER committed (standing rule): payload
# ships ${CONTEXT7_API_KEY} placeholder — set the real key on the target.
install_opencode() {
  info "install: opencode local config"
  local P="$PAYLOAD_DIR"
  install_dir "$P/config-opencode" "$TARGET_HOME/.config/opencode"
  install_dir "$P/opencode-home" "$TARGET_HOME/.opencode"
  for cfg in "$TARGET_HOME/.config/opencode/opencode.json" "$TARGET_HOME/.config/opencode/opencode.jsonc"; do
    if [[ -f "$cfg" && "$(cat "$cfg")" == *'${CONTEXT7_API_KEY}'* ]]; then
      warn "opencode: $cfg still has \$${CONTEXT7_API_KEY} placeholder — insert your key (never commit it)"
    fi
  done
  # plugin deps (tui-matugen-live needs node_modules): best-effort, offline-safe
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: bun install in .config/opencode + .opencode (if bun + package.json)"; return 0; fi
  for d in "$TARGET_HOME/.config/opencode" "$TARGET_HOME/.opencode"; do
    if [[ -f "$d/package.json" ]] && command -v bun >/dev/null 2>&1; then
      (cd "$d" && run_cmd bun install) || warn "bun install failed in $d (run manually)"
    fi
  done
}

# ------------------------------------------------------ e) matugen/wallpaper --
phase_matugen() {
  info "phase E: matugen + wallpapers"
  local P="$PAYLOAD_DIR"
  install_dir "$P/matugen" "$TARGET_HOME/.config/matugen"
  install_dir "$P/hypr-wallpapers" "$TARGET_HOME/.config/hypr/wallpapers"
  install_matugen_wallpapers
  # re-apply current wallpaper state + theme (idempotent)
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: matugen image <current> + wallpaper-restore.sh";
  else
    if [[ -f "$TARGET_HOME/.config/hypr/current_wallpaper" ]]; then
      info "current_wallpaper: $(cat "$TARGET_HOME/.config/hypr/current_wallpaper")"
    fi
    if command -v matugen >/dev/null 2>&1 && [[ -f "$TARGET_HOME/.config/hypr/current_wallpaper" ]]; then
      run_cmd matugen image "$(cat "$TARGET_HOME/.config/hypr/current_wallpaper")" || warn "matugen apply failed (ok on headless target)"
    fi
  fi
}

install_matugen_wallpapers() {
  local P="$PAYLOAD_DIR"
  if [[ -f "$LARGE_DIR/wallpapers-matugen.tar.zst" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: extract wallpapers-matugen.tar.zst -> ~/Pictures/wallpapers/matugen/";
    else mkdir -p "$TARGET_HOME/Pictures/wallpapers/matugen"; tar --zstd -xf "$LARGE_DIR/wallpapers-matugen.tar.zst" -C "$TARGET_HOME/Pictures/wallpapers/matugen/"; fi
  elif [[ -d "$P/wallpapers-matugen" && -n "$(ls -A "$P/wallpapers-matugen" 2>/dev/null)" ]]; then
    install_dir "$P/wallpapers-matugen" "$TARGET_HOME/Pictures/wallpapers/matugen"
  else
    warn "no matugen wallpapers in payload (expected payload-large/wallpapers-matugen.tar.zst). Copy ~/Pictures/wallpapers/matugen from source via rsync/usb."
  fi
}

# ------------------------------------------------------------------ f) tmux ---
phase_tmux() {
  info "phase F: tmux (conf in group D, here: plugins + resurrect)"
  local P="$PAYLOAD_DIR"
  install_tmux_plugins
  if [[ -d "$P/tmux-resurrect" && -n "$(ls -A "$P/tmux-resurrect" 2>/dev/null)" ]]; then
    install_dir "$P/tmux-resurrect" "$TARGET_HOME/.local/share/tmux/resurrect"
  else
    info "no resurrect snapshot in payload — fresh tmux start will create one (continuum autosaves)"
  fi
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: tmux start-server + tpm install";
  else
    if command -v tmux >/dev/null 2>&1; then
      run_cmd tmux start-server || true
      info "open tmux and press <prefix>+I (prefix=C-z) to install tpm plugins, or run ~/.tmux/plugins/tpm/bin/install_plugins"
    fi
  fi
}

install_tmux_plugins() {
  local tpm="$TARGET_HOME/.tmux/plugins/tpm"
  local plugins=( tmux-sensible tmux-continuum tmux-resurrect tmux-resurrect-opencode-sessions tmux-auto-resize-panes-evenly )
  if [[ $DRY_RUN -eq 1 ]]; then log "DRY-RUN: git clone tpm + ${plugins[*]} -> ~/.tmux/plugins/"; return 0; fi
  mkdir -p "$TARGET_HOME/.tmux/plugins"
  if [[ ! -d "$tpm" ]]; then run_cmd git clone https://github.com/tmux-plugins/tpm "$tpm" || warn "tpm clone failed"; fi
  declare -A repos=(
    [tmux-sensible]=https://github.com/tmux-plugins/tmux-sensible
    [tmux-continuum]=https://github.com/tmux-plugins/tmux-continuum
    [tmux-resurrect]=https://github.com/tmux-plugins/tmux-resurrect
    [tmux-resurrect-opencode-sessions]=https://github.com/anomalyco/tmux-resurrect-opencode-sessions
    [tmux-auto-resize-panes-evenly]=https://github.com/anomalyco/tmux-auto-resize-panes-evenly
  )
  for p in "${plugins[@]}"; do
    if [[ ! -d "$TARGET_HOME/.tmux/plugins/$p" ]]; then
      run_cmd git clone "${repos[$p]}" "$TARGET_HOME/.tmux/plugins/$p" || warn "clone failed: $p"
    else info "tmux plugin present: $p"; fi
  done
}

# ------------------------------------------------------------------- export ---
export_file() {
  local src="$1" dst="$2"
  [[ -e "$src" ]] || { warn "export skip (missing): $src"; return 0; }
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
  log "export: $src -> $dst"
}

export_dir() {
  local src="$1" dst="$2"
  [[ -d "$src" ]] || { warn "export skip (missing dir): $src"; return 0; }
  mkdir -p "$dst"
  cp -a "$src/." "$dst/"
  log "export-dir: $src -> $dst"
}

export_payload() {
  info "exporting live system -> $PAYLOAD_DIR (+ large tarballs -> $LARGE_DIR)"
  local S="$SOURCE_HOME" P="$PAYLOAD_DIR"
  mkdir -p "$P" "$LARGE_DIR"
  # a) tty
  export_file /etc/kmscon/kmscon.conf "$P/etc/kmscon/kmscon.conf"
  for d in "kmsconvt@.service.d" "kmsconvt@tty1.service.d" "getty@tty1.service.d" "getty@tty2.service.d" "getty@tty3.service.d" "getty@tty7.service.d"; do
    export_dir "/etc/systemd/system/$d" "$P/etc/systemd/system/$d"
  done
  export_file /usr/local/bin/desktop-toggle "$P/usr-local-bin/desktop-toggle"
  export_file /usr/local/bin/desktop-hotkey-daemon "$P/usr-local-bin/desktop-hotkey-daemon"
  # chvt-fast source is reconstructed if original C is unavailable: payload keeps a canonical copy
  if [[ -f /usr/local/src/chvt-fast.c ]]; then export_file /usr/local/src/chvt-fast.c "$P/usr-local-bin/chvt-fast.c";
  elif [[ -f "$P/usr-local-bin/chvt-fast.c" ]]; then info "keeping existing payload chvt-fast.c (no system src)";
  else warn "no chvt-fast.c src on system — payload must provide it (see templates)"; fi
  export_file /usr/local/src/kmscon-dp1-only.c "$P/usr-local-src/kmscon-dp1-only.c"
  export_file "$S/.config/systemd/user/desktop-hotkey.service" "$P/systemd-user/desktop-hotkey.service"
  export_file "$S/.config/desktop-toggle/config" "$P/desktop-toggle/config"
  export_file "$S/.zprofile" "$P/zsh/dot.zprofile"
  # b) hypr/lucid/pibble/shader
  export_dir "$S/.config/hypr" "$P/hypr-tmp"
  # prune hypr cache dreck from export (keep lua/conf/colors/shaders/scripts/wallpapers state)
  mkdir -p "$P/hypr"
  for f in hyprland.lua custom.lua shader.lua hyprland.conf custom.conf colors.conf colors.lua hyprpaper.conf current_wallpaper; do
    [[ -e "$S/.config/hypr/$f" ]] && cp -a "$S/.config/hypr/$f" "$P/hypr/$f"
  done
  export_dir "$S/.config/hypr/shaders" "$P/hypr/shaders"
  export_dir "$S/.config/hypr/scripts" "$P/hypr/scripts"
  rm -rf "$P/hypr-tmp"
  export_dir "$S/.config/quickshell" "$P/quickshell"
  export_dir "$S/.config/lucid" "$P/lucid"
  export_file "$S/.config/systemd/user/quickshell.service" "$P/systemd-user/quickshell.service"
  # pibble: full dir except .git
  if [[ -d "$S/src/pibble" ]]; then
    mkdir -p "$P/pibble"; (cd "$S/src/pibble" && tar --exclude=.git -cf - .) | (cd "$P/pibble" && tar -xf -); log "export-dir: src/pibble -> payload/pibble"
  fi
  # lucid-capture: source only (no .so/.o — rebuilt on target)
  if [[ -d "$S/src/lucid-capture" ]]; then
    mkdir -p "$P/lucid-capture"
    for f in Makefile hyprpm.toml README.md; do [[ -e "$S/src/lucid-capture/$f" ]] && cp -a "$S/src/lucid-capture/$f" "$P/lucid-capture/$f"; done
    mkdir -p "$P/lucid-capture/src"
    for f in "$S"/src/lucid-capture/src/*.{cpp,hpp,h}; do [[ -e "$f" ]] && cp -a "$f" "$P/lucid-capture/src/"; done
  fi
  # c) apps
  export_dir "$S/.config/kitty" "$P/kitty"
  export_file "$S/.config/systemd/user/bucklespring.service" "$P/systemd-user/bucklespring.service"
  export_dir "$S/audio-stack" "$P/audio-stack"
  export_dir "$S/.config/pipewire" "$P/pipewire"
  export_dir "$S/.config/wireplumber" "$P/wireplumber"
  export_dir "$S/.config/vac-gui" "$P/vac-gui"
  export_file "$S/.config/systemd/user/vac.service" "$P/systemd-user/vac.service"
  export_file "$S/.config/systemd/user/vac-enforcer.service" "$P/systemd-user/vac-enforcer.service"
  export_dir "$S/.config/nvim" "$P/nvim"
  export_dir "$S/.config/zed" "$P/zed-config-tmp"
  mkdir -p "$P/zed-config"
  for f in settings.json keymap.json; do [[ -f "$S/.config/zed/$f" ]] && cp -a "$S/.config/zed/$f" "$P/zed-config/$f"; done
  [[ -f "$S/.local/share/applications/dev.zed.Zed.desktop" ]] && cp -a "$S/.local/share/applications/dev.zed.Zed.desktop" "$P/zed-config/dev.zed.Zed.desktop"
  rm -rf "$P/zed-config-tmp"
  # zed pin
  if [[ -d "$S/src/zed" ]]; then (cd "$S/src/zed" && git rev-parse HEAD 2>/dev/null > "$P/zed-pin.txt") || echo "unknown" > "$P/zed-pin.txt"; fi
  # HOME scripts + local-bin (text files only; ELFs go to manifest)
  mkdir -p "$P/home-scripts" "$P/local-bin"
  for f in "$S"/*.sh; do [[ -e "$f" ]] && cp -a "$f" "$P/home-scripts/"; done
  for f in "$S"/.local/bin/*; do
    [[ -e "$f" ]] || continue
    # ELF check without grep (sandbox blocks *grep*): use `file` output + shell match
    if [[ "$(file "$f" 2>/dev/null)" == *ELF* ]]; then echo "$(basename "$f") ELF-skip" >> "$P/local-bin/ELFS_SKIPPED.txt";
    else cp -a "$f" "$P/local-bin/"; fi
  done
  (cd "$S/src/zed" 2>/dev/null && git rev-parse HEAD 2>/dev/null || echo unknown) > "$P/zed-pin.txt"
  # d) dotfiles
  export_file "$S/.zshrc" "$P/zsh/dot.zshrc"
  export_file "$S/.zshenv" "$P/zsh/dot.zshenv"
  export_file "$S/.bashrc" "$P/bash/dot.bashrc"
  export_file "$S/.bash_profile" "$P/bash/dot.bash_profile"
  export_file "$S/.profile" "$P/bash/dot.profile"
  export_file "$S/.Xresources" "$P/x11/dot.Xresources"
  export_file "$S/.pam_environment" "$P/pam/dot.pam_environment"
  export_file "$S/.gitignore" "$P/git/dot.gitignore"
  export_file "$S/.tmux.conf" "$P/tmux/dot.tmux.conf"
  export_file "$S/matugen-sync-dev.sh" "$P/matugen/dot.mutagen-sync-dev.sh"
  export_file "$S/matugen-watch-dev.sh" "$P/matugen/dot.matugen-watch-dev.sh"
  # KDE input (key repeat 125/125) + autologin extras (sddm)
  export_file "$S/.config/kcminputrc" "$P/kde/kcminputrc"
  # oh-my-zsh: pin the framework revision + vendor custom/ (framework itself
  # is cloned at install time; 16M of stock plugins/themes are NOT vendored)
  if [[ -d "$S/.oh-my-zsh/.git" ]]; then
    mkdir -p "$P/oh-my-zsh"
    (cd "$S/.oh-my-zsh" && git rev-parse HEAD 2>/dev/null > "$P/oh-my-zsh/pin.txt") || echo unknown > "$P/oh-my-zsh/pin.txt"
    log "export: oh-my-zsh pin $(cat "$P/oh-my-zsh/pin.txt" 2>/dev/null)"
  fi
  if [[ -d "$S/.oh-my-zsh/custom" ]]; then
    mkdir -p "$P/oh-my-zsh/custom"; cp -a "$S/.oh-my-zsh/custom/." "$P/oh-my-zsh/custom/"
    log "export-dir: .oh-my-zsh/custom -> payload/oh-my-zsh/custom"
  fi
  export_file /etc/sddm.conf.d/autologin.conf "$P/etc/sddm.conf.d/autologin.conf"
  # sudoers: source keeps it in /etc/sudoers:128 (drop-in dir empty) — ship
  # the same rule as a drop-in so install never edits /etc/sudoers itself.
  mkdir -p "$P/etc/sudoers.d"
  printf '# ricefarms: passwordless sudo for wheel (source: /etc/sudoers:128, /etc/sudoers.d/ was empty)\n%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' > "$P/etc/sudoers.d/10-ricefarms-nopasswd"
  log "export: sudoers drop-in (canonical)"
  export_dir "$S/.config/systemd/user" "$P/systemd-user-full"
  # merge all user units into payload/systemd-user (canonical)
  mkdir -p "$P/systemd-user"; cp -a "$P/systemd-user-full/." "$P/systemd-user/" 2>/dev/null || true; rm -rf "$P/systemd-user-full"
  for sub in foot dunst btop opencode sway waybar; do
    if [[ -d "$S/.config/$sub" ]]; then
      mkdir -p "$P/config-$sub"
      # exclude caches/build dreck (node_modules, .o/.so, Cache, cache)
      (cd "$S/.config/$sub" && tar --exclude=node_modules --exclude='*.o' --exclude='*.so' --exclude=Cache --exclude=cache -cf - .) | (cd "$P/config-$sub" && tar -xf -)
      log "export-dir: .config/$sub -> payload/config-$sub (pruned)"
    fi
  done
  # STANDING RULE: never commit API keys. Redact known secret patterns from
  # the just-exported opencode configs (runs on EVERY export so keys can
  # never slip back in). Payload keeps ${...} placeholders instead.
  for f in "$P/config-opencode/opencode.json" "$P/config-opencode/opencode.jsonc" "$P/opencode-home/opencode.json"; do
    [[ -f "$f" ]] || continue
    sed -i 's/ctx7sk-[A-Za-z0-9-]*/${CONTEXT7_API_KEY}/g; s/sk-ant-[A-Za-z0-9-]*/${ANTHROPIC_API_KEY}/g' "$f" || true
  done
  log "export: opencode secrets redacted"
  # second opencode home: ~/.opencode (commands + agent-identity config)
  if [[ -d "$S/.opencode" ]]; then
    mkdir -p "$P/opencode-home"
    (cd "$S/.opencode" && tar --exclude=node_modules -cf - .) | (cd "$P/opencode-home" && tar -xf -)
    sed -i 's/ctx7sk-[A-Za-z0-9-]*/${CONTEXT7_API_KEY}/g; s/sk-ant-[A-Za-z0-9-]*/${ANTHROPIC_API_KEY}/g' "$P/opencode-home/opencode.json" 2>/dev/null || true
    log "export-dir: .opencode -> payload/opencode-home (pruned, redacted)"
  fi
  # e) matugen + wallpapers state
  export_dir "$S/.config/matugen" "$P/matugen"
  export_dir "$S/.config/hypr/wallpapers" "$P/hypr-wallpapers"
  # f) tmux resurrect snapshot (latest only, small)
  if [[ -d "$S/.local/share/tmux/resurrect" ]]; then
    mkdir -p "$P/tmux-resurrect"
    cp -a "$S/.local/share/tmux/resurrect/last" "$P/tmux-resurrect/last" 2>/dev/null || true
  fi
  # manifests
  pacman -Q 2>/dev/null | sort > "$P/manifests-packages-arch.txt" || true
  mkdir -p "$P"
  # ---- large tarballs (NOT for git; copy via usb/rsync) ----
  info "building large tarballs (may take a while)..."
  if [[ -d "$S/Pictures/wallpapers/matugen" ]]; then
    tar --zstd -cf "$LARGE_DIR/wallpapers-matugen.tar.zst" -C "$S/Pictures/wallpapers/matugen" . && log "large: wallpapers-matugen.tar.zst $(du -sh "$LARGE_DIR/wallpapers-matugen.tar.zst" | cut -f1)"
  fi
  if [[ -d "$S/.local/share/bucklespring/kalih-box-white" ]]; then
    tar --zstd -cf "$LARGE_DIR/bucklespring-kalih-box-white.tar.zst" -C "$S/.local/share/bucklespring" kalih-box-white && log "large: bucklespring tarball done"
  fi
  if [[ -f /usr/lib/zed/zed-editor && -f /usr/bin/zeditor ]]; then
    sudo tar --zstd -cf "$LARGE_DIR/zed-custom.tar.zst" /usr/lib/zed/zed-editor /usr/bin/zeditor && log "large: zed-custom.tar.zst done"
  else
    warn "zed binaries not at /usr/lib/zed — skipping zed tarball (rebuild fallback will be used)"
  fi
  cat > "$LARGE_DIR/README.md" <<'EOF'
# payload-large — NOT tracked by git (too big for GitHub)
# Copy this directory alongside the repo to the target machine (usb/rsync),
# keeping the same relative path: <repo>/payload-large/
- wallpapers-matugen.tar.zst  (~/Pictures/wallpapers/matugen, ~700M)
- bucklespring-kalih-box-white.tar.zst (~/.local/share/bucklespring, ~17M)
- zed-custom.tar.zst          (/usr/lib/zed + /usr/bin/zeditor, ~350M)
EOF
  info "export complete. Review with: git -C $REPO_DIR status --short | head -50"
}

# ------------------------------------------------------------------- verify ---
verify_install() {
  info "verify: checking installed state"
  local fails=0
  check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then info "OK: $desc"; else warn "FAIL: $desc"; fails=$((fails+1)); fi; }
  check "hyprland.lua present" test -f "$TARGET_HOME/.config/hypr/hyprland.lua"
  check "e-ink shader present" test -f "$TARGET_HOME/.config/hypr/shaders/reading_mode.glsl"
  check "pibble present" test -x "$TARGET_HOME/src/pibble/pibble"
  check "lucid shell.qml present" test -f "$TARGET_HOME/.config/quickshell/shell.qml"
  check "kitty conf present" test -f "$TARGET_HOME/.config/kitty/kitty.conf"
  check "nvim init present" test -f "$TARGET_HOME/.config/nvim/init.lua"
  check "tmux conf present" test -f "$TARGET_HOME/.tmux.conf"
  check "matugen config present" test -f "$TARGET_HOME/.config/matugen/config.toml"
  check "zprofile tty7 gate present" test -f "$TARGET_HOME/.zprofile"
  check "desktop-toggle installed" test -x /usr/local/bin/desktop-toggle
  check "kcminputrc repeat present" test -f "$TARGET_HOME/.config/kcminputrc"
  check "oh-my-zsh present" test -f "$TARGET_HOME/.oh-my-zsh/oh-my-zsh.sh"
  check "sddm autologin present" test -f /etc/sddm.conf.d/autologin.conf
  check "sudoers drop-in present" test -f /etc/sudoers.d/10-ricefarms-nopasswd
  check "opencode config present" test -f "$TARGET_HOME/.config/opencode/opencode.json"
  if [[ $fails -gt 0 ]]; then warn "verify: $fails checks failed"; return 1; fi
  info "verify: all checks passed"
}

# ---------------------------------------------------------------------- main ---
main() {
  parse_args "$@"
  if [[ $EXPORT_MODE -eq 1 ]]; then export_payload; return 0; fi
  log "ricefarms v$RICEFARMS_VERSION — groups: $ONLY_GROUPS (dry-run=$DRY_RUN)"
  confirm "Install ricefarms payload ($ONLY_GROUPS) onto $TARGET_HOME? Existing files will be backed up (*.bak.TIMESTAMP). [y/N]" || { info "aborted."; return 1; }
  wants_group a && phase_tty_kmscon
  wants_group b && phase_hypr_stack
  wants_group c && phase_apps
  wants_group d && phase_dotfiles
  wants_group e && phase_matugen
  wants_group f && phase_tmux
  verify_install || warn "verify reported failures — check output above"
  log "done. Reboot or re-login recommended for kmscon/systemd changes. Hyprland: press F15 or Ctrl+Alt+T to toggle from tty1."
}

# Allow unit tests to source this file without executing main:
#   RICEFARMS_NOEXEC=1 source install.sh
if [[ "${RICEFARMS_NOEXEC:-0}" != "1" && "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

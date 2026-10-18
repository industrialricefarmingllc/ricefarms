#!/usr/bin/env bash
# ricefarms — unit tests for install.sh (no network, mocked system tools)
# Run: bash tests/test_install.sh
# Every function/phase in install.sh has at least one test.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; TESTS=()

# ---------------- minimal assert framework ----------------
assert_eq() { # $1 desc, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "NOT OK - $1 (expected='$2' actual='$3')"; fi
}
assert_true() { # $1 desc, $2... command
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $desc";
  else FAIL=$((FAIL+1)); echo "NOT OK - $desc (command failed: $*)"; fi
}
assert_file_has() { # $1 desc, $2 file, $3 needle (literal, grep-free)
  if [[ -f "$2" ]] && [[ "$(cat "$2")" == *"$3"* ]]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "NOT OK - $1 (missing '$3' in $2)"; fi
}

# ---------------- load installer without executing ----------------
export RICEFARMS_NOEXEC=1
# shellcheck disable=SC1091
source "$REPO_DIR/install.sh"

# ---------------- isolated temp roots ----------------
TMP="$(mktemp -d)"
export TMP # mocks resolve $TMP/calls.log at runtime — must be exported
FAKE_PAYLOAD="$TMP/payload"; FAKE_HOME="$TMP/home"; FAKE_LARGE="$TMP/large"; FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_PAYLOAD" "$FAKE_HOME" "$FAKE_LARGE" "$FAKE_BIN"
export PAYLOAD_DIR="$FAKE_PAYLOAD" TARGET_HOME="$FAKE_HOME" LARGE_DIR="$FAKE_LARGE"
export PATH="$FAKE_BIN:$PATH"

# mock system tools: log invocations, succeed
for tool in sudo systemctl cc git pacman paru matugen tmux pkill hyprctl loginctl awww visudo bun make; do
  printf '#!/usr/bin/env bash\necho "$0 $*" >> "$TMP/calls.log"\nexit 0\n' > "$FAKE_BIN/$tool"
  chmod +x "$FAKE_BIN/$tool"
done

reset_calls() { rm -f "$TMP/calls.log"; touch "$TMP/calls.log"; }
calls_contain() { [[ -f "$TMP/calls.log" ]] && [[ "$(cat "$TMP/calls.log")" == *"$1"* ]]; }

echo "== 1. logging/utils =="
assert_true "log function exists" declare -F log
assert_true "info exists" declare -F info
assert_true "warn exists" declare -F warn
assert_true "die exists" declare -F die
# die returns 1
if die "boom" 2>/dev/null; then FAIL=$((FAIL+1)); echo "NOT OK - die returns nonzero";
else PASS=$((PASS+1)); echo "ok - die returns nonzero"; fi

echo "== 2. parse_args =="
ONLY_GROUPS="a,b,c,d,e,f"; DRY_RUN=0; ASSUME_YES=0; EXPORT_MODE=0
parse_args --yes --dry-run --only a,b
assert_eq "parse --yes" "1" "$ASSUME_YES"
assert_eq "parse --dry-run" "1" "$DRY_RUN"
assert_eq "parse --only" "a,b" "$ONLY_GROUPS"
DRY_RUN=0; ASSUME_YES=0; ONLY_GROUPS="a,b,c,d,e,f"; EXPORT_MODE=0
parse_args --only=a
assert_eq "parse --only= form" "a" "$ONLY_GROUPS"
ONLY_GROUPS="a,b,c,d,e,f"

echo "== 3. wants_group =="
ONLY_GROUPS="a,c"
if wants_group a; then PASS=$((PASS+1)); echo "ok - wants a in a,c"; else FAIL=$((FAIL+1)); echo "NOT OK - wants a"; fi
if wants_group b; then FAIL=$((FAIL+1)); echo "NOT OK - b should be excluded"; else PASS=$((PASS+1)); echo "ok - b excluded"; fi
ONLY_GROUPS="a,b,c,d,e,f"

echo "== 4. confirm =="
ASSUME_YES=1; assert_true "confirm auto-yes" confirm "q?"
ASSUME_YES=0
if printf 'y\n' | confirm "q?"; then PASS=$((PASS+1)); echo "ok - confirm y"; else FAIL=$((FAIL+1)); echo "NOT OK - confirm y"; fi
if printf 'n\n' | confirm "q?"; then FAIL=$((FAIL+1)); echo "NOT OK - confirm n should fail"; else PASS=$((PASS+1)); echo "ok - confirm n rejects"; fi

echo "== 5. run_cmd =="
DRY_RUN=1
out="$(run_cmd echo hello)"; assert_true "run_cmd dry-run prints DRY-RUN" test "$out" != ""
DRY_RUN=0
assert_eq "run_cmd real executes" "hello" "$(run_cmd echo hello)"

echo "== 6. backup/install file/dir =="
DRY_RUN=0
echo "orig" > "$FAKE_HOME/f.txt"
backup_file "$FAKE_HOME/f.txt"
if ls "$FAKE_HOME"/f.txt.bak.* >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - backup_file creates .bak"; else FAIL=$((FAIL+1)); echo "NOT OK - backup_file"; fi
mkdir -p "$FAKE_PAYLOAD/x"; echo "new" > "$FAKE_PAYLOAD/x/src.txt"
install_file "$FAKE_PAYLOAD/x/src.txt" "$FAKE_HOME/dst.txt"
assert_eq "install_file copies" "new" "$(cat "$FAKE_HOME/dst.txt")"
install_file "$FAKE_PAYLOAD/x/missing.txt" "$FAKE_HOME/nope.txt"  # should warn, not fail
PASS=$((PASS+1)); echo "ok - install_file missing warns (no crash)"
mkdir -p "$FAKE_PAYLOAD/mydir"; echo "a" > "$FAKE_PAYLOAD/mydir/a.txt"
install_dir "$FAKE_PAYLOAD/mydir" "$FAKE_HOME/mydir"
assert_eq "install_dir copies" "a" "$(cat "$FAKE_HOME/mydir/a.txt")"
DRY_RUN=1
install_file "$FAKE_PAYLOAD/x/src.txt" "$FAKE_HOME/should-not-exist.txt"
if [[ ! -f "$FAKE_HOME/should-not-exist.txt" ]]; then PASS=$((PASS+1)); echo "ok - dry-run does not write"; else FAIL=$((FAIL+1)); echo "NOT OK - dry-run wrote"; fi
DRY_RUN=0

echo "== 7. detect/phase packages =="
assert_true "detect_pacman exists" declare -F detect_pacman
pm="$(detect_pacman)"; assert_true "detect_pacman returns non-empty" test -n "$pm"
DRY_RUN=1; assert_true "phase_packages dry-run" phase_packages; DRY_RUN=0

echo "== 8. phase A: tty/kmscon =="
assert_true "phase_tty_kmscon exists" declare -F phase_tty_kmscon
assert_true "build_chvt_fast exists" declare -F build_chvt_fast
assert_true "build_modepin exists" declare -F build_modepin
assert_true "enable_tty_units exists" declare -F enable_tty_units
# minimal fake payload for A
mkdir -p "$FAKE_PAYLOAD/etc/kmscon" "$FAKE_PAYLOAD/etc/systemd/system/kmsconvt@.service.d" \
  "$FAKE_PAYLOAD/etc/systemd/system/kmsconvt@tty1.service.d" "$FAKE_PAYLOAD/etc/systemd/system/getty@tty1.service.d" \
  "$FAKE_PAYLOAD/etc/systemd/system/getty@tty2.service.d" "$FAKE_PAYLOAD/etc/systemd/system/getty@tty3.service.d" \
  "$FAKE_PAYLOAD/etc/systemd/system/getty@tty7.service.d" "$FAKE_PAYLOAD/usr-local-bin" \
  "$FAKE_PAYLOAD/usr-local-src" "$FAKE_PAYLOAD/systemd-user" "$FAKE_PAYLOAD/desktop-toggle" "$FAKE_PAYLOAD/zsh"
echo "font-size=20" > "$FAKE_PAYLOAD/etc/kmscon/kmscon.conf"
echo "toggle" > "$FAKE_PAYLOAD/usr-local-bin/desktop-toggle"
echo "daemon" > "$FAKE_PAYLOAD/usr-local-bin/desktop-hotkey-daemon"
echo "c-src" > "$FAKE_PAYLOAD/usr-local-bin/chvt-fast.c"
echo "modepin-src" > "$FAKE_PAYLOAD/usr-local-src/kmscon-dp1-only.c"
echo "[Unit]" > "$FAKE_PAYLOAD/systemd-user/desktop-hotkey.service"
echo "DESK_VT=7" > "$FAKE_PAYLOAD/desktop-toggle/config"
echo "tty7 gate" > "$FAKE_PAYLOAD/zsh/dot.zprofile"
DRY_RUN=1; reset_calls
assert_true "phase_tty dry-run" phase_tty_kmscon
DRY_RUN=0
# chvt-fast.c canonical content check on REAL payload
assert_file_has "chvt-fast.c has VT_ACTIVATE" "$REPO_DIR/payload/usr-local-bin/chvt-fast.c" "VT_ACTIVATE"
assert_file_has "chvt-fast.c has 15s timeout" "$REPO_DIR/payload/usr-local-bin/chvt-fast.c" "alarm(15)"
assert_file_has "kmscon.conf has font-size" "$REPO_DIR/payload/etc/kmscon/kmscon.conf" "font-size"
assert_file_has "tty1 autologin uses kmscon" "$REPO_DIR/payload/etc/systemd/system/kmsconvt@tty1.service.d/autologin.conf" "kmscon"
assert_file_has "desktop-toggle config has DESK_VT" "$REPO_DIR/payload/desktop-toggle/config" "DESK_VT=7"
assert_file_has "zprofile gates tty7" "$REPO_DIR/payload/zsh/dot.zprofile" "/dev/tty7"

echo "== 8b. autologin extras + key repeat =="
assert_true "phase_autologin_extras exists" declare -F phase_autologin_extras
assert_true "verify_input_repeat exists" declare -F verify_input_repeat
# fixtures for new functions (repeat sources must carry real 125 values)
mkdir -p "$FAKE_PAYLOAD/etc/sddm.conf.d" "$FAKE_PAYLOAD/etc/sudoers.d" "$FAKE_PAYLOAD/kde" "$FAKE_PAYLOAD/config-sway" "$FAKE_PAYLOAD/hypr"
printf '[Autologin]\nUser=testuser\n' > "$FAKE_PAYLOAD/etc/sddm.conf.d/autologin.conf"
printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' > "$FAKE_PAYLOAD/etc/sudoers.d/10-ricefarms-nopasswd"
printf '[Keyboard]\nRepeatDelay=125\nRepeatRate=125\n' > "$FAKE_PAYLOAD/kde/kcminputrc"
printf 'repeat_delay 125\nrepeat_rate 125\n' > "$FAKE_PAYLOAD/config-sway/config"
printf 'xkb-repeat-delay=125\n' >> "$FAKE_PAYLOAD/etc/kmscon/kmscon.conf"
printf 'repeat_delay = 125\nrepeat_rate = 125\n' >> "$FAKE_PAYLOAD/hypr/hyprland.lua"
DRY_RUN=1; reset_calls
assert_true "phase_autologin_extras dry-run" phase_autologin_extras
assert_true "verify_input_repeat passes on fixture" verify_input_repeat
DRY_RUN=0
# warn-only contract: incomplete payload must NOT fail the installer
mkdir -p "$TMP/empty-payload"
if PAYLOAD_DIR="$TMP/empty-payload" verify_input_repeat 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - verify_input_repeat warn-only on empty payload"
else FAIL=$((FAIL+1)); echo "NOT OK - verify_input_repeat warn-only on empty payload"; fi
# real payload 1:1 fidelity
assert_file_has "sddm autologin user nicerice" "$REPO_DIR/payload/etc/sddm.conf.d/autologin.conf" "User=nicerice"
assert_file_has "sudoers drop-in NOPASSWD" "$REPO_DIR/payload/etc/sudoers.d/10-ricefarms-nopasswd" "%wheel ALL=(ALL:ALL) NOPASSWD: ALL"
assert_file_has "kcminputrc RepeatDelay 125" "$REPO_DIR/payload/kde/kcminputrc" "RepeatDelay=125"
assert_file_has "kcminputrc RepeatRate 125" "$REPO_DIR/payload/kde/kcminputrc" "RepeatRate=125"
assert_file_has "kmscon repeat-delay 125" "$REPO_DIR/payload/etc/kmscon/kmscon.conf" "xkb-repeat-delay=125"
assert_file_has "hypr repeat_delay 125" "$REPO_DIR/payload/hypr/hyprland.lua" "repeat_delay = 125"
assert_file_has "hypr repeat_rate 125" "$REPO_DIR/payload/hypr/hyprland.lua" "repeat_rate = 125"
assert_file_has "sway repeat_delay 125" "$REPO_DIR/payload/config-sway/config" "repeat_delay 125"
assert_file_has "sway repeat_rate 125" "$REPO_DIR/payload/config-sway/config" "repeat_rate 125"
assert_file_has "getty tty2 autologin" "$REPO_DIR/payload/etc/systemd/system/getty@tty2.service.d/autologin.conf" "--autologin nicerice"

echo "== 9. phase B: hypr/lucid/shader/pibble =="
assert_true "phase_hypr_stack exists" declare -F phase_hypr_stack
assert_true "build_lucid_capture exists" declare -F build_lucid_capture
assert_true "verify_hypr_binds exists" declare -F verify_hypr_binds
mkdir -p "$FAKE_PAYLOAD/hypr/shaders" "$FAKE_PAYLOAD/hypr/scripts" "$FAKE_PAYLOAD/quickshell" \
  "$FAKE_PAYLOAD/lucid" "$FAKE_PAYLOAD/pibble" "$FAKE_PAYLOAD/lucid-capture"
printf 'bind=,F15,exec,/usr/local/bin/desktop-toggle\nbind=$mod,R,exec,pibble toggle\n' > "$FAKE_PAYLOAD/hypr/hyprland.lua"
echo "conf" > "$FAKE_PAYLOAD/hypr/hyprland.conf"
echo "x" > "$FAKE_PAYLOAD/hypr/shaders/main.glsl"; echo "x" > "$FAKE_PAYLOAD/hypr/shaders/reading_mode.glsl"; echo "x" > "$FAKE_PAYLOAD/hypr/shaders/matugen-agx.glsl"
echo "qml" > "$FAKE_PAYLOAD/quickshell/shell.qml"; echo "t" > "$FAKE_PAYLOAD/lucid/apply-theme.sh"
echo ok > "$FAKE_PAYLOAD/systemd-user/quickshell.service"
printf '#!/usr/bin/env bash\necho pibble\n' > "$FAKE_PAYLOAD/pibble/pibble"; chmod +x "$FAKE_PAYLOAD/pibble/pibble"
echo "m" > "$FAKE_PAYLOAD/lucid-capture/Makefile"
DRY_RUN=1; assert_true "phase_hypr dry-run" phase_hypr_stack; DRY_RUN=0
assert_true "verify_hypr_binds passes on good fixture" verify_hypr_binds
# real payload checks (1:1 fidelity)
assert_file_has "hyprland.lua has F15" "$REPO_DIR/payload/hypr/hyprland.lua" "F15"
assert_file_has "hyprland.lua launches pibble" "$REPO_DIR/payload/hypr/hyprland.lua" "pibble start"
assert_file_has "hyprland.lua has lucid/qs" "$REPO_DIR/payload/hypr/hyprland.lua" "quickshell"
assert_true "reading_mode.glsl exists" test -f "$REPO_DIR/payload/hypr/shaders/reading_mode.glsl"
assert_true "main.glsl exists" test -f "$REPO_DIR/payload/hypr/shaders/main.glsl"
assert_true "matugen-agx.glsl exists" test -f "$REPO_DIR/payload/hypr/shaders/matugen-agx.glsl"
assert_true "quickshell shell.qml exists" test -f "$REPO_DIR/payload/quickshell/shell.qml"
assert_true "lucid apply-theme exists" test -f "$REPO_DIR/payload/lucid/apply-theme.sh"
assert_true "pibble executable exists" test -x "$REPO_DIR/payload/pibble/pibble"
assert_file_has "shader.lua manages Reading Mode" "$REPO_DIR/payload/hypr/shader.lua" "Reading Mode"
assert_file_has "shader.lua binds K key" "$REPO_DIR/payload/hypr/shader.lua" "+ K"

echo "== 9b. hypr plugins + helpers =="
assert_true "phase_hypr_plugins exists" declare -F phase_hypr_plugins
assert_true "build_liquid_glass exists" declare -F build_liquid_glass
assert_true "verify_hypr_plugins exists" declare -F verify_hypr_plugins
# fixtures (helper with baked-in source username exercises the rewrite)
mkdir -p "$FAKE_PAYLOAD/usr-local-bin" "$FAKE_PAYLOAD/liquid-glass-hypr" "$FAKE_PAYLOAD/hypr-goo-workspaces"
for _b in hypr-inputs-ready minimize-all restore-all liquid-glass-toggle pin-all unpin-all gpu-tty-foot; do
  printf '#!/bin/sh\nexec foot --config /home/nicerice/.config/foot/foot-kiosk.ini\n' > "$FAKE_PAYLOAD/usr-local-bin/$_b"
done
printf 'all:\n\techo build\n' > "$FAKE_PAYLOAD/liquid-glass-hypr/Makefile"
echo "fixture-pin" > "$FAKE_PAYLOAD/liquid-glass-hypr/pin.txt"
printf 'all:\n\techo goo\n' > "$FAKE_PAYLOAD/hypr-goo-workspaces/Makefile"
export USRLOCAL_BIN="$TMP/usr-local-bin"
DRY_RUN=1; reset_calls
assert_true "phase_hypr_plugins dry-run" phase_hypr_plugins
assert_true "verify_hypr_plugins passes on fixture" verify_hypr_plugins
DRY_RUN=0; reset_calls
phase_hypr_plugins
assert_true "helper installed to fake usr-local" test -x "$TMP/usr-local-bin/minimize-all"
assert_file_has "username rewritten to target" "$TMP/usr-local-bin/gpu-tty-foot" "$FAKE_HOME/.config/foot"
if [[ "$(cat "$TMP/usr-local-bin/gpu-tty-foot")" == *"/home/nicerice"* ]]; then
  FAIL=$((FAIL+1)); echo "NOT OK - source username fully rewritten"
else PASS=$((PASS+1)); echo "ok - source username fully rewritten"; fi
if calls_contain "make"; then PASS=$((PASS+1)); echo "ok - build_liquid_glass runs make";
else FAIL=$((FAIL+1)); echo "NOT OK - build_liquid_glass runs make"; fi
# warn-only contract on empty payload
if PAYLOAD_DIR="$TMP/empty-payload" verify_hypr_plugins 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - verify_hypr_plugins warn-only on empty payload"
else FAIL=$((FAIL+1)); echo "NOT OK - verify_hypr_plugins warn-only on empty payload"; fi
# real payload 1:1 fidelity (goo = hypr-goo-workspaces, merged into liquidglass)
assert_file_has "minimize-all lua dispatch" "$REPO_DIR/payload/usr-local-bin/minimize-all" "hl.dispatch"
assert_file_has "hypr-inputs-ready gates IPC" "$REPO_DIR/payload/usr-local-bin/hypr-inputs-ready" "hyprctl instances"
assert_file_has "liquid-glass-toggle prefs" "$REPO_DIR/payload/usr-local-bin/liquid-glass-toggle" "prefs.json"
assert_file_has "gpu-tty-foot kiosk" "$REPO_DIR/payload/usr-local-bin/gpu-tty-foot" "foot-kiosk.ini"
assert_file_has "liquid-glass pin is live HEAD" "$REPO_DIR/payload/liquid-glass-hypr/pin.txt" "17978c2f13d091018178f9b519cd09acc255ec34"
assert_file_has "liquid-glass Makefile target" "$REPO_DIR/payload/liquid-glass-hypr/Makefile" "TARGET = liquidglass.so"
assert_true "goo sources vendored" test -f "$REPO_DIR/payload/hypr-goo-workspaces/src/main.cpp"
_hit="$(find "$REPO_DIR/payload/liquid-glass-hypr" "$REPO_DIR/payload/hypr-goo-workspaces" \( -name "*.o" -o -name "*.so*" \) | head -n 1 || true)"
if [[ -z "$_hit" ]]; then PASS=$((PASS+1)); echo "ok - no build artifacts vendored";
else FAIL=$((FAIL+1)); echo "NOT OK - build artifacts vendored: $_hit"; fi

echo "== 10. phase C: apps =="
assert_true "phase_apps exists" declare -F phase_apps
assert_true "install_bucklespring_sounds exists" declare -F install_bucklespring_sounds
assert_true "build_buckle exists" declare -F build_buckle
assert_true "install_zed exists" declare -F install_zed
assert_true "build_zed_from_source exists" declare -F build_zed_from_source
assert_true "activate_home_scripts exists" declare -F activate_home_scripts
mkdir -p "$FAKE_PAYLOAD/kitty" "$FAKE_PAYLOAD/audio-stack" "$FAKE_PAYLOAD/pipewire" \
  "$FAKE_PAYLOAD/wireplumber" "$FAKE_PAYLOAD/vac-gui" "$FAKE_PAYLOAD/nvim" \
  "$FAKE_PAYLOAD/zed-config" "$FAKE_PAYLOAD/home-scripts" "$FAKE_PAYLOAD/local-bin" \
  "$FAKE_PAYLOAD/bucklespring-sounds/kalih-box-white"
echo "kitty" > "$FAKE_PAYLOAD/kitty/kitty.conf"
echo "nvim" > "$FAKE_PAYLOAD/nvim/init.lua"
echo "{}" > "$FAKE_PAYLOAD/zed-config/settings.json"
echo "wav" > "$FAKE_PAYLOAD/bucklespring-sounds/kalih-box-white/00-0.wav"
echo 'echo hi' > "$FAKE_PAYLOAD/home-scripts/demo.sh"
echo 'echo helper' > "$FAKE_PAYLOAD/local-bin/helper"
echo "s" > "$FAKE_PAYLOAD/systemd-user/bucklespring.service"
echo "v" > "$FAKE_PAYLOAD/systemd-user/vac.service"
echo "ve" > "$FAKE_PAYLOAD/systemd-user/vac-enforcer.service"
DRY_RUN=1; assert_true "phase_apps dry-run" phase_apps; DRY_RUN=0
# bucklespring branch: dir payload
rm -f "$FAKE_LARGE/bucklespring-kalih-box-white.tar.zst"
DRY_RUN=0; install_bucklespring_sounds
assert_true "buckle sounds installed from dir" test -f "$FAKE_HOME/.local/share/bucklespring/kalih-box-white/00-0.wav"
# home scripts activation
mkdir -p "$FAKE_HOME/.home-scripts-staging"; echo 'echo staged' > "$FAKE_HOME/.home-scripts-staging/t.sh"
activate_home_scripts
assert_true "home script activated" test -x "$FAKE_HOME/t.sh"
# real payload checks
assert_true "kitty.conf exists" test -f "$REPO_DIR/payload/kitty/kitty.conf"
assert_file_has "kitty includes matugen" "$REPO_DIR/payload/kitty/kitty.conf" "matugen"
assert_true "nvim init exists" test -f "$REPO_DIR/payload/nvim/init.lua"
assert_file_has "nvim uses lazy" "$REPO_DIR/payload/nvim/init.lua" "lazy"
assert_true "zed settings exist" test -f "$REPO_DIR/payload/zed-config/settings.json"
assert_true "zed pin recorded" test -f "$REPO_DIR/payload/zed-pin.txt"
assert_true "buckle service exists" test -f "$REPO_DIR/payload/systemd-user/bucklespring.service"
assert_file_has "buckle uses kalih-box-white" "$REPO_DIR/payload/systemd-user/bucklespring.service" "kalih-box-white"
assert_true "audio-stack exported" test -d "$REPO_DIR/payload/audio-stack"
assert_true "home-scripts non-empty" test -n "$(ls -A "$REPO_DIR/payload/home-scripts")"
assert_true "60ish home scripts" test "$(ls "$REPO_DIR/payload/home-scripts" | wc -l)" -ge 50

echo "== 11. phase D: dotfiles =="
assert_true "phase_dotfiles exists" declare -F phase_dotfiles
mkdir -p "$FAKE_PAYLOAD/zsh" "$FAKE_PAYLOAD/bash" "$FAKE_PAYLOAD/x11" "$FAKE_PAYLOAD/pam" "$FAKE_PAYLOAD/git" "$FAKE_PAYLOAD/tmux" "$FAKE_PAYLOAD/matugen"
for f in zsh/dot.zshrc zsh/dot.zshenv zsh/dot.zprofile bash/dot.bashrc bash/dot.bash_profile bash/dot.profile x11/dot.Xresources pam/dot.pam_environment git/dot.gitignore tmux/dot.tmux.conf matugen/dot.mutagen-sync-dev.sh matugen/dot.matugen-watch-dev.sh; do echo "x" > "$FAKE_PAYLOAD/$f"; done
DRY_RUN=1; assert_true "phase_dotfiles dry-run" phase_dotfiles; DRY_RUN=0
DRY_RUN=0; phase_dotfiles
assert_true "zshrc installed" test -f "$FAKE_HOME/.zshrc"
assert_true "tmux conf installed" test -f "$FAKE_HOME/.tmux.conf"
assert_file_has "real zshrc has tmux" "$REPO_DIR/payload/zsh/dot.zshrc" "tmux"
assert_file_has "real tmux has continuum" "$REPO_DIR/payload/tmux/dot.tmux.conf" "continuum"
assert_file_has "real tmux prefix C-z" "$REPO_DIR/payload/tmux/dot.tmux.conf" "C-z"

echo "== 11b. oh-my-zsh =="
assert_true "install_ohmyzsh exists" declare -F install_ohmyzsh
mkdir -p "$FAKE_PAYLOAD/oh-my-zsh/custom"
echo "deadbeef-pin" > "$FAKE_PAYLOAD/oh-my-zsh/pin.txt"
echo "custom" > "$FAKE_PAYLOAD/oh-my-zsh/custom/example.zsh"
DRY_RUN=1; reset_calls
assert_true "install_ohmyzsh dry-run" install_ohmyzsh
DRY_RUN=0
# real run with mocked git: clone logged, no network, no crash
reset_calls
install_ohmyzsh
if calls_contain "clone"; then PASS=$((PASS+1)); echo "ok - install_ohmyzsh clones framework";
else FAIL=$((FAIL+1)); echo "NOT OK - install_ohmyzsh clones framework"; fi
# same .zshrc: lock the oh-my-zsh wiring + live sync
assert_file_has "zshrc points at oh-my-zsh" "$REPO_DIR/payload/zsh/dot.zshrc" 'export ZSH="$HOME/.oh-my-zsh"'
assert_file_has "zshrc theme afowler" "$REPO_DIR/payload/zsh/dot.zshrc" 'ZSH_THEME="afowler"'
assert_file_has "zshrc plugins git" "$REPO_DIR/payload/zsh/dot.zshrc" 'plugins=(git)'
assert_file_has "zshrc sources framework" "$REPO_DIR/payload/zsh/dot.zshrc" 'source $ZSH/oh-my-zsh.sh'
if diff -q "$HOME/.zshrc" "$REPO_DIR/payload/zsh/dot.zshrc" >/dev/null 2>&1; then
  PASS=$((PASS+1)); echo "ok - payload zshrc identical to live .zshrc"
else FAIL=$((FAIL+1)); echo "NOT OK - payload zshrc identical to live .zshrc"; fi
assert_true "oh-my-zsh pin recorded" test -f "$REPO_DIR/payload/oh-my-zsh/pin.txt"
assert_file_has "oh-my-zsh pin is live HEAD" "$REPO_DIR/payload/oh-my-zsh/pin.txt" "146461f7c6d95f4ba1220559d66eb113418b40a8"
assert_true "oh-my-zsh custom vendored" test -d "$REPO_DIR/payload/oh-my-zsh/custom"

echo "== 11c. opencode local config =="
assert_true "install_opencode exists" declare -F install_opencode
mkdir -p "$FAKE_PAYLOAD/config-opencode" "$FAKE_PAYLOAD/opencode-home"
printf '{"agent":{"build":{"model":"m"}}}\n' > "$FAKE_PAYLOAD/config-opencode/opencode.json"
printf '{"theme":"matugen"}\n' > "$FAKE_PAYLOAD/config-opencode/tui.json"
printf '{"x":1}\n' > "$FAKE_PAYLOAD/opencode-home/opencode.json"
printf '{"dependencies":{}}\n' > "$FAKE_PAYLOAD/config-opencode/package.json"
DRY_RUN=1; reset_calls
assert_true "install_opencode dry-run" install_opencode
DRY_RUN=0; reset_calls
install_opencode
assert_true "opencode config installed" test -f "$FAKE_HOME/.config/opencode/opencode.json"
assert_true "opencode-home installed" test -f "$FAKE_HOME/.opencode/opencode.json"
if calls_contain "install"; then PASS=$((PASS+1)); echo "ok - install_opencode restores node deps via bun";
else FAIL=$((FAIL+1)); echo "NOT OK - install_opencode restores node deps via bun"; fi
# real payload fidelity
assert_file_has "opencode build model" "$REPO_DIR/payload/config-opencode/opencode.json" "opencode/muse-spark-1.3-contributor-free"
assert_file_has "opencode chrome-devtools mcp" "$REPO_DIR/payload/config-opencode/opencode.json" "chrome-devtools"
assert_file_has "opencode tui matugen" "$REPO_DIR/payload/config-opencode/tui.json" '"theme": "matugen"'
assert_true "opencode terminal-bell plugin" test -f "$REPO_DIR/payload/config-opencode/plugin/terminal-bell.ts"
assert_true "opencode openhooks plugin" test -f "$REPO_DIR/payload/config-opencode/plugins/openhooks/plugin.mjs"
assert_true "opencode-home commands" test -d "$REPO_DIR/payload/opencode-home/commands"
assert_file_has "opencode key placeholder" "$REPO_DIR/payload/config-opencode/opencode.json" '${CONTEXT7_API_KEY}'
# STANDING RULE guards: no live keys, no ssh secrets — in payload...
# (self-safe: pattern requires an alnum after the prefix; this file only
# holds the bare prefix inside brackets, and payload/ is scanned, not tests/)
_leak="$(rg -l --no-messages --glob '!node_modules' 'ctx7sk-[A-Za-z0-9]|sk-ant-[A-Za-z0-9]|BEGIN OPENSSH PRIVATE KEY|BEGIN RSA PRIVATE KEY' "$REPO_DIR/payload" || true)"
if [[ -z "$_leak" ]]; then PASS=$((PASS+1)); echo "ok - no secrets in payload tree";
else FAIL=$((FAIL+1)); echo "NOT OK - secret leaked in payload: $_leak"; fi
# ...and none in ssh-shaped paths at all
_hit="$(find "$REPO_DIR/payload" \( -name "id_rsa" -o -name "id_ed25519*" -o -name "*.pem" -o -name ".ssh" -o -name "known_hosts" \) | head -n 1)"
if [[ -n "$_hit" ]]; then
  FAIL=$((FAIL+1)); echo "NOT OK - ssh material in payload: $_hit"
else PASS=$((PASS+1)); echo "ok - no ssh material in payload"; fi
# ...and none anywhere in git history (uses real git: tests mock $PATH git)
# NOTE: `| head` may SIGPIPE git under pipefail — neutralize with || true.
# -S would still flag the redaction commits themselves (count changed), so
# assert on blob content instead: grep all revisions, expect no hits.
# (trailing-class required: the redaction regex text itself lives in
# install.sh/tests, but only as a bare prefix inside brackets.)
_hit="$(/usr/bin/git -C "$REPO_DIR" grep -l 'ctx7sk-[A-Za-z0-9]' $(/usr/bin/git -C "$REPO_DIR" rev-list --all 2>/dev/null) -- 2>/dev/null | head -n 1 || true)"
if [[ -n "$_hit" ]]; then
  FAIL=$((FAIL+1)); echo "NOT OK - API key reachable in git history: $_hit"
else PASS=$((PASS+1)); echo "ok - no API keys in git history"; fi

echo "== 12. phase E: matugen =="
assert_true "phase_matugen exists" declare -F phase_matugen
assert_true "install_matugen_wallpapers exists" declare -F install_matugen_wallpapers
mkdir -p "$FAKE_PAYLOAD/matugen/templates" "$FAKE_PAYLOAD/hypr-wallpapers" "$FAKE_PAYLOAD/wallpapers-matugen"
echo "toml" > "$FAKE_PAYLOAD/matugen/config.toml"; echo "img" > "$FAKE_PAYLOAD/wallpapers-matugen/a.jpg"
DRY_RUN=1; assert_true "phase_matugen dry-run" phase_matugen; DRY_RUN=0
install_matugen_wallpapers
assert_true "wallpaper installed" test -f "$FAKE_HOME/Pictures/wallpapers/matugen/a.jpg"
assert_true "real matugen config exists" test -f "$REPO_DIR/payload/matugen/config.toml"
assert_file_has "matugen has kitty template" "$REPO_DIR/payload/matugen/config.toml" "kitty"
assert_true "matugen templates non-empty" test -n "$(ls -A "$REPO_DIR/payload/matugen/templates")"

echo "== 13. phase F: tmux =="
assert_true "phase_tmux exists" declare -F phase_tmux
assert_true "install_tmux_plugins exists" declare -F install_tmux_plugins
mkdir -p "$FAKE_PAYLOAD/tmux-resurrect"; echo "resurrect" > "$FAKE_PAYLOAD/tmux-resurrect/last"
DRY_RUN=1; assert_true "phase_tmux dry-run" phase_tmux; DRY_RUN=0
DRY_RUN=1; assert_true "install_tmux_plugins dry-run" install_tmux_plugins; DRY_RUN=0

echo "== 14. export + verify =="
assert_true "export_file exists" declare -F export_file
assert_true "export_dir exists" declare -F export_dir
assert_true "verify_install exists" declare -F verify_install
echo "src" > "$TMP/src.txt"; export_file "$TMP/src.txt" "$TMP/dst.txt"
assert_eq "export_file copies" "src" "$(cat "$TMP/dst.txt")"
mkdir -p "$TMP/sd"; echo "d" > "$TMP/sd/f"; export_dir "$TMP/sd" "$TMP/dd"
assert_eq "export_dir copies" "d" "$(cat "$TMP/dd/f")"
# verify_install on empty home should FAIL (documents contract)
if TARGET_HOME="$TMP/empty-home" verify_install 2>/dev/null; then FAIL=$((FAIL+1)); echo "NOT OK - verify should fail on empty home";
else PASS=$((PASS+1)); echo "ok - verify fails on empty home"; fi

echo "== 15. installer structural contract =="
assert_file_has "install.sh has group a" "$REPO_DIR/install.sh" "phase_tty_kmscon"
assert_file_has "install.sh has group b" "$REPO_DIR/install.sh" "phase_hypr_stack"
assert_file_has "install.sh has group c" "$REPO_DIR/install.sh" "phase_apps"
assert_file_has "install.sh has group d" "$REPO_DIR/install.sh" "phase_dotfiles"
assert_file_has "install.sh has group e" "$REPO_DIR/install.sh" "phase_matugen"
assert_file_has "install.sh has group f" "$REPO_DIR/install.sh" "phase_tmux"
assert_file_has "install.sh supports --only" "$REPO_DIR/install.sh" "--only"
assert_file_has "install.sh supports --dry-run" "$REPO_DIR/install.sh" "--dry-run"
assert_file_has "install.sh supports --export" "$REPO_DIR/install.sh" "--export"
assert_true "payload-large README exists" test -f "$REPO_DIR/payload-large/README.md"
assert_file_has "gitattributes LFS-tracks tarballs" "$REPO_DIR/.gitattributes" "payload-large/*.tar.zst filter=lfs"
for _tb in wallpapers-matugen.tar.zst bucklespring-kalih-box-white.tar.zst zed-custom.tar.zst; do
  # NOTE: working tree holds real binaries; the committed form is the LFS
  # pointer in the index — assert on staged content, not the file.
  # NOTE: tests mock $PATH git — use the real binary for index inspection.
  if [[ "$(/usr/bin/git -C "$REPO_DIR" show ":payload-large/$_tb" 2>/dev/null | head -n 1)" == *"git-lfs.github.com/spec/v1"* ]]; then
    PASS=$((PASS+1)); echo "ok - LFS pointer staged: $_tb"
  else FAIL=$((FAIL+1)); echo "NOT OK - LFS pointer staged: $_tb"; fi
  if [[ "$(/usr/bin/git -C "$REPO_DIR" check-attr filter -- "payload-large/$_tb" 2>/dev/null)" == *"filter: lfs"* ]]; then
    PASS=$((PASS+1)); echo "ok - LFS filter set: $_tb"
  else FAIL=$((FAIL+1)); echo "NOT OK - LFS filter set: $_tb"; fi
done

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
rm -rf "$TMP"
[[ $FAIL -eq 0 ]]

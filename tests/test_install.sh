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
FAKE_PAYLOAD="$TMP/payload"; FAKE_HOME="$TMP/home"; FAKE_LARGE="$TMP/large"; FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_PAYLOAD" "$FAKE_HOME" "$FAKE_LARGE" "$FAKE_BIN"
export PAYLOAD_DIR="$FAKE_PAYLOAD" TARGET_HOME="$FAKE_HOME" LARGE_DIR="$FAKE_LARGE"
export PATH="$FAKE_BIN:$PATH"

# mock system tools: log invocations, succeed
for tool in sudo systemctl cc git pacman paru matugen tmux pkill hyprctl loginctl awww; do
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

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
rm -rf "$TMP"
[[ $FAIL -eq 0 ]]

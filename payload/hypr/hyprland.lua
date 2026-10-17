-- Hyprland Lua config - migrated from hyprland.conf (Dell S2417DG 2560x1440@165 scale 1.25)
-- Generated to silence "You are using the .conf config format, support will be removed in 0.57" warning
-- See https://wiki.hypr.land/Configuring/Start/ and /usr/share/hypr/hyprland.lua for reference
local shader = require("shader")

------------------
---- MONITORS ----
------------------
hl.monitor({ output = "DP-2", mode = "3840x2160@60", position = "0x0", scale = 2.4 })
-- DP-1 at 165Hz (monitor overclock on). Was 120Hz so 120/60/60 shared a
-- content cadence; back to 120 if mixed-refresh judder shows.
hl.monitor({ output = "DP-1", mode = "2560x1440@165", position = "1600x0", scale = 1.6 })
hl.monitor({ output = "DP-3", mode = "3840x2160@60", position = "3200x0", scale = 2.4 })
hl.monitor({ output = "HDMI-A-1", disabled = true })
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })

hl.workspace_rule({ workspace = "1", monitor = "DP-1", persistent = true })
hl.workspace_rule({ workspace = "2", monitor = "DP-1", persistent = true })
hl.workspace_rule({ workspace = "3", monitor = "DP-1", persistent = true })
hl.workspace_rule({ workspace = "4", monitor = "DP-2", persistent = true })
hl.workspace_rule({ workspace = "5", monitor = "DP-2", persistent = true })
hl.workspace_rule({ workspace = "6", monitor = "DP-2", persistent = true })
hl.workspace_rule({ workspace = "7", monitor = "DP-3", persistent = true })
hl.workspace_rule({ workspace = "8", monitor = "DP-3", persistent = true })
hl.workspace_rule({ workspace = "9", monitor = "DP-3", persistent = true })
-- Second vertical row: real additional space below row 1.
-- DP-1: 11-13, DP-2: 14-16, DP-3: 17-19. Pairs: 1<->11, 2<->12, 3<->13,
-- 4<->14, 5<->15, 6<->16, 7<->17, 8<->18, 9<->19. 10 stays scratch (see conf).
hl.workspace_rule({ workspace = "11", monitor = "DP-1", persistent = true })
hl.workspace_rule({ workspace = "12", monitor = "DP-1", persistent = true })
hl.workspace_rule({ workspace = "13", monitor = "DP-1", persistent = true })
hl.workspace_rule({ workspace = "14", monitor = "DP-2", persistent = true })
hl.workspace_rule({ workspace = "15", monitor = "DP-2", persistent = true })
hl.workspace_rule({ workspace = "16", monitor = "DP-2", persistent = true })
hl.workspace_rule({ workspace = "17", monitor = "DP-3", persistent = true })
hl.workspace_rule({ workspace = "18", monitor = "DP-3", persistent = true })
hl.workspace_rule({ workspace = "19", monitor = "DP-3", persistent = true })
-- Third vertical row: DP-1: 21-23, DP-2: 24-26, DP-3: 27-29.
-- Chain: 1->11->21, 2->12->22, ... 9->19->29. 20 stays free.
hl.workspace_rule({ workspace = "21", monitor = "DP-1", persistent = true })
hl.workspace_rule({ workspace = "22", monitor = "DP-1", persistent = true })
hl.workspace_rule({ workspace = "23", monitor = "DP-1", persistent = true })
hl.workspace_rule({ workspace = "24", monitor = "DP-2", persistent = true })
hl.workspace_rule({ workspace = "25", monitor = "DP-2", persistent = true })
hl.workspace_rule({ workspace = "26", monitor = "DP-2", persistent = true })
hl.workspace_rule({ workspace = "27", monitor = "DP-3", persistent = true })
hl.workspace_rule({ workspace = "28", monitor = "DP-3", persistent = true })
hl.workspace_rule({ workspace = "29", monitor = "DP-3", persistent = true })
-- Extra horizontal columns 4-5 per row (5 wide x 3 tall per monitor). 30 stays free.
-- DP-1 row0: 31,32 | row1: 33,34 | row2: 35,36
hl.workspace_rule({ workspace = "31", monitor = "DP-1", persistent = true })
hl.workspace_rule({ workspace = "32", monitor = "DP-1", persistent = true })
hl.workspace_rule({ workspace = "33", monitor = "DP-1", persistent = true })
hl.workspace_rule({ workspace = "34", monitor = "DP-1", persistent = true })
hl.workspace_rule({ workspace = "35", monitor = "DP-1", persistent = true })
hl.workspace_rule({ workspace = "36", monitor = "DP-1", persistent = true })
-- DP-2 row0: 37,38 | row1: 39,40 | row2: 41,42
hl.workspace_rule({ workspace = "37", monitor = "DP-2", persistent = true })
hl.workspace_rule({ workspace = "38", monitor = "DP-2", persistent = true })
hl.workspace_rule({ workspace = "39", monitor = "DP-2", persistent = true })
hl.workspace_rule({ workspace = "40", monitor = "DP-2", persistent = true })
hl.workspace_rule({ workspace = "41", monitor = "DP-2", persistent = true })
hl.workspace_rule({ workspace = "42", monitor = "DP-2", persistent = true })
-- DP-3 row0: 43,44 | row1: 45,46 | row2: 47,48
hl.workspace_rule({ workspace = "43", monitor = "DP-3", persistent = true })
hl.workspace_rule({ workspace = "44", monitor = "DP-3", persistent = true })
hl.workspace_rule({ workspace = "45", monitor = "DP-3", persistent = true })
hl.workspace_rule({ workspace = "46", monitor = "DP-3", persistent = true })
hl.workspace_rule({ workspace = "47", monitor = "DP-3", persistent = true })
hl.workspace_rule({ workspace = "48", monitor = "DP-3", persistent = true })

-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------
hl.env("LIBVA_DRIVER_NAME", "nvidia")
hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
hl.env("NVD_BACKEND", "direct")
hl.env("GBM_BACKEND", "nvidia-drm")
hl.env("WLR_NO_HARDWARE_CURSORS", "0")
hl.env("XCURSOR_SIZE", "16")
hl.env("HYPRCURSOR_SIZE", "16")
hl.env("QT_QPA_PLATFORM", "wayland")
hl.env("QT_WAYLAND_DISABLE_WINDOWDECORATION", "0")
hl.env("QT_AUTO_SCREEN_SCALE_FACTOR", "1")
hl.env("GDK_BACKEND", "wayland,x11")
hl.env("GDK_SCALE", "1")
hl.env("SDL_VIDEODRIVER", "wayland")
hl.env("CLUTTER_BACKEND", "wayland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "wayland")
hl.env("NIXOS_OZONE_WL", "1")

-------------------
---- AUTOSTART ----
-------------------
hl.on("hyprland.start", function()
  pcall(function()
    local home = os.getenv("HOME") or "/home/nicerice"
    local function is_on(path) local f=io.open(path,"r"); if not f then return false end; local l=f:read("*l") or ""; f:close(); return l:match("^%s*on%s*$") ~= nil end
    if is_on(home.."/.cache/quickshell/reading_mode") then return end
    if is_on(home.."/.cache/quickshell/night_light") then return end
    if is_on(home.."/.cache/quickshell/crt_mode") then return end
    -- homogenizer disabled by default for now: boot to Main (SUPER+G to enable AgX)
    shader.enable("Main")
  end)
  hl.exec_cmd("awww-daemon")
  hl.exec_cmd("systemctl --user is-active -q quickshell || systemctl --user start quickshell")
  hl.exec_cmd("hypridle")
  -- Lucid shell (quickshell NotificationServer in lucidbar/Notifications.qml)
  -- owns org.freedesktop.Notifications. Do NOT autostart dunst/mako/swaync:
  -- whichever holds the bus name first wins and the other silently never
  -- receives notifications. Kill strays so a `hyprctl reload` (which re-runs
  -- this block) can't resurrect the Hyprland-default popup path.
  hl.exec_cmd("pkill -x dunst; pkill -x mako; pkill -x swaync; true")
  hl.exec_cmd("/usr/lib/hyprpolkitagent/hyprpolkitagent || /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1")
  hl.exec_cmd("wl-paste --watch cliphist store")
  -- Pibble launcher daemon (replaces Lucid dock launcher + vicinae; Super-tap toggles it)
  hl.exec_cmd("/home/nicerice/src/pibble/pibble start")
  -- Steam entirely in background, no windows (tray only via -silent, pgrep guard since reload re-runs this block)
  hl.exec_cmd("pgrep -x steam > /dev/null || steam -silent")
  hl.exec_cmd("~/.config/hypr/scripts/keyboard-hotplug.sh")
  -- Windows-RIT equivalent: prioritize Hyprland over builders so key releases
  -- preempt rustc/opencode under load (keeps repeat 125/125 usable). Safe to
  -- re-run on reload; script is idempotent. See scripts/input-rt.sh.
  hl.exec_cmd("~/.config/hypr/scripts/input-rt.sh")
  hl.exec_cmd("sleep 1 && ~/.config/hypr/scripts/wallpaper-restore.sh")
  -- liquid-glass-hypr: in-render-pass glass for quickshell layers.
  -- Geometry comes from ~/.cache/liquid-glass-hypr (qs writes it at boot).
  -- Never `hyprctl plugin unload` this live: unload SEGVs (GL teardown
  -- off-context). To update: rebuild, then reboot / SIGTERM-cycle.
  -- liquid-glass-hypr: in-render-pass glass for quickshell layers.
  -- Geometry comes from ~/.cache/liquid-glass-hypr (qs writes it at boot).
  -- Never `hyprctl plugin unload` this live: unload SEGVs (GL teardown
  -- off-context). To update: rebuild, then reboot / exit-cycle.
  -- Guarded: a bare `hyprctl reload` re-runs this block, and loading the
  -- same .so twice aborts the compositor (SIGABRT 12:46). Skip if present.
  -- 2026-09-06: re-enabled with monitorLive guard in hkDropShadowDraw
  -- (stale-monitor SEGV during VT-switch reconfig fixed in plugin).
  hl.exec_cmd("hyprctl plugin list 2>/dev/null | grep -q liquid-glass-hypr || hyprctl plugin load /home/nicerice/src/liquid-glass-hypr/liquidglass.so")
  -- Machine-local glass preset (this box has VRAM to spare): full-res working
  -- buffers + no CA. Applied BOTH here (fresh boot, after the plugin loads)
  -- and on every config.reloaded below: ephemeral `hl.config` plugin keys are
  -- wiped by every `hyprctl reload`, and the start handler does NOT re-fire
  -- on reload (only top-level code + reloaded handlers do). Stays configurable
  -- live via hyprctl eval (capture_scale 2 = half-res/full buffers,
  -- 4 = quarter-res/lean). No-ops harmlessly if the plugin isn't up yet.
  hl.exec_cmd("hyprctl eval 'hl.config({plugin={liquidglass={capture_scale=2, ca=0}}})' 2>/dev/null || true")
  -- hypr-goo-workspaces merged INTO liquid-glass-hypr 0.5.0 (single
  -- renderWindow trampoline owner; standalone build retired). No separate
  -- load — it would double-hook rounding/events.
end)

-- Glass preset re-apply on every reload (top-level runs on reload; the start
-- handler above does not re-fire). Mirrors the boot apply: no loop risk —
-- hl.config sets runtime values without triggering another reload (same
-- pattern as shader.lua's config.reloaded handler).
hl.on("config.reloaded", function()
  hl.exec_cmd("hyprctl eval 'hl.config({plugin={liquidglass={capture_scale=2, ca=0}}})' 2>/dev/null || true")
end)

-----------------------
---- LOOK AND FEEL ----
-----------------------
hl.config({
  general = {
    gaps_in = 10,
    gaps_out = { top = 37, right = 50, bottom = 37, left = 50 },
    -- TEMPORARY revert (2026-09-17): frames parked, back to the 1px hairline.
    -- The relief code is untouched and dormant below 6fb px by design; to
    -- bring the gallery back, set this to 8 again (~13fb px DP-1, ~19fb 4Ks).
    border_size = 1,
    col = {
      active_border = { colors = { "rgba(89b4faee)", "rgba(cba6f7ee)" }, angle = 45 },
      inactive_border = "rgba(313244aa)",
    },
    layout = "dwindle",
  },
  dwindle = {
    preserve_split = true,
    smart_split = false,
    split_width_multiplier = 1.0,
    force_split = 0,
    use_active_for_splits = true,
  },
  decoration = {
    rounding = 20,
    shadow = { enabled = true, range = 4, render_power = 3, color = "rgba(1a1a1aee)" },
    blur = { enabled = true, size = 3, passes = 2 },
    -- homogenizer disabled by default for now (shader.lua manages toggles, SUPER+G to enable)
    screen_shader = "/home/nicerice/.config/hypr/shaders/main.glsl",
  },
  animations = { enabled = true },
  xwayland = { force_zero_scaling = true },
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    mouse_move_enables_dpms = true,
    key_press_enables_dpms = true,
    -- Activation focus is OFF by default: activation requests (urgent hints,
    -- terminal bells, link-openings) only flag the window urgent, never steal
    -- focus. The urgency guard in custom.lua restores the Windows-style jump
    -- (focus the requester incl. workspace switch) but ONLY after 5s without
    -- key/mouse input - so background bells can't yank focus mid-keystroke,
    -- while opening a link while idle still takes you to it. Every focus
    -- change + urgent decision is logged to /tmp/urgency-guard.log.
    focus_on_activate = false,
    -- DP-1 is VRR-capable (G-Sync) but VRR latches VRR_ENABLED on the CRTC
    -- across VT switches: kmscon's fixed-refresh atomic commits then stall
    -- ~3s per head (Flip event timeout x3 on triple-head = ~10s frozen on
    -- the last Hyprland frame, kernel already on tty1). Keep VRR off so the
    -- tty1 switch lands instantly. Re-enable per-game if needed (vrr=2 =
    -- fullscreen-only is the compromise to try first).
    vrr = 0,
  },
  input = {
    kb_layout = "us,ru",
    kb_variant = ",phonetic_winkeys",
    kb_model = "pc105+inet",
    kb_options = "grp:alt_shift_toggle,grp_led:scroll,terminate:ctrl_alt_bksp",
    repeat_delay = 125,
    repeat_rate = 125,
    -- focus follows mouse ENABLED: hovering a window focuses it (click-only was
    -- 2026-10-09 follow_mouse=0, reverted per request).
    follow_mouse = 1,
    resolve_binds_by_sym = true,
    touchpad = { natural_scroll = false },
  },
  -- idle-hide off (inactive_timeout = 0 disables it); typing-hide via
  -- hide_on_key_press + xbanish. Do not set >0 or cursor vanishes when idle.
  -- 2026-09-19: instant system-wide vanish on idle with HW cursors on NVIDIA
  -- 580 (GTX 1080 Ti) despite inactive_timeout=0 -> force software cursors.
  -- Revert: set back to 2 (auto).
  cursor = {
    hide_on_key_press = true,
    inactive_timeout = 0,
    hide_on_touch = true,
    no_hardware_cursors = 1,
  },
})

hl.curve("easeOut", { type = "bezier", points = { {0.05, 0.9}, {0.1, 1.05} } })
hl.animation({ leaf = "windows", enabled = true, speed = 4, bezier = "easeOut" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 4, bezier = "easeOut", style = "popin 78%" })
hl.animation({ leaf = "border", enabled = true, speed = 8, bezier = "default" })
hl.animation({ leaf = "borderangle", enabled = true, speed = 8, bezier = "default" })
hl.animation({ leaf = "fade", enabled = true, speed = 4, bezier = "default" })
-- Workspace switch, companion mode: STOCK animation owns MOTION (directional
-- slide left/right/up/down, steered per-jump by setWsStyle in custom.lua —
-- exactly as before). The goo-workspaces morph in liquid-glass-hypr adds ONLY
-- per-window alpha + scale on top and MUST NOT move windows itself (its slide/
-- collapse/genie are all zeroed below) or the two motions stack into chaos.
-- Native style stays `slide` (alpha pinned at 1, no native fade) so the
-- plugin's outgoing 1.0 -> 0.33 dim applies exactly once.
hl.animation({ leaf = "workspaces", enabled = true, speed = 4, bezier = "default", style = "slide" })
-- Outgoing: fade 1.0 -> 0.0 (fade_out_min) on the upstream
-- move-from-workspace alpha channel, geometry untouched (collapse 1.0).
-- Linear out_curve = steady visible fade through the whole flight (reload-
-- and restart-safe on every binary; the staged ease-out variant in the
-- plugin only refines the curve shape).
-- Companion mode: native slide owns motion; plugin adds fade + uniform
-- scale. Incoming 0.95 -> 1.0 (blob_scale, wobble 0.0) on the tossed spring
-- (60/13/4: soft, slight overshoot). No start delays: every window gets its
-- OWN DURATION, 400ms + up to duration_spread_ms by rank (even coverage, no
-- collisions) + small hash wobble. All motion params zero.
hl.config({ plugin = { gooworkspaces = {
  enabled = 1,
  duration_ms = 400.0,
  -- Per-window duration spread (ms): window i runs 400 + 500*r_i.
  duration_spread_ms = 500.0,
  slide_ratio = 0.0,
  stretch = 0.0,
  squash = 0.0,
  -- Incoming scale target 0.95 -> 1.0.
  blob_scale = 0.95,
  -- Outgoing mirrors incoming: shrink 1.0 -> 0.5 while fading (linear).
  collapse = 0.5,
  -- 0.02, NOT 0.0: Hyprland culls windows with effectiveAlpha == 0 from
  -- rendering (CWindow::visible), and culled windows run no hooks so no
  -- restore can ever reach them = permanently invisible. 0.02 looks
  -- identical to 0 but never trips the cull.
  fade_out_min = 0.02,
  wobble_amp = 0.0,
  wobble_freq = 1.5,
  -- Legacy (start-delay era); ignored by the duration-spread design. Kept
  -- so old configs never hit unknown-key errors.
  stagger = 0.375,
  in_curve = "spring",
  out_curve = "linear",
  spring_stiffness = 60.0,
  spring_damping = 15.0,
  spring_velocity = 4.0,
  genie_pull = 0.0,
} } })

---------------------
---- KEYBINDINGS ----
---------------------
local mod = "SUPER"
-- Pibble launcher on bare SUPER tap only (not after SUPER+chord).
-- Plain release binds can't tell tap from chord, so track it: arm on Super
-- press, disarm on any other SUPER+key press, toggle on release only if armed.
-- (Replaces Lucid dock launcher `qs ipc call -- launcher toggle`; dock hidden via Prefs.dockEnabled=false.)
local super_tap_armed = false
-- Forward-declared here (assigned in the tmux section, NEVER redeclare with
-- local again): the tmux Super press arms it, and super_tap_disarm clears it
-- so any SUPER+chord evaluated globally after a tmux Super press kills tap
-- intent exactly like a global chord does. Must be one shared cell.
local tmux_super_armed = false
local function super_tap_arm() super_tap_armed = true end
local function super_tap_disarm() super_tap_armed = false tmux_super_armed = false end
local function make_super_tap_release(cmd)
  return function()
    if super_tap_armed then
      hl.dispatch(hl.dsp.exec_cmd(cmd))
    end
    super_tap_armed = false
  end
end
hl.bind("Super_L", super_tap_arm, { ignore_mods = true, transparent = true, non_consuming = true, description = "arm Pibble launcher tap (L press)" })
hl.bind("Super_R", super_tap_arm, { ignore_mods = true, transparent = true, non_consuming = true, description = "arm Pibble launcher tap (R press)" })
hl.bind("Meta_L", super_tap_arm, { ignore_mods = true, transparent = true, non_consuming = true, description = "arm Pibble launcher tap (Meta L press)" })
hl.bind("Meta_R", super_tap_arm, { ignore_mods = true, transparent = true, non_consuming = true, description = "arm Pibble launcher tap (Meta R press)" })
hl.bind("Super_L", make_super_tap_release("date +%s%3N > /tmp/supertap_L; /home/nicerice/src/pibble/pibble toggle"), { release = true, ignore_mods = true, transparent = true, description = "Pibble launcher (left SUPER tap)" })
hl.bind("Super_R", make_super_tap_release("date +%s%3N > /tmp/supertap_R; /home/nicerice/src/pibble/pibble toggle"), { release = true, ignore_mods = true, transparent = true, description = "Pibble launcher (right SUPER tap)" })
hl.bind("Meta_L", make_super_tap_release("date +%s%3N > /tmp/supertap_MetaL; /home/nicerice/src/pibble/pibble toggle"), { release = true, ignore_mods = true, transparent = true, description = "Pibble launcher (left META tap fallback)" })
hl.bind("Meta_R", make_super_tap_release("date +%s%3N > /tmp/supertap_MetaR; /home/nicerice/src/pibble/pibble toggle"), { release = true, ignore_mods = true, transparent = true, description = "Pibble launcher (right META tap fallback)" })
-- Interrupts: second-modifier presses cover every SUPER+Mod+key combo at the
-- moment the second modifier goes down; per-key entries cover plain SUPER+key.
for _, m in ipairs({ "Shift_L", "Shift_R", "Control_L", "Control_R", "Alt_L", "Alt_R" }) do
  hl.bind("SUPER + " .. m, super_tap_disarm, { transparent = true, non_consuming = true, description = "disarm launcher tap (SUPER+" .. m .. ")" })
end
for _, k in ipairs({ "C", "Return", "R", "SPACE", "Q", "F", "V", "J", "W", "S", "G", "K", "comma", "down", "F12", "D", "up", "F11", "U", "E", "left", "right", "H", "L", "XF86AudioRaiseVolume", "XF86AudioLowerVolume" }) do
  hl.bind("SUPER + " .. k, super_tap_disarm, { transparent = true, non_consuming = true, description = "disarm launcher tap (SUPER+" .. k .. ")" })
end
for _, mb in ipairs({ "mouse:272", "mouse:273", "mouse_up", "mouse_down" }) do
  hl.bind("SUPER + " .. mb, super_tap_disarm, { mouse = true, transparent = true, non_consuming = true, description = "disarm launcher tap (" .. mb .. ")" })
end
hl.bind(mod .. " + C", hl.dsp.exec_cmd("date +%s%3N > /tmp/presstest; /home/nicerice/src/pibble/pibble toggle"), { description = "Pibble launcher diagnostic (SUPER+C press)" })
hl.bind(mod .. " + Return", hl.dsp.exec_cmd("foot"))
-- Legacy drawerToggle + rofi fallback removed with rofi uninstall; dock hidden so point at pibble
hl.bind(mod .. " + R", hl.dsp.exec_cmd("/home/nicerice/src/pibble/pibble toggle"))
hl.bind(mod .. " + W", hl.dsp.exec_cmd("/home/nicerice/src/pibble/pibble toggle wallpapers"), { description = "Pibble wallpapers (SUPER+W)" })
-- Ported from legacy hyprland.conf (lua is the live config; conf-only binds
-- never fired): Lucid helpers. NOTE SUPER+L stays focus-right (custom.lua),
-- NOT the lock screen the old conf had.
hl.bind(mod .. " + E", hl.dsp.exec_cmd("qs ipc call -- moji toggle"), { description = "Lucid emoji (SUPER+E)" })
hl.bind(mod .. " + S", hl.dsp.exec_cmd("qs ipc call -- snap toggle"), { description = "Lucid snap (SUPER+S)" })
hl.bind(mod .. " + comma", hl.dsp.exec_cmd("qs ipc call -- settings open"), { description = "Lucid settings (SUPER+,)" })
-- SUPER+SPACE: toggle US / RU phonetic (restored, matches legacy hyprland.conf).
-- Replaces stale quickshell:hubToggle (no handler in current shell).
hl.bind(mod .. " + SPACE", hl.dsp.exec_cmd("hyprctl switchxkblayout all next"), { description = "Toggle RU phonetic keyboard (SUPER+SPACE)" })
hl.bind("ALT + F4", hl.dsp.global("quickshell:powerMenu"))
hl.bind(mod .. " + Q", hl.dsp.window.close())
hl.bind(mod .. " + F", hl.dsp.window.fullscreen({ mode = 0 }))
hl.bind(mod .. " + V", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mod .. " + J", hl.dsp.layout("togglesplit"))
hl.bind(mod .. " + down", hl.dsp.exec_cmd("/usr/local/bin/minimize-all"))
hl.bind(mod .. " + F12", hl.dsp.exec_cmd("/usr/local/bin/minimize-all"))
hl.bind(mod .. " + D", hl.dsp.exec_cmd("/usr/local/bin/minimize-all"))
hl.bind(mod .. " + SHIFT + down", hl.dsp.exec_cmd("/usr/local/bin/pin-all"))
hl.bind(mod .. " + SHIFT + F12", hl.dsp.exec_cmd("/usr/local/bin/pin-all"))
hl.bind(mod .. " + SHIFT + D", hl.dsp.exec_cmd("/usr/local/bin/pin-all"))
hl.bind(mod .. " + up", hl.dsp.exec_cmd("/usr/local/bin/restore-all"))
hl.bind(mod .. " + F11", hl.dsp.exec_cmd("/usr/local/bin/restore-all"))
hl.bind(mod .. " + U", hl.dsp.exec_cmd("/usr/local/bin/restore-all"))
hl.bind(mod .. " + SHIFT + up", hl.dsp.exec_cmd("/usr/local/bin/unpin-all"))
hl.bind(mod .. " + SHIFT + F11", hl.dsp.exec_cmd("/usr/local/bin/unpin-all"))
hl.bind(mod .. " + SHIFT + U", hl.dsp.exec_cmd("/usr/local/bin/unpin-all"))

-- tmux-style prefix: CTRL+BackSpace, 1s auto-exit
-- Sticky: one prefix press arms the submap, EVERY bind inside refreshes the
-- 1s deadline and stays in the submap, so C-BackSpace, arrows, space, C-z
-- etc. all chain without re-pressing the prefix. Exits: Esc, any unbound
-- key (catchall), Super tap (exits AND toggles pibble), re-pressing the
-- prefix never exits (just re-arms), plus the 1s timeout.
-- Fresh oneshot timer per arm (docs pattern); generation guard so a stale
-- timer can't reset a newer tmux session. NOTE: reusing one timer object
-- via set_enabled() does NOT reliably re-arm a spent oneshot — that's why
-- the first version of this lingered forever.
-- 10s: the morph-kill chord is reached for deliberately, not chained at
-- tmux speed. Socket-tap verified a real press pattern: prefix armed at
-- 11:32:23, x never registered before the 3s deadline reset at 11:32:27 -
-- a deliberate prefix...look...x pace outlives short deadlines. (1s died at
-- 1.6s gaps in testing; 3s still died on a real deliberate press.)
local TMUX_TIMEOUT_MS = 10000
local tmuxGen = 0
local function armTmuxTimeout()
  tmuxGen = tmuxGen + 1
  local gen = tmuxGen
  hl.timer(function()
    if gen == tmuxGen then
      tmux_super_armed = false
      local ok, cur = pcall(hl.get_current_submap)
      if ok and cur == "tmux" then
        hl.dispatch(hl.dsp.submap("reset"))
      end
    end
  end, { timeout = TMUX_TIMEOUT_MS, type = "oneshot" })
end
local function disarmTmuxTimeout()
  tmuxGen = tmuxGen + 1
end
-- Catchall guard: Hyprland delivers EVERY matching bind for one keypress,
-- so a bound key fires its action AND the catchall. Actions stamp this
-- guard first; the catchall only resets when the stamp is stale (>0.1s),
-- i.e. no other bind fired for the same keypress.
local tmuxCatchGuardAt = 0
local function tmuxGuard() tmuxCatchGuardAt = os.clock() end
-- NOTE: tmux_super_armed (dedicated Super-tap flag, see Super block below)
-- is forward-declared next to super_tap_armed so super_tap_disarm can clear
-- it; cleared on every other exit path so a stale arm can never fire later.
local function tmuxBind(key, disp)
  local function action()
    tmuxGuard()
    hl.dispatch(disp)
    armTmuxTimeout()
  end
  hl.bind(key, action)
  -- CTRL-held variant so C-<key> chains without releasing CTRL
  -- (e.g. C-BackSpace, arrows, space, then C-z). Skip keys that already
  -- carry a modifier.
  if not key:match("CTRL") and not key:match("SHIFT") and key ~= "escape" then
    pcall(function() hl.bind("CTRL + " .. key, action) end)
  end
end
-- Sticky binds (arrows, { / } and now everything else): act + refresh the 1s deadline, stay in submap.
local function tmuxSticky(key, disp, opts)
  opts = opts or { repeating = true }
  hl.bind(key, function()
    tmuxGuard()
    hl.dispatch(disp)
    armTmuxTimeout()
  end, opts)
end
-- tmux-style marked pane: Ctrl+BackSpace M marks, Ctrl+BackSpace U drops marked window here.
-- Persists across reloads via ~/.cache/hypr-marked-window (first line = address).
-- Highlight: the marked window gets an orange border via the "marked" tag +
-- tmux-marked rule below (no notification popups; the border is the feedback).
hl.window_rule({ name = "tmux-marked", match = { tag = "marked" }, border_color = "rgb(ff9e64) rgb(7c5c3e)" })
local tmuxMarkFile = (os.getenv("HOME") or "/home/nicerice") .. "/.cache/hypr-marked-window"
-- One physical Shift+M/Shift+U press matches several binds at once ("M" with
-- empty modmask matches as a subset, plus the explicit "SHIFT+M"), so guard
-- single-shot actions against duplicate delivery within 0.5s.
local tmuxLastMarkAt, tmuxLastDropAt = 0, 0
local function tmuxHasMarkTag(w)
  local ok, tags = pcall(function() return w.tags end)
  if not ok or type(tags) ~= "table" then return false end
  for _, t in ipairs(tags) do
    if t == "marked" then return true end
  end
  return false
end
local function tmuxMark()
  local t = os.clock()
  if t - tmuxLastMarkAt < 0.5 then return end
  tmuxLastMarkAt = t
  local ok, w = pcall(hl.get_active_window)
  if not ok or not w then return end
  local addr = nil
  pcall(function() addr = w.address end)
  if not addr or addr == "" then return end
  -- toggle: M on an already-marked window unmarks it
  if tmuxHasMarkTag(w) then
    pcall(function() hl.dispatch(hl.dsp.window.tag({ tag = "-marked", window = "address:" .. addr })) end)
    os.remove(tmuxMarkFile)
    return
  end
  -- clear highlight from previously marked window
  local f = io.open(tmuxMarkFile, "r")
  if f then
    local old = (f:read("*l") or ""):gsub("%s+", "")
    f:close()
    if old ~= "" and old ~= addr then
      pcall(function() hl.dispatch(hl.dsp.window.tag({ tag = "-marked", window = "address:" .. old })) end)
    end
  end
  pcall(function() hl.dispatch(hl.dsp.window.tag({ tag = "+marked" })) end)
  local title, cls, wsid = "", "", ""
  pcall(function() title = w.title or "" end)
  pcall(function() cls = w.class or "" end)
  pcall(function()
    local ws = hl.get_active_workspace()
    if ws then wsid = tostring(ws.id) end
  end)
  local fw = io.open(tmuxMarkFile, "w")
  if not fw then return end
  fw:write(addr .. "\n")
  fw:write("title=" .. title .. "\n")
  fw:write("class=" .. cls .. "\n")
  fw:write("workspace=" .. wsid .. "\n")
  fw:close()
end
local function tmuxDrop()
  local t = os.clock()
  if t - tmuxLastDropAt < 0.5 then return end
  tmuxLastDropAt = t
  local f = io.open(tmuxMarkFile, "r")
  if not f then return end
  local addr = (f:read("*l") or ""):gsub("%s+", "")
  f:close()
  if addr == "" then os.remove(tmuxMarkFile); return end
  local exists = false
  pcall(function()
    local w = hl.get_window("address:" .. addr)
    if w then exists = true end
  end)
  if not exists then
    pcall(function()
      for _, w in ipairs(hl.get_windows()) do
        if w.address == addr then exists = true; break end
      end
    end)
  end
  if not exists then os.remove(tmuxMarkFile); return end
  local wsid = nil
  pcall(function()
    local ws = hl.get_active_workspace()
    if ws then wsid = tostring(ws.id) end
  end)
  if not wsid then return end
  hl.dispatch(hl.dsp.window.move({ workspace = wsid, window = "address:" .. addr }))
  hl.dispatch(hl.dsp.focus({ window = "address:" .. addr }))
  pcall(function() hl.dispatch(hl.dsp.window.tag({ tag = "-marked", window = "address:" .. addr })) end)
  os.remove(tmuxMarkFile)
end
local function tmuxBindFn(key, fn, desc)
  local function action()
    tmuxGuard()
    pcall(fn)
    armTmuxTimeout()
  end
  hl.bind(key, action, desc and { description = desc } or nil)
  -- CTRL-held variant so C-m / C-u etc. chain while CTRL is still held.
  if not key:match("CTRL") and not key:match("SHIFT") then
    pcall(function() hl.bind("CTRL + " .. key, action, desc and { description = desc } or nil) end)
  end
end
hl.bind("CTRL + BackSpace", function()
  hl.dispatch(hl.dsp.submap("tmux"))
  armTmuxTimeout()
end)
hl.define_submap("tmux", function()
  tmuxBind("c", hl.dsp.exec_cmd("/home/nicerice/src/pibble/pibble toggle"))
  -- x closes ANY window: in-flight/recent pibble launches first
  -- (killflights exits 0), else the focused window. killactive stays on
  -- its global bind outside the submap.
  tmuxBind("x", hl.dsp.exec_cmd("/home/nicerice/src/pibble/pibble killflights || hyprctl dispatch 'hl.dsp.window.close()'"))
  -- Layout-proof fallbacks (resolve_binds_by_sym = true): in the RU
  -- phonetic layout the X/C positions send Cyrillic_ha/Cyrillic_es, so the
  -- sym binds above never fire there and the catchall silently eats the
  -- submap. Keycodes are layout-independent (XKB numbering, evdev+8:
  -- AB02/X=53, AB03/C=54). Both fire in US layout; kill/toggle are
  -- idempotent so the double exec is harmless.
  tmuxBind("code:53", hl.dsp.exec_cmd("/home/nicerice/src/pibble/pibble killflights || hyprctl dispatch 'hl.dsp.window.close()'"))
  tmuxBind("code:54", hl.dsp.exec_cmd("/home/nicerice/src/pibble/pibble toggle"))
  tmuxBind("z", hl.dsp.window.fullscreen({ mode = 1 }))
  tmuxBind("f", hl.dsp.window.fullscreen({ mode = 0 }))
  tmuxBind("v", hl.dsp.window.float({ action = "toggle" }))
  -- Workspace jumps pre-steer the slide with the shared steerWsJump()
  -- (custom.lua) so they never inherit a stale direction; the
  -- workspace.active handler re-steers from the actual from->to anyway.
  local function tmuxCurWs()
    local id = nil
    pcall(function()
      local w = hl.get_active_workspace()
      if w then id = w.id end
    end)
    return id
  end
  local function tmuxWsRel(dir)
    return function()
      tmuxGuard()
      local c = tmuxCurWs()
      if c then steerWsJump(c, c + dir) end
      hl.dispatch(hl.dsp.focus({ workspace = dir > 0 and "e+1" or "e-1" }))
      armTmuxTimeout()
    end
  end
  hl.bind("n", tmuxWsRel(1))
  pcall(function() hl.bind("CTRL + n", tmuxWsRel(1)) end)
  hl.bind("p", tmuxWsRel(-1))
  pcall(function() hl.bind("CTRL + p", tmuxWsRel(-1)) end)
  local function tmuxWsNum(k)
    return function()
      tmuxGuard()
      local c = tmuxCurWs()
      if c then steerWsJump(c, tonumber(k)) end
      hl.dispatch(hl.dsp.focus({ workspace = k }))
      armTmuxTimeout()
    end
  end
  for i = 1, 9 do
    local k = tostring(i)
    hl.bind(k, tmuxWsNum(k))
    pcall(function() hl.bind("CTRL + " .. k, tmuxWsNum(k)) end)
  end
  tmuxBind("space", hl.dsp.layout("togglesplit"))
  -- F16 = open kitty from inside tmux mode too (global binds don't fire in submaps)
  tmuxBind("F16", hl.dsp.exec_cmd("kitty"))
  tmuxBind("code:194", hl.dsp.exec_cmd("kitty"))
  -- F17 = open nautilus from inside tmux mode too
  tmuxBind("F17", hl.dsp.exec_cmd("nautilus --new-window"))
  tmuxBind("code:195", hl.dsp.exec_cmd("nautilus --new-window"))
  tmuxSticky("left", hl.dsp.focus({ direction = "left" }))
  tmuxSticky("right", hl.dsp.focus({ direction = "right" }))
  tmuxSticky("up", hl.dsp.focus({ direction = "up" }))
  tmuxSticky("down", hl.dsp.focus({ direction = "down" }))
  -- CTRL-held arrows so holding CTRL across the chain still moves
  tmuxSticky("CTRL + left", hl.dsp.focus({ direction = "left" }))
  tmuxSticky("CTRL + right", hl.dsp.focus({ direction = "right" }))
  tmuxSticky("CTRL + up", hl.dsp.focus({ direction = "up" }))
  tmuxSticky("CTRL + down", hl.dsp.focus({ direction = "down" }))
  -- vim-style h/l (parity with hyprland.conf): sticky + CTRL variants
  tmuxSticky("h", hl.dsp.focus({ direction = "left" }))
  tmuxSticky("l", hl.dsp.focus({ direction = "right" }))
  tmuxSticky("CTRL + h", hl.dsp.focus({ direction = "left" }))
  tmuxSticky("CTRL + l", hl.dsp.focus({ direction = "right" }))
  -- { / } — tmux { } swap-pane analogy: move/swap window left/right (sticky)
  -- Standard US { = SHIFT+[ . VIA dedicated { } keys may send braceleft/
  -- braceright with or without SHIFT, so bind every sym variant.
  local moveL = hl.dsp.window.move({ direction = "left" })
  local moveR = hl.dsp.window.move({ direction = "right" })
  local swapL = hl.dsp.window.swap({ direction = "left" })
  local swapR = hl.dsp.window.swap({ direction = "right" })
  for _, k in ipairs({ "SHIFT + bracketleft", "SHIFT + braceleft", "braceleft" }) do
    tmuxSticky(k, moveL, { repeating = true, description = "tmux: move window left ({)" })
  end
  for _, k in ipairs({ "SHIFT + bracketright", "SHIFT + braceright", "braceright" }) do
    tmuxSticky(k, moveR, { repeating = true, description = "tmux: move window right (})" })
  end
  for _, k in ipairs({ "CTRL + SHIFT + bracketleft", "CTRL + SHIFT + braceleft", "CTRL + braceleft" }) do
    tmuxSticky(k, swapL, { repeating = true, description = "tmux: swap window left (CTRL+{)" })
  end
  for _, k in ipairs({ "CTRL + SHIFT + bracketright", "CTRL + SHIFT + braceright", "CTRL + braceright" }) do
    tmuxSticky(k, swapR, { repeating = true, description = "tmux: swap window right (CTRL+})" })
  end
  -- M / U — tmux marked-pane analogue: mark window, drop it on this workspace.
  -- Lower + upper + explicit SHIFT variants so Ctrl+BackSpace M / Ctrl+BackSpace U work
  -- regardless of Caps/Shift sym handling (same reason as { / } above).
  for _, k in ipairs({ "m", "M", "SHIFT + m", "SHIFT + M" }) do
    tmuxBindFn(k, tmuxMark, "tmux: mark window (like tmux mark-pane)")
  end
  for _, k in ipairs({ "u", "U", "SHIFT + u", "SHIFT + U" }) do
    tmuxBindFn(k, tmuxDrop, "tmux: drop marked window here (like tmux join-pane)")
  end
  hl.bind("escape", function()
    tmux_super_armed = false
    disarmTmuxTimeout()
    hl.dispatch(hl.dsp.submap("reset"))
  end, { description = "tmux: exit prefix mode (Esc)" })
  -- Re-pressing the prefix mid-chain just re-arms/refreshes the 1s deadline,
  -- it never exits (exits are Esc, unbound key, Super tap, timeout). Cover
  -- Shift still held from a { / } press (Ctrl+Shift+BackSpace) so it never
  -- falls through into the app.
  for _, k in ipairs({ "CTRL + BackSpace", "CTRL + SHIFT + BackSpace" }) do
    hl.bind(k, function()
      tmuxGuard()
      hl.dispatch(hl.dsp.submap("tmux"))
      armTmuxTimeout()
    end)
  end
  -- Shift/Ctrl stays: lone presses are part of bound chords, so they must
  -- neither cancel nor CONSUME: a consumed modifier never registers
  -- server-side, and the chorded key would arrive modmask-less and miss its
  -- bind (this is what broke { }). non_consuming lets the modifier
  -- propagate; transparent + ignore_mods mirror the Super-tap arm recipe
  -- (also keeps modifier releases from tripping the catchall). The guard
  -- stamp tells the catchall below this press was handled.
  for _, k in ipairs({ "Shift_L", "Shift_R", "Control_L", "Control_R" }) do
    hl.bind(k, function()
      tmuxGuard()
      armTmuxTimeout()
    end, { non_consuming = true, ignore_mods = true, transparent = true,
      description = "tmux: hold Shift/Ctrl while chaining" })
  end
  -- Super inside tmux mode: cancel the chain immediately AND perform its
  -- own action. Raw tap toggles pibble; any SUPER+chord behaves exactly as
  -- if tmux mode wasn't armed (chord's global action fires, tap does not).
  -- Shape rationale (both verified live with real-evdev injection):
  -- - Press resets to default AT ONCE and arms BOTH flags, so a chorded key
  --   is evaluated globally: its action fires and the global SUPER+key
  --   disarm (which now also clears tmux_super_armed) kills tap intent with
  --   no timing dependence. A dedicated tmux flag is still required: release
  --   matching can resolve against the press-time submap, in which case only
  --   the tmux-local release is eligible; sharing one flag let the global
  --   release steal the tap instead. Exactly one path runs per release, and
  --   each path consumes only its own flag, so exactly one toggle fires.
  -- MUST stay before the catchall: press/release stamp the guard.
  for _, k in ipairs({ "Super_L", "Super_R", "Meta_L", "Meta_R" }) do
    hl.bind(k, function()
      tmuxGuard()
      disarmTmuxTimeout()
      hl.dispatch(hl.dsp.submap("reset"))
      super_tap_arm()
      tmux_super_armed = true
    end, { ignore_mods = true, transparent = true, non_consuming = true,
      description = "tmux: Super cancels chain (press)" })
    hl.bind(k, function()
      tmuxGuard()
      disarmTmuxTimeout()
      hl.dispatch(hl.dsp.submap("reset"))
      if tmux_super_armed then
        tmux_super_armed = false
        hl.dispatch(hl.dsp.exec_cmd("date +%s%3N > /tmp/supertap_tmux; /home/nicerice/src/pibble/pibble toggle"))
      end
    end, { release = true, ignore_mods = true, transparent = true,
      description = "tmux: Super tap toggles launcher" })
  end
  -- Cancel: any key with no other bind exits tmux mode. Non-consuming, so
  -- the cancelling keystroke still reaches the app (like tmux dropping its
  -- repeat). MUST stay the last bind in this submap: it executes after all
  -- real binds and skips the reset when one of them stamped the guard for
  -- this same keypress.
  hl.bind("catchall", function()
    if os.clock() - tmuxCatchGuardAt > 0.1 then
      tmux_super_armed = false
      disarmTmuxTimeout()
      hl.dispatch(hl.dsp.submap("reset"))
    end
  end, { non_consuming = true, description = "tmux: exit prefix mode on any unbound key" })
end)

-- Desktop toggle: F15 globally (keyboard-independent) -> kmscon tty1
-- Close pibble first: a VT switch while the launcher is open strands its
-- open state (stuck fullscreen blur on return), so park it before leaving.
hl.bind("F15", hl.dsp.exec_cmd("qs -p /home/nicerice/src/pibble ipc -n call launcher close 2>/dev/null; exec /usr/local/bin/desktop-toggle"))
hl.bind("code:185", hl.dsp.exec_cmd("qs -p /home/nicerice/src/pibble ipc -n call launcher close 2>/dev/null; exec /usr/local/bin/desktop-toggle"))
hl.bind("CTRL + ALT + T", hl.dsp.exec_cmd("qs -p /home/nicerice/src/pibble ipc -n call launcher close 2>/dev/null; exec /usr/local/bin/desktop-toggle"))
hl.bind("CTRL + ALT + F1", hl.dsp.exec_cmd("qs -p /home/nicerice/src/pibble ipc -n call launcher close 2>/dev/null; exec sudo chvt 1"))
hl.bind(mod .. " + SHIFT + E", hl.dsp.exec_cmd("exec /usr/local/bin/desktop-toggle --stop"))

-- persistent custom hotkeys (survives regeneration) - SUPER+CTRL+left/right = workspace
pcall(function() dofile(os.getenv("HOME") .. "/.config/hypr/custom.lua") end)

-- Window rules (example)
-- hl.window_rule({ name = "float pavucontrol", match = { class = "pavucontrol" }, float = true })

-- Kitty liquid glass: kitty draws its own background alpha
-- (background_opacity in kitty.conf) and the liquid-glass-hypr plugin draws
-- real refraction glass behind it. No Hyprland opacity rule on purpose (that
-- would fade text too); rounding feeds the glass corners; no_blur because
-- the plugin owns the backdrop blur (the compositor pass would frost OVER
-- the refraction and bury it). Named rule = survives reloads (eval-applied
-- rules do not: every matugen wallpaper switch reloads and wipes them).
hl.window_rule({ name = "kitty-glass", match = { class = "kitty" }, rounding = 16, no_blur = true })

-- Zen liquid glass: same takeover as kitty — Zen must be translucent
-- (zen.widget.linux.transparency + browser.tabs.allow_transparent_browser +
-- Nebula contrast 0 + semi-transparent glass colors) so the plugin's
-- refraction shows through. no_blur: compositor blur would frost OVER the
-- refraction. Class is "zen" (covers zen-browser). Note: plugin skips
-- fullscreen-coverage windows, so maximized Zen falls back to native blur.
hl.window_rule({ name = "zen-glass", match = { class = "zen" }, rounding = 16, no_blur = true })

-- liquid-glass-hypr plugin keys intentionally NOT set via hl.config here:
-- the plugin registers them at load time, so setting them statically
-- triggers "unknown config key 'plugin.liquidglass.*'" on (re)load/verify
-- before the plugin is loaded (hyprland.lua:514). The plugin's compiled
-- defaults already match (windows="kitty,zen",
-- window_tint_file="~/.config/kitty/matugen-colors.conf" in
-- src/liquid-glass-hypr/src/Config.cpp), and live tuning goes through
-- ~/.config/quickshell/lucidprefs/prefs.json, so nothing is lost.

-- Matugen generated colors -- uniform palette from wallpaper
pcall(function()
  local f = io.open(os.getenv("HOME") .. "/.config/hypr/colors.lua", "r")
  if f then
    f:close()
    local colors = dofile(os.getenv("HOME") .. "/.config/hypr/colors.lua")
    if colors and colors.accent then
      hl.config({
        general = {
          col = {
            active_border = { colors = { "rgba(" .. colors.accent:gsub("#","") .. "ff)", "rgba(" .. (colors.accent2 or colors.accent):gsub("#","") .. "ff)" }, angle = 45 },
            inactive_border = "rgba(" .. colors.inactive:gsub("#","") .. "aa)",
          }
        }
      })
    end
  end
end)

-- Lucid: no distinct active window border — the active window is signalled
-- by glass glow instead (liquid-glass-hypr window_active_glow). Single dim
-- color, so active windows also take the static border path. Placed after
-- the matugen block so it wins on every (re)load, wallpaper switches
-- included (they regenerate colors.lua and reload).
pcall(function()
  local f = io.open(os.getenv("HOME") .. "/.config/hypr/colors.lua", "r")
  if f then
    f:close()
    local colors = dofile(os.getenv("HOME") .. "/.config/hypr/colors.lua")
    if colors and colors.inactive then
      hl.config({
        general = {
          col = {
            active_border = "rgba(" .. colors.inactive:gsub("#", "") .. "aa)",
          }
        }
      })
    end
  end
end)


-- Lucid capture - hyprglass data path for quickshell (image data only, our shader does visuals)
if hl.plugin.hyprglass then
  local hg = hl.plugin.hyprglass
  hg.config({
    blur_strength = 2.0,
    blur_iterations = 1,
    layers = { enabled = 1 },
  })
  hg.layer("quickshell", { mask_threshold = 0.001 })
end
-- Also try lucid-capture name (if plugin renamed)
if hl.plugin["lucid-capture"] then
  local lc = hl.plugin["lucid-capture"]
  lc.config({
    blur_strength = 2.0,
    blur_iterations = 1,
    layers = { enabled = 1 },
  })
  lc.layer("quickshell", { mask_threshold = 0.001 })
end

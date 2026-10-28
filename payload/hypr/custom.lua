-- custom.lua - persistent lua hotkeys, sourced by hyprland.lua
CUSTOM_LUA_EDP_GRID = true
-- SUPER+left/right = focus, SUPER+CTRL+left/right + SUPER+ALT+left/right = workspace grid (10/20/30 fall back to numeric neighbours)
hl.bind("SUPER + left", hl.dsp.focus({ direction = "left" }))
hl.bind("SUPER + right", hl.dsp.focus({ direction = "right" }))
hl.bind("SUPER + H", hl.dsp.focus({ direction = "left" }))
hl.bind("SUPER + L", hl.dsp.focus({ direction = "right" }))
hl.bind("SUPER + CTRL + left", function() gridHorizontal(-1) end)
hl.bind("SUPER + CTRL + right", function() gridHorizontal(1) end)
hl.bind("SUPER + CTRL + H", function() gridHorizontal(-1) end)
hl.bind("SUPER + CTRL + L", function() gridHorizontal(1) end)
-- SUPER+ALT+left/right = row-local horizontal (5 wide, wraps). Workspaces
-- outside the grid (10/20/30) fall back to numeric neighbours so the internal
-- eDP-1 panel stays navigable when the DP-1/2/3 monitors are disconnected.
-- Workspace slide direction: horizontal moves slide, vertical moves slidevert.
-- Matches Hyprgrid (parseKeyword animation workspaces ... slide/slidevert).
-- Same speed/bezier as hyprland.lua so only the style flips, no full reload.
-- Directional slide styles: the engine parses the suffix (left/right/top/bottom)
-- as the edge the incoming workspace slides in from (WorkspaceAnimationController).
-- right: target is right of current, left: target is left,
-- bottom: target is below, top: target is above.
-- (Companion mode: stock slide owns motion; the goo plugin adds only
-- per-window fade + scale with its own motion zeroed, so steering this style
-- per jump is safe again and never double-applies.)
local function setWsStyle(style)
  pcall(function()
    hl.animation({ leaf = "workspaces", enabled = true, speed = 4.43, bezier = "default", style = style })
  end)
end
-- Workspace -> monitor, mirroring the workspace_rule list in hyprland.lua.
local WS_MON = {}
for _, id in ipairs({1,2,3,11,12,13,21,22,23,31,32,33,34,35,36}) do WS_MON[id] = "DP-1" end
for _, id in ipairs({4,5,6,14,15,16,24,25,26,37,38,39,40,41,42}) do WS_MON[id] = "DP-2" end
for _, id in ipairs({7,8,9,17,18,19,27,28,29,43,44,45,46,47,48}) do WS_MON[id] = "DP-3" end
-- Monitor layout west -> east (see hyprland.lua monitor positions).
local MON_X = { ["DP-2"] = 0, ["DP-1"] = 1600, ["DP-3"] = 3200 }
function perMonitorWorkspace(dir)
  local mon = nil
  pcall(function() mon = hl.get_monitor_at_cursor() end)
  if not mon then pcall(function() mon = hl.get_active_monitor() end) end
  if not mon then
    setWsStyle(dir > 0 and "slide right" or "slide left")
    hl.dispatch(hl.dsp.focus({ workspace = dir > 0 and "m+1" or "m-1" }))
    return
  end
  -- Ensure the selected monitor is the active one before doing m+1/m-1
  local curMon = nil
  pcall(function() curMon = hl.get_active_monitor() end)
  if curMon and curMon.name ~= mon.name then
    hl.dispatch(hl.dsp.focus({ monitor = mon.name }))
  end
  -- Explicit target on this monitor (sorted id order, wrapping) instead of
  -- m+1/m-1, so the pre-steer below and the workspace.active handler
  -- compute the same style from the same pair.
  local cur = nil
  pcall(function()
    local w = hl.get_active_workspace(mon)
    if w then cur = w.id end
  end)
  local target = nil
  if cur and WS_MON[cur] == mon.name then
    local ids = {}
    for id, m in pairs(WS_MON) do
      if m == mon.name then ids[#ids + 1] = id end
    end
    table.sort(ids)
    for i, id in ipairs(ids) do
      if id == cur then
        target = ids[((i - 1 + dir) % #ids) + 1]
        break
      end
    end
  end
  if target then
    steerWsJump(cur, target)
    hl.dispatch(hl.dsp.focus({ workspace = tostring(target) }))
  else
    setWsStyle(dir > 0 and "slide right" or "slide left")
    hl.dispatch(hl.dsp.focus({ workspace = dir > 0 and "m+1" or "m-1" }))
  end
  pcall(function()
    local f = io.open("/tmp/perMonitorWorkspace.log","a")
    if f then
      local curMon2 = hl.get_monitor_at_cursor()
      local actMon2 = hl.get_active_monitor()
      local curWs = hl.get_active_workspace(mon)
      f:write(string.format("%s dir=%d mon=%s curWs=%s cursorMon=%s activeMon=%s\n",
        os.date("%H:%M:%S"), dir, mon.name, curWs and tostring(curWs.id) or "nil",
        curMon2 and curMon2.name or "nil",
        actMon2 and actMon2.name or "nil"))
      f:close()
    end
  end)
end
hl.bind("SUPER + ALT + left", function() gridHorizontal(-1) end)
hl.bind("SUPER + ALT + right", function() gridHorizontal(1) end)
hl.bind("SUPER + ALT + H", function() gridHorizontal(-1) end)
hl.bind("SUPER + ALT + L", function() gridHorizontal(1) end)
hl.bind("SUPER + ALT + SHIFT + left", function() gridMoveHorizontal(-1) end)
hl.bind("SUPER + ALT + SHIFT + right", function() gridMoveHorizontal(1) end)
hl.bind("SUPER + ALT + SHIFT + H", function() gridMoveHorizontal(-1) end)
hl.bind("SUPER + ALT + SHIFT + L", function() gridMoveHorizontal(1) end)

-- Real grid: 5 wide x 3 tall per monitor (15 per monitor, 45 total).
-- DP-1 r0: 1,2,3,31,32 | r1: 11,12,13,33,34 | r2: 21,22,23,35,36
-- DP-2 r0: 4,5,6,37,38 | r1: 14,15,16,39,40 | r2: 24,25,26,41,42
-- DP-3 r0: 7,8,9,43,44 | r1: 17,18,19,45,46 | r2: 27,28,29,47,48
-- left/right wraps within row, up/down wraps within column. 10/20/30 stay free.
local GRID_ROWS = {
  {1,2,3,31,32}, {11,12,13,33,34}, {21,22,23,35,36},
  {4,5,6,37,38}, {14,15,16,39,40}, {24,25,26,41,42},
  {7,8,9,43,44}, {17,18,19,45,46}, {27,28,29,47,48},
}
local WS_POS = {}
for ri, row in ipairs(GRID_ROWS) do
  for ci, id in ipairs(row) do
    WS_POS[id] = { r = ri, c = ci, n = #row }
  end
end
-- Solo internal-panel grid. With no DP monitors connected, Hyprland has no
-- rule for eDP-1 and creates only the free workspace 10. Use a dedicated 5x3
-- block starting at 10 so the first jump (10 -> 11) can be reversed.
local EDP_ROWS = {
  {10,11,12,13,14},
  {20,21,22,23,24},
  {30,31,32,33,34},
}
local EDP_POS, EDP_DOWN, EDP_UP = {}, {}, {}
for ri, row in ipairs(EDP_ROWS) do
  for ci, id in ipairs(row) do
    EDP_POS[id] = { r = ri, c = ci, n = #row }
    EDP_DOWN[id] = EDP_ROWS[(ri % #EDP_ROWS) + 1][ci]
    EDP_UP[id] = EDP_ROWS[((ri - 2) % #EDP_ROWS) + 1][ci]
  end
end
function soloEDP()
  local mon, mons = nil, nil
  pcall(function() mon = hl.get_active_monitor() end)
  pcall(function() mons = hl.get_monitors() end)
  return mon ~= nil and mon.name == "eDP-1" and mons ~= nil and #mons == 1
end
-- One steering function for every path: keybinds pre-steer with it before
-- dispatch AND the workspace.active handler below re-steers from the actual
-- from->to pair, so both always agree and can never fight. Global (no
-- local) so hyprland.lua's tmux binds can pre-steer with it too.
-- (WS_MON/MON_X live above perMonitorWorkspace - lexical scope - while this
-- needs WS_POS too, so it sits down here past the grid tables.)
function steerWsJump(fromId, toId)
  if not fromId or not toId or fromId == toId then return end
  local solo = soloEDP()
  local posMap = solo and EDP_POS or WS_POS
  local pa, pb = posMap[fromId], posMap[toId]
  if not pa or not pb then return end
  local style = nil
  local ma = not solo and WS_MON[fromId] or nil
  local mb = not solo and WS_MON[toId] or nil
  if ma and mb and ma ~= mb then
    style = (MON_X[mb] or 0) > (MON_X[ma] or 0) and "slide right" or "slide left"
  elseif pa.r == pb.r then
    -- every row is 5 wide: a same-row jump landing 4 columns over is a wrap
    -- (32 -> 1, 7 -> 44). Wraps continue the press direction filmstrip-style
    -- (from the right end -> right), matching the historical feel; anything
    -- shorter is positional (== the press direction anyway).
    if math.abs(pb.c - pa.c) == (pa.n or 5) - 1 then
      style = pa.c > pb.c and "slide right" or "slide left"
    else
      style = pb.c > pa.c and "slide right" or "slide left"
    end
  elseif pa.c == pb.c then
    -- every column is 3 tall: same deal vertically (21 -> 1 keeps sliding
    -- down, 1 -> 21 keeps sliding up).
    if math.abs(pb.r - pa.r) > 1 then
      style = pa.r > pb.r and "slidevert bottom" or "slidevert top"
    else
      style = pb.r > pa.r and "slidevert bottom" or "slidevert top"
    end
  else
    -- diagonal jump on one monitor: no cardinal slide fits, so don't fake
    -- one - fade instead and let the goo grow carry it (direction-neutral,
    -- never a misleading axis).
    style = "fade"
  end
  setWsStyle(style)
  -- TEMPORARY trace (remove with the handler trace below).
  pcall(function()
    local f = io.open("/tmp/ws-steer.log", "a")
    if f then
      f:write(string.format("%s steer %s -> %s : %s\n", os.date("%H:%M:%S"), tostring(fromId), tostring(toId), style))
      f:close()
    end
  end)
end
-- Catch-all steering: every switch recomputes its style from the actual
-- from->to workspaces, so paths that never pre-steer (bar workspace clicks,
-- app-focus jumps, e+1/e-1) stop inheriting stale directions.
-- Baseline tracked PER MONITOR: interleaved switches on different monitors
-- must not pair with each other.
local lastWsByMon = {}
hl.on("workspace.active", function(...)
  local newId = nil
  local first = ...
  -- HL.Workspace arrives as userdata (tostring "HL.Workspace(2:2)"), not a
  -- plain table - but property access works the same.
  if type(first) == "table" or type(first) == "userdata" then
    pcall(function() newId = first.id end)
    if not newId then
      pcall(function() newId = first.workspaceId end)
    end
    if not newId then
      pcall(function() newId = first.workspace_id end)
    end
  elseif type(first) == "number" then
    newId = first
  elseif type(first) == "string" then
    newId = tonumber(first) or tonumber(string.match(first, "%((%d+):") or string.match(first, "%d+"))
  end
  if not newId then
    -- unknown payload shape: the new workspace is already active by the
    -- time this runs, so read it directly.
    pcall(function()
      local w = hl.get_active_workspace()
      if w then newId = w.id end
    end)
  end
  if type(newId) == "string" then newId = tonumber(newId) end
  if newId and newId ~= 0 then
    local mon = WS_MON[newId]
    local prev = mon and lastWsByMon[mon] or nil
    if prev and prev ~= newId then steerWsJump(prev, newId) end
    if mon then lastWsByMon[mon] = newId end
  end
  -- TEMPORARY trace (remove once directions are confirmed): payload shape
  -- plus the decision, so the log shows what each switch computed.
  pcall(function()
    local f = io.open("/tmp/ws-steer.log", "a")
    if f then
      local pdesc = type(first) == "table" and ("table id=" .. tostring(first.id)) or tostring(first)
      f:write(string.format("%s payload=%s new=%s\n", os.date("%H:%M:%S"), pdesc, tostring(newId)))
      f:close()
    end
  end)
end)
local GRID_DOWN = { [1]=11, [2]=12, [3]=13, [4]=14, [5]=15, [6]=16, [7]=17, [8]=18, [9]=19,
  [11]=21, [12]=22, [13]=23, [14]=24, [15]=25, [16]=26, [17]=27, [18]=28, [19]=29,
  [21]=1, [22]=2, [23]=3, [24]=4, [25]=5, [26]=6, [27]=7, [28]=8, [29]=9,
  [31]=33, [33]=35, [35]=31, [32]=34, [34]=36, [36]=32,
  [37]=39, [39]=41, [41]=37, [38]=40, [40]=42, [42]=38,
  [43]=45, [45]=47, [47]=43, [44]=46, [46]=48, [48]=44 }
local GRID_UP = { [11]=1, [12]=2, [13]=3, [14]=4, [15]=5, [16]=6, [17]=7, [18]=8, [19]=9,
  [21]=11, [22]=12, [23]=13, [24]=14, [25]=15, [26]=16, [27]=17, [28]=18, [29]=19,
  [1]=21, [2]=22, [3]=23, [4]=24, [5]=25, [6]=26, [7]=27, [8]=28, [9]=29,
  [33]=31, [35]=33, [31]=35, [34]=32, [36]=34, [32]=36,
  [39]=37, [41]=39, [37]=41, [40]=38, [42]=40, [38]=42,
  [45]=43, [47]=45, [43]=47, [46]=44, [48]=46, [44]=48 }
-- Free row anchors 10/20/30 (outside the 45-cell grid): wrap vertically as a
-- 3-row column so the internal panel still has a working up/down pair.
local FALLBACK_DOWN = { [10]=20, [20]=30, [30]=10 }
local FALLBACK_UP   = { [10]=30, [20]=10, [30]=20 }
-- Pick the grid for the current setup: solo eDP-1 gets its own block; any
-- docked/multi-monitor layout keeps the original 45-cell DP grid.
function activeGrid()
  if soloEDP() then return EDP_ROWS, EDP_POS, EDP_DOWN, EDP_UP end
  return GRID_ROWS, WS_POS, GRID_DOWN, GRID_UP
end
function gridHorizontal(dir)
  local ws = nil
  pcall(function() ws = hl.get_active_workspace() end)
  if not ws or not ws.id then return end
  local rows, posMap = activeGrid()
  local pos = posMap[ws.id]
  if not pos then
    -- 10/20/30 are outside the grid. When only the internal panel is
    -- connected (eDP-1), the DP-1/2/3 workspace rules leave workspace 10 as
    -- the only workspace, and perMonitorWorkspace's m+1/m-1 only cycles
    -- EXISTING workspaces (it never creates one), so navigation was a
    -- no-op. Absolute dispatch creates the numeric neighbour even if its
    -- rule names a disconnected DP monitor.
    local target = ws.id + dir
    if target > 0 then
      hl.dispatch(hl.dsp.focus({ workspace = tostring(target) }))
    end
    return
  end
  local row = rows[pos.r]
  local nc = ((pos.c - 1 + dir) % pos.n) + 1
  steerWsJump(ws.id, row[nc])
  hl.dispatch(hl.dsp.focus({ workspace = tostring(row[nc]) }))
end
function gridMoveHorizontal(dir)
  local ws = nil
  pcall(function() ws = hl.get_active_workspace() end)
  if not ws or not ws.id then return end
  local rows, posMap = activeGrid()
  local pos = posMap[ws.id]
  if not pos then return end
  local row = rows[pos.r]
  local nc = ((pos.c - 1 + dir) % pos.n) + 1
  steerWsJump(ws.id, row[nc])
  hl.dispatch(hl.dsp.window.move({ workspace = tostring(row[nc]), follow = true }))
end
function gridVertical(dir)
  local ws = nil
  pcall(function() ws = hl.get_active_workspace() end)
  if not ws or not ws.id then return end
  local _, _, down, up = activeGrid()
  local target = dir > 0 and down[ws.id] or up[ws.id]
  if not target then
    -- Same laptop-only fallback as gridHorizontal: move a row numerically
    -- (10 <-> 20 <-> 30 wraps) instead of doing nothing outside the grid.
    local nid = (dir > 0 and FALLBACK_DOWN or FALLBACK_UP)[ws.id]
      or (ws.id + dir * 10)
    if nid > 0 then
      hl.dispatch(hl.dsp.focus({ workspace = tostring(nid) }))
    end
    return
  end
  steerWsJump(ws.id, target)
  hl.dispatch(hl.dsp.focus({ workspace = tostring(target) }))
end
function gridMoveVertical(dir)
  local ws = nil
  pcall(function() ws = hl.get_active_workspace() end)
  if not ws or not ws.id then return end
  local _, _, down, up = activeGrid()
  local target = dir > 0 and down[ws.id] or up[ws.id]
  if not target then return end
  steerWsJump(ws.id, target)
  hl.dispatch(hl.dsp.window.move({ workspace = tostring(target), follow = true }))
end
hl.bind("SUPER + ALT + down", function() gridVertical(1) end)
hl.bind("SUPER + ALT + up", function() gridVertical(-1) end)
hl.bind("SUPER + ALT + J", function() gridVertical(1) end)
hl.bind("SUPER + ALT + K", function() gridVertical(-1) end)
hl.bind("SUPER + ALT + SHIFT + down", function() gridMoveVertical(1) end)
hl.bind("SUPER + ALT + SHIFT + up", function() gridMoveVertical(-1) end)
hl.bind("SUPER + ALT + SHIFT + J", function() gridMoveVertical(1) end)
hl.bind("SUPER + ALT + SHIFT + K", function() gridMoveVertical(-1) end)

-- Volume controls: pactl via pulse-native (wpctl/PipeWire-native currently wedged:
-- `wpctl status` empty + `get-volume` hangs 120s, while `pactl` works).
-- Use @DEFAULT_SINK@/@DEFAULT_SOURCE@ so XM6/ALC897 switching keeps working.
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("pactl set-sink-volume @DEFAULT_SINK@ +5%"), { repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("pactl set-sink-volume @DEFAULT_SINK@ -5%"), { repeating = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("pactl set-sink-mute @DEFAULT_SINK@ toggle"))
hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("pactl set-source-mute @DEFAULT_SOURCE@ toggle"))
-- Fallback with pactl for OSD consistency (also triggers dunst via wpctl if needed)
hl.bind("SUPER + XF86AudioRaiseVolume", hl.dsp.exec_cmd("pactl set-sink-volume @DEFAULT_SINK@ +5%"))
hl.bind("SUPER + XF86AudioLowerVolume", hl.dsp.exec_cmd("pactl set-sink-volume @DEFAULT_SINK@ -5%"))

-- Screenshot: Print = region + freeze + clipboard-only silent (no notification)
hl.bind("Print", hl.dsp.exec_cmd("hyprshot -m region --freeze --clipboard-only --silent"))

-- F16 = open kitty (single press, no modifier — mirrors F15 desktop-toggle pattern)
-- kb_variant ",phonetic_winkeys" (via the inet evdev symbols) remaps FK13-FK20:
--   key <FK16> { [ XF86Launch7 ] };
-- so the physical F16 key never emits the F16 keysym. Bind the keysym the
-- keymap actually emits. Do NOT use "code:NN": Hyprland 0.56.2's Lua bind
-- parser turns any "code:" spec into an empty-key bind (key="", keycode=0),
-- which matches KEY_UNKNOWN events (e.g. Xbox Elite paddles).
hl.bind("XF86Launch7", hl.dsp.exec_cmd("kitty"))
hl.bind("F16", hl.dsp.exec_cmd("kitty"))
-- F17 = open nautilus (same keymap remap: FK17 = XF86Launch8)
hl.bind("XF86Launch8", hl.dsp.exec_cmd("nautilus --new-window"))
hl.bind("F17", hl.dsp.exec_cmd("nautilus --new-window"))

-- Urgency focus guard: no activation focus-steal within 5s of input.
-- misc:focus_on_activate=false means activation requests (urgent hints,
-- terminal bells, link-openings) only flag the window urgent, never steal
-- focus. This guard restores the old Windows-style jump, but ONLY when you
-- have been idle for 5s: on window.urgent it focuses the requester iff no
-- key press, mouse button, or pointer motion landed in the last 5s.
-- Otherwise the urgent flag stays and you jump manually. Every focus change
-- is logged with its reason (see FOCUS_REASONS) to /tmp/urgency-guard.log,
-- so a steal that still happens while armed leaves a trace of its path.
local URGENCY_GUARD_MS = 5000
local urgencyGuardGen = 0
local urgencyGuardArmed = false
local urgencyGuardLastSrc = nil
local urgencyGuardLastDecision = "-"
-- Focus reasons from src/desktop/state/FocusState.hpp (2nd arg of window.active).
local URGENCY_GUARD_REASONS = {
  [0]="UNKNOWN",[1]="FFM",[2]="KEYBIND",[3]="DISPATCH_FOCUSWINDOW",
  [4]="DISPATCH_MOVEWINDOWINTOGROUP",[5]="CLICK",[6]="OTHER",
  [7]="DESKTOP_STATE_CHANGE",[8]="SWITCH_TO_WINDOW_SOFT",[9]="SWITCH_TO_WINDOW_HARD",
  [10]="GROUP_CURRENT_WINDOW_CHANGE",[11]="WORKSPACE_CHANGE",
  [12]="TOGGLE_SPECIAL_WORKSPACE",[13]="UNMAP_WINDOW_TILING",
  [14]="UNMAP_WINDOW_FLOATING",[15]="UNMAP_GROUPED_WINDOW",
  [16]="NEW_WINDOW",[17]="GHOSTS",
}
local function urgencyGuardLog(msg)
  pcall(function()
    local f = io.open("/tmp/urgency-guard.log", "a")
    if f then
      f:write(string.format("%s %s\n", os.date("%H:%M:%S"), msg))
      f:close()
    end
  end)
end
local function urgencyGuardSet(armed, why)
  if urgencyGuardArmed == armed then return end
  urgencyGuardArmed = armed
  urgencyGuardLog(armed and ("armed (recent input"
    .. (urgencyGuardLastSrc and ": " .. urgencyGuardLastSrc or "") .. ")")
    or ("disarmed (idle" .. (why and ": " .. why or "") .. ")"))
end
-- Global (no local) so it can be exercised via `hyprctl eval`:
--   hyprctl eval 'urgencyGuardNoteInput("test")'
function urgencyGuardNoteInput(src)
  if src ~= nil then urgencyGuardLastSrc = src end
  urgencyGuardSet(true)
  urgencyGuardGen = urgencyGuardGen + 1
  local gen = urgencyGuardGen
  hl.timer(function() urgencyGuardOnTimeout(gen) end,
    { timeout = URGENCY_GUARD_MS, type = "oneshot" })
end
-- Split out (not inlined in the timer closure) so the expiry branches can be
-- tested deterministically: hyprctl eval 'urgencyGuardOnTimeout(<gen>)'
-- with a stale gen must no-op, with the current gen must disarm.
function urgencyGuardOnTimeout(gen)
  if gen == urgencyGuardGen then urgencyGuardSet(false, "timeout") end
end
-- The decision, extracted for testing: hyprctl eval 'urgencyGuardShouldFocus()'
-- returns false while armed (recent input), true when idle.
function urgencyGuardShouldFocus()
  return not urgencyGuardArmed
end
-- Observability: appends "status armed=.. gen=.. last=.." to the log.
-- Usage: hyprctl eval 'urgencyGuardStatus()'; cat /tmp/urgency-guard.log
function urgencyGuardStatus()
  urgencyGuardLog(string.format("status armed=%s gen=%d last=%s",
    tostring(urgencyGuardArmed), urgencyGuardGen, urgencyGuardLastDecision))
end
-- Activation requests land here. Idle: focus the requester (old behavior,
-- including workspace jump). Armed: leave it flagged urgent, log and ignore.
pcall(function()
  hl.on("window.urgent", function(w)
    local ok, cls, title, addr = pcall(function()
      return w.class, w.title, w.address
    end)
    if not ok then cls, title, addr = "?", "?", nil end
    if urgencyGuardShouldFocus() then
      -- Already there: nothing to do (avoids a redundant jump/warp).
      local cur = nil
      pcall(function()
        local a = hl.get_active_window()
        if a then cur = a.address end
      end)
      if addr and cur == addr then
        urgencyGuardLastDecision = "urgent-already-active"
        urgencyGuardLog(string.format("urgent already-active %s | %s", tostring(cls), tostring(title)))
        return
      end
      urgencyGuardLastDecision = "focused-idle-urgent"
      urgencyGuardLog(string.format("urgent FOCUS (idle) %s | %s", tostring(cls), tostring(title)))
      if addr then
        pcall(function()
          hl.dispatch(hl.dsp.focus({ window = "address:" .. addr }))
        end)
      end
    else
      urgencyGuardLastDecision = "ignored-armed-urgent"
      urgencyGuardLog(string.format("urgent IGNORED (armed) %s | %s", tostring(cls), tostring(title)))
    end
  end)
end)
-- Steal detector: every focus change with its reason and the armed state.
pcall(function()
  hl.on("window.active", function(w, reason)
    local ok, cls, title = pcall(function() return w.class, w.title end)
    if not ok then cls, title = "?", "?" end
    local rname = URGENCY_GUARD_REASONS[reason] or tostring(reason)
    urgencyGuardLog(string.format("focus -> %s | %s reason=%s armed=%s",
      tostring(cls), tostring(title), rname, tostring(urgencyGuardArmed)))
  end)
end)
-- Test hook: hyprctl eval 'urgencyGuardOnKey(30, 0, 1)'
-- input.keyboard.key payload: keycode, unix-ms timestamp, 0=release/1=press/2=repeat.
-- Any key event (press, repeat, release) counts as activity - no state check
-- so the guard can't silently break if the payload order ever changes.
function urgencyGuardOnKey(keycode, timeMs, state)
  urgencyGuardNoteInput("key")
end
pcall(function()
  hl.on("input.keyboard.key", urgencyGuardOnKey)
end)
-- Mouse buttons + scroll also count as input. Transparent + non-consuming so
-- clicks/scrolls pass through to windows and other binds untouched; we only
-- observe. Each bind is independent so one bad name can't break the rest.
pcall(function()
  for _, b in ipairs({ "mouse:272", "mouse:273", "mouse:274", "mouse:275",
                       "mouse:276", "mouse:277", "mouse:278", "mouse:279",
                       "mouse_up", "mouse_down" }) do
    pcall(function()
      hl.bind(b, function() urgencyGuardNoteInput("button") end, { mouse = true, transparent = true,
        non_consuming = true, description = "urgency-guard: observe input (" .. b .. ")" })
    end)
  end
end)
-- Pointer motion also counts as input: a steal must never yank the workspace
-- / cursor from under a moving mouse. hl.on has no motion event, so poll the
-- cursor position 4x/sec. >3px since the last tick = intentional movement
-- (ignores sensor jitter). First tick only stores the baseline.
-- Test hook: hyprctl eval 'urgencyGuardNoteMotion(100, 100)'
local urgencyGuardLastCursor = nil
function urgencyGuardNoteMotion(x, y)
  if type(x) ~= "number" or type(y) ~= "number" then return end
  local last = urgencyGuardLastCursor
  urgencyGuardLastCursor = { x = x, y = y }
  if not last then return end
  local dx, dy = x - last.x, y - last.y
  if dx * dx + dy * dy > 9 then
    urgencyGuardNoteInput("motion")
  end
end
pcall(function()
  hl.timer(function()
    pcall(function()
      local p = hl.get_cursor_pos()
      if p and type(p.x) == "number" and type(p.y) == "number" then
        urgencyGuardNoteMotion(p.x, p.y)
      end
    end)
  end, { timeout = 250, type = "repeat" })
end)

-- liquid-glass-toggle persistence (see /usr/local/bin/liquid-glass-toggle).
-- prefs.json is the source of truth for both independent switches:
--   liquidGlassEnabled   -> plugin:liquidglass:enabled (bar/dock/OSD/windows)
--   gooWorkspacesEnabled -> plugin:gooworkspaces:enabled (workspace morph)
-- They are independent: goo works with glass off, and glass works with goo off.
-- NEVER `hyprctl plugin unload` here: unload SEGVs (see hyprland.lua).
local function applyGlassGooState()
  local glassOff, gooOff = false, false
  pcall(function()
    local home = os.getenv("HOME") or "/home/nicerice"
    local f = io.open(home .. "/.config/quickshell/lucidprefs/prefs.json", "r")
    if f then
      local text = f:read("*a") or ""
      f:close()
      if text:match('"liquidGlassEnabled"%s*:%s*false') then glassOff = true end
      if text:match('"gooWorkspacesEnabled"%s*:%s*false') then gooOff = true end
    end
  end)
  local glassEn = glassOff and 0 or 1
  local gooEn = (not gooOff) and 1 or 0
  pcall(function() hl.config({ plugin = { liquidglass = { enabled = glassEn } } }) end)
  pcall(function() hl.config({ plugin = { gooworkspaces = { enabled = gooEn } } }) end)
end
pcall(applyGlassGooState)
pcall(function() hl.on("config.reloaded", applyGlassGooState) end)

-- Touch gestures (src/hypr-edge-swipe/hypr-touch-gestures.so):
--   * swipe inward or outward from any edge -> workspace in that direction
--     on the 5x3 grid; a swipe from the interior toward an edge goes the
--     opposite way; the workspace follows the finger and slides back if
--     released early
--   * corner launcher gestures are disabled (Pibble off 2026-10-27;
--     source kept in ~/src/pibble)
--   * pinch out on a window -> live resize, then maximize; again -> fullscreen
--   * pinch in -> fullscreen -> maximized -> normal, or a smaller float
--   * drag on a window -> double-tap, then drag with the second touch; a
--     single-finger drag stays with the app, and vertical scrolls briefly
--     pause drag arming; normal windows snap back into the tiling spot under
--     the drop point
-- This replaces the built-in `gestures:workspace_swipe_touch`. The native
-- path is motion-based (a right-bezel inward swipe targets m-1), cannot do
-- the workspace grid's up/down or wrapping, and needs >50% of the screen to
-- commit. Keep it off; the plugin handles the same hardware with edge-based
-- directions, vertical grid navigation and a 900 px full-travel distance.
pcall(function()
  hl.config({ gestures = { workspace_swipe_touch = false } })
end)
-- Pibble corner-open gesture off. This is belt-and-braces: the plugin keeps
-- its compiled default unless rebuilt, so the launcher entrypoint is also
-- non-executable on this machine.
pcall(function()
  hl.config({ plugin = { touch = { corner_enabled = 0 } } })
end)
hl.on("hyprland.start", function()
  hl.exec_cmd("hyprctl plugin list 2>/dev/null | grep -q hypr-touch-gestures || hyprctl plugin load /home/nicerice/src/hypr-edge-swipe/hypr-touch-gestures.so")
end)

-- Ignore maximize requests from all apps (stock Hyprland 0.56 rule).
-- Without this, apps that restore a maximized state (kitty, Zed, btop, ...)
-- open covering the whole workspace instead of just their dwindle tile.
-- Lives here (not hyprland.lua) so it survives config regeneration.
pcall(function()
  hl.window_rule({
    name = "suppress-maximize-events",
    match = { class = ".*" },
    suppress_event = "maximize",
  })
end)

-- >>> quick-translate >>>
-- SUPER+T opens Lucid's launcher on the Translate tab.
hl.bind("SUPER + T", hl.dsp.exec_cmd("qs ipc call launcher translate"), { description = "Translate (SUPER+T)" })
-- <<< quick-translate <<<

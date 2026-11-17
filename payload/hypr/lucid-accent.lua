-- lucid-accent.lua - long-press alternate spellings for the Lucid shell.
--
-- Hyprland does not emit key-repeat events (the `input.keyboard.key` event is
-- press/release only; repeat is implemented client-side from the seat's
-- repeat_info).  So the useful system fact is `input.repeat_delay`: after that
-- long a plain letter is either repeating or about to.
--
-- Two different things are wanted from that:
--
--   * stop the target app from spewing repeats while the key is held, and
--   * wait long enough that ordinary typing does not raise the picker.
--
-- For an unmodified lowercase letter we send a synthetic key release a little
-- before the app's first repeat.  The app sees one character and stops its
-- repeat timer; the physical key is still down, so there is no key-up yet.  At
-- LONG_PRESS_MS the picker is raised: the app already holds exactly one
-- character, so choosing a spelling removes one and inserts the variant.
-- Letting go before LONG_PRESS_MS simply leaves the one character, like a
-- normal press.
--
-- Shift/Caps are different: `send_key_state` also re-sends the modifier mask,
-- and its final clear would tell the app that Shift/Caps was released even
-- though the physical key is still held.  Those combinations therefore take
-- keyboard focus just before the first repeat instead (the app stops
-- repeating on focus loss), and the picker is raised immediately.  Since this
-- is only the upper-case path it is both rarer and invisible unless the key is
-- held past the repeat delay.
--
-- The request is a tiny JSON file in $XDG_RUNTIME_DIR because the global
-- shortcut carries no payload.  It is written atomically (tmp + rename)
-- before the dispatch.

local RUNTIME = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
local REQUEST = RUNTIME .. "/lucid-accent.json"

-- xkb keycodes that produce a letter in the configured layouts (US + RU
-- phonetic here; the union also covers the extra Cyrillic keys on the
-- number/punctuation row).  QS filters out the ones with no variants, so a
-- false candidate costs nothing until it is actually held.
local LETTER_CODES = {
  [12] = true, [13] = true, [14] = true, [15] = true, [21] = true,
  [24] = true, [25] = true, [26] = true, [27] = true, [28] = true,
  [29] = true, [30] = true, [31] = true, [32] = true, [33] = true,
  [34] = true, [35] = true,
  [38] = true, [39] = true, [40] = true, [41] = true, [42] = true,
  [43] = true, [44] = true, [45] = true, [46] = true,
  [49] = true, [51] = true,
  [52] = true, [53] = true, [54] = true, [55] = true, [56] = true,
  [57] = true, [58] = true,
}

local MOD_KEYS = {
  [37] = true, [105] = true, -- Control
  [64] = true, [108] = true, -- Alt
  [133] = true, [142] = true, -- Super / Meta
}
local CAPS_KEY = 66

-- A deliberate long-press.  Keeping it independent of input.repeat_delay is
-- what stops ordinary typing (and a held vim key) from raising the picker
-- after a 125 ms repeat delay.
local LONG_PRESS_MS = 300
-- How long before the app's repeat would start to release the key early.
-- This is an in-process dispatch, so a single frame of headroom is plenty.
local STOP_LEAD_MS = 20

local pending = nil
local blocked = nil
local down = {}
-- Seed from the wall clock so a config reload (which re-runs this file) can
-- never restart the sequence below a request the shell has already seen.
local seq = os.time() * 1000 + math.floor((os.clock() * 1000) % 1000)


local function held(name)
  local ok, v = pcall(hl.is_key_down, name)
  return ok and v == true
end

local function main_keyboard()
  local ok, devices = pcall(hl.get_devices)
  if not ok or type(devices) ~= "table" then
    return nil
  end
  local fallback = nil
  for _, d in ipairs(devices) do
    if d.type == "keyboard" then
      if d.main then return d end
      fallback = fallback or d
    end
  end
  return fallback
end

local function cancel()
  if not pending then return end
  pending.cancelled = true
  if pending.stopTimer then
    pcall(function() pending.stopTimer:set_enabled(false) end)
  end
  if pending.showTimer then
    pcall(function() pending.showTimer:set_enabled(false) end)
  end
  pending = nil
end

local function write_request(t)
  local tmp = REQUEST .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  local monitor = t.monitor or ""
  if monitor == "" then
    local okm, mon = pcall(hl.get_active_monitor)
    if okm and mon and mon.name then monitor = mon.name end
  end
  seq = seq + 1
  local payload = string.format(
    '{"seq":%d,"code":%d,"shift":%s,"caps":%s,"layout":%d,"press":%d,"delay":%d,"rate":%d,"leaks":%d,"mon":"%s"}',
    seq, t.code, t.shift and "true" or "false", t.caps and "true" or "false",
    t.layout, t.press, t.delay, t.rate, t.leaks or 0, monitor)
  f:write(payload)
  f:close()
  os.remove(REQUEST)
  return os.rename(tmp, REQUEST)
end

local function fire(t)
  if pending ~= t or t.cancelled then return end
  if not down[t.code] then
    cancel()
    return
  end
  -- the window that was being typed into must still be the active one
  local okWin, win = pcall(hl.get_active_window)
  if not okWin or not win or (t.winAddress ~= "" and win.address ~= t.winAddress) then
    cancel()
    return
  end
  -- a layer surface may have taken the keyboard while the key was held
  local okLayers, layers = pcall(hl.get_layers)
  if okLayers and type(layers) == "table" then
    for _, l in ipairs(layers) do
      if (l.keyboard_interactivity or 0) == 1 then
        cancel()
        return
      end
    end
  end

  pending = nil
  blocked = t.code
  if write_request(t) then
    pcall(function() hl.dispatch(hl.dsp.global("quickshell:accent")) end)
  end
end

local function on_key(code, time, state)
  if state == 0 then
    down[code] = false
    if blocked == code then blocked = nil end
    if pending and pending.code == code then
      cancel()
    end
    return
  end

  -- state == 1, a press
  down[code] = true

  if MOD_KEYS[code] then
    cancel()
    return
  end
  if code == CAPS_KEY then return end
  if blocked == code then return end

  -- another key went down while this one was waiting: chord, not a hold
  cancel()

  if not LETTER_CODES[code] then return end
  if held("Control_L") or held("Control_R")
     or held("Alt_L") or held("Alt_R")
     or held("Super_L") or held("Super_R")
     or held("Meta_L") or held("Meta_R") then
    return
  end

  local okSub, submap = pcall(hl.get_current_submap)
  if okSub and submap and submap ~= "" then return end
  -- a layer surface owns the keyboard (lock screen, launcher, widget panel,
  -- gate, or our own picker)
  local okLayers, layers = pcall(hl.get_layers)
  if okLayers and type(layers) == "table" then
    for _, l in ipairs(layers) do
      if (l.keyboard_interactivity or 0) == 1 then
        return
      end
    end
  end
  local okWin, win = pcall(hl.get_active_window)
  if not okWin or not win then return end
  -- native fullscreen text fields (browser, terminal) still work; games are
  -- filtered by class below
  local cls = string.lower(tostring(win.class or ""))
  if cls:find("gamescope") or cls:find("steam_app") or cls:find("wine") then return end

  local kb = main_keyboard()
  if not kb then return end

  local okDelay, delay = pcall(hl.get_config, "input.repeat_delay")
  local okRate, rate = pcall(hl.get_config, "input.repeat_rate")
  delay = okDelay and tonumber(delay) or 250
  rate = okRate and tonumber(rate) or 25
  if not delay or delay <= 0 or not rate or rate <= 0 then return end

  local shift = held("Shift_L") or held("Shift_R")
  local caps = kb.caps_lock == true
  local layout = tonumber(kb.active_layout_index) or 0
  -- Q has no precomposed spellings on the US layout.  Leave its normal
  -- auto-repeat alone instead of stopping a key the picker will never show.
  if layout == 0 and code == 24 then return end
  -- The synthetic release path uses send_key_state, whose pass() clears the
  -- modifier/group mask in the app afterwards.  That is harmless for a plain
  -- US-layout letter (mask already zero) but would reset an app's xkb state to
  -- US/group-0 while typing in RU, so non-zero groups take the focus path.
  local lower = not shift and not caps and layout == 0

  local t = {
    code = code,
    press = tonumber(time) or 0,
    shift = shift,
    caps = caps,
    layout = layout,
    delay = math.floor(delay),
    rate = math.floor(rate),
    winAddress = win.address or "",
    -- the window's own monitor, not whatever monitor the pointer happens to
    -- be over: the picker must appear where the text is being typed
    monitor = (win.monitor and win.monitor.name) or (win.workspace and win.workspace.monitor and win.workspace.monitor.name) or "",
    cancelled = false,
    -- The lower-case path stops the app before its first repeat, so the key
    -- press itself is the only character to remove.  Upper-case takes focus
    -- just before the repeat for the same reason.
    leaks = 0,
  }

  -- Lowercase: release the app's key before its first repeat.  The app keeps
  -- the one character it already inserted, but its client-side repeat timer
  -- stops, so the picker never has to delete a run of e's.
  if lower then
    t.stopTimer = hl.timer(function()
      if pending ~= t or t.cancelled or not down[code] then return end
      pcall(function()
        hl.dispatch(hl.dsp.send_key_state({ mods = "", key = tostring(code), state = "up" }))
      end)
    end, { timeout = math.max(10, t.delay - STOP_LEAD_MS), type = "oneshot" })
  end

  -- Lower case waits for a real Android-length hold.  Upper case cannot use
  -- the synthetic release (it would clear Shift/Caps in the app), so focus is
  -- taken just before the repeat instead.  That path is rarer and leaves the
  -- app with the one character the picker replaces.
  local showMs = lower and LONG_PRESS_MS or math.max(90, t.delay - STOP_LEAD_MS)
  t.showTimer = hl.timer(function()
    fire(t)
  end, { timeout = showMs, type = "oneshot" })

  pending = t
end

pcall(function() hl.on("input.keyboard.key", on_key) end)

-- Manual test hooks:
--   hyprctl eval 'lucidAccentTry(38, 0, 1)'   -- press A
--   hyprctl eval 'lucidAccentTry(38, 0, 0)'   -- release A
function lucidAccentTry(code, time, state)
  on_key(code, time, state)
end

-- shader.lua: minimal reading-mode keeper for Lucid
-- only e-ink shader (reading_mode.glsl) on SUPER+K, preserves gaps/borders/rounding/wallpaper

local home       = os.getenv("HOME") or "/home/nicerice"
local shader_dir = home .. "/.config/hypr/shaders/"

-- Cache files (kept for persistence across reloads)
local cache_dir       = home .. "/.cache/quickshell"
local rm_state_file   = cache_dir .. "/reading_mode"
local shader_state_file = cache_dir .. "/current_shader"

local M = {}
M.current_shader = nil
M.active_mode    = nil

-- keep defaults for reference, but Reading Mode no longer forces them
M.defaults = {
    rounding        = 20,
    gaps_in         = 10,
    gaps_out        = { top = 38, right = 50, bottom = 38, left = 50 },
    border_size     = 1,
    active_border   = "rgba(89b4faaa)",
    inactive_border = "rgba(313244aa)",
    animations      = true,
    shadow          = true,
    blur            = true,
    dim_inactive    = false,
    dim_around      = 0.6,
    damage_tracking = 2,
}

-- helpers
local function write_file(path, content)
    local f = io.open(path, "w")
    if f then f:write(content) f:close() end
end
local function read_file(path, fallback)
    local f = io.open(path, "r")
    if not f then return fallback end
    local content = f:read("*l") or ""
    f:close()
    content = content:match("^%s*(.-)%s*$")
    return (content ~= "") and content or fallback
end

M.simple_shaders = {
    ["Main"] = "main.glsl",
    ["AgX"] = "matugen-agx.glsl",
    ["AgX Map"] = "matugen-agx.glsl",
}
M.complex_modes = {
    ["Reading Mode"] = {
        shader = "reading_mode.glsl",
        activate = function(shader_path)
            write_file(rm_state_file, "on")
            -- preserve gaps/borders/rounding/wallpaper — only shader + minimal e-ink tweaks
            -- single call: one reload instead of two (extra reloads blank the 4K secondaries)
            hl.config({
                decoration = {
                    dim_inactive = false,
                    shadow       = { enabled = false },
                    blur         = { enabled = false },
                    screen_shader = shader_path,
                },
                animations = { enabled = false },
            })
        end,
        deactivate = function()
            write_file(rm_state_file, "off")
            -- restore shadow/blur/animations, keep tiling intact
            hl.config({
                decoration = {
                    dim_inactive = M.defaults.dim_inactive,
                    dim_around   = M.defaults.dim_around,
                    shadow       = { enabled = M.defaults.shadow },
                    blur         = { enabled = M.defaults.blur },
                },
                animations = { enabled = M.defaults.animations },
                debug      = { damage_tracking = M.defaults.damage_tracking },
            })
            hl.config({ decoration = { screen_shader = shader_dir .. "main.glsl" } })
        end,
    },
}

local function persist_state()
    if M.current_shader then
        write_file(shader_state_file, M.current_shader)
    else
        write_file(shader_state_file, "none")
    end
end

function M.turn_off_all()
    if M.active_mode then
        M.complex_modes[M.active_mode].deactivate()
        M.active_mode = nil
    end
    -- keep Main active to avoid direct-scanout flicker ("" causes pipeline swap black frames on NVIDIA)
    M.current_shader = "Main"
    hl.config({ decoration = { screen_shader = shader_dir .. "main.glsl" } })
    persist_state()
end

-- idempotent enable (no toggle-off): safe for boot/startup handlers
function M.enable(name)
    if M.active_mode and M.active_mode ~= name then
        M.complex_modes[M.active_mode].deactivate()
        M.active_mode = nil
    end
    if M.complex_modes[name] then
        M.active_mode = name
        M.current_shader = name
        M.complex_modes[name].activate(shader_dir .. M.complex_modes[name].shader)
        persist_state()
        return
    end
    if M.simple_shaders[name] then
        M.current_shader = name
        -- single call: shader is fully static (no time uniform), tracking 2 is correct
        hl.config({ decoration = { screen_shader = shader_dir .. M.simple_shaders[name] } })
        persist_state()
        return
    end
end

function M.toggle(name)
    if name == "Turn Off All" then
        M.turn_off_all()
        return
    end
    -- AgX aliases: AgX / AgX Map are same shader — toggle off returns to Main (not off)
    local isAgX = (name == "AgX" or name == "AgX Map")
    local curIsAgX = (M.current_shader == "AgX" or M.current_shader == "AgX Map")
    if isAgX and curIsAgX then
        M.current_shader = "Main"
        -- single call: tracking already 2, re-setting it only caused an extra reload
        hl.config({ decoration = { screen_shader = shader_dir .. "main.glsl" } })
        persist_state()
        return
    end
    if M.current_shader == name then
        if M.complex_modes[name] then
            M.complex_modes[name].deactivate()
            M.active_mode = nil
            M.current_shader = "Main"
            hl.config({ decoration = { screen_shader = shader_dir .. "main.glsl" } })
            persist_state()
            return
        end
        M.turn_off_all()
        return
    end
    if M.active_mode and M.active_mode ~= name then
        M.complex_modes[M.active_mode].deactivate()
        M.active_mode = nil
        M.current_shader = nil
    end
    if M.complex_modes[name] then
        M.active_mode = name
        M.current_shader = name
        M.complex_modes[name].activate(shader_dir .. M.complex_modes[name].shader)
        persist_state()
        return
    end
    if M.simple_shaders[name] then
        M.current_shader = name
        -- single call: shader is fully static (no time uniform), tracking 2 is correct
        hl.config({ decoration = { screen_shader = shader_dir .. M.simple_shaders[name] } })
        persist_state()
        return
    end
end

-- keybinds
local mod = "SUPER"
hl.bind(mod .. " + K", function() M.toggle("Reading Mode") end, { description = "Toggle Reading Mode" })
hl.bind(mod .. " + ALT + S", function() M.turn_off_all() end, { description = "Turn off all shaders" })
hl.bind(mod .. " + G", function() M.toggle("AgX") end, { description = "Toggle AgX Map (matugen AgX tint)" })
hl.bind(mod .. " + ALT + G", function() M.toggle("AgX") end, { description = "Toggle AgX Map (alt)" })
hl.bind(mod .. " + SHIFT + G", function() M.toggle("AgX Map") end, { description = "Toggle AgX Map" })

-- restore after reload (matugen triggers reload)
hl.on("config.reloaded", function()
    local rm = read_file(rm_state_file, "off")
    if rm == "on" then
        M.active_mode = "Reading Mode"
        M.current_shader = "Reading Mode"
        hl.config({
            decoration = { dim_inactive=false, shadow={enabled=false}, blur={enabled=false}, screen_shader = shader_dir .. "reading_mode.glsl" },
            animations = { enabled=false },
        })
        return
    end
    local persisted = read_file(shader_state_file, "none")
    if persisted == "none" or persisted == "" then
        -- homogenizer disabled by default for now: fresh state boots to Main
        hl.config({ decoration = { screen_shader = shader_dir .. "main.glsl" } })
        M.current_shader = "Main"
        M.active_mode = nil
        persist_state()
    elseif M.simple_shaders[persisted] then
        M.current_shader = persisted
        hl.config({ decoration = { screen_shader = shader_dir .. M.simple_shaders[persisted] } })
    elseif M.complex_modes[persisted] then
        M.active_mode = persisted
        M.current_shader = persisted
        hl.config({ decoration = { screen_shader = shader_dir .. M.complex_modes[persisted].shader } })
    elseif persisted == "Main" then
        M.current_shader = "Main"
        hl.config({ decoration = { screen_shader = shader_dir .. "main.glsl" } })
    else
        if persisted:match("%.glsl$") then
            hl.config({ decoration = { screen_shader = shader_dir .. persisted } })
        else
            -- unknown state: homogenizer disabled by default, fall back to Main
            hl.config({ decoration = { screen_shader = shader_dir .. "main.glsl" } })
            M.current_shader = "Main"
            persist_state()
        end
    end
end)

do
    local persisted = read_file(shader_state_file, "")
    if persisted ~= "" and persisted ~= "none" then
        if M.simple_shaders[persisted] or persisted == "Main" then
            M.current_shader = persisted
        elseif M.complex_modes[persisted] then
            M.active_mode = persisted
            M.current_shader = persisted
        end
    end
end

return M

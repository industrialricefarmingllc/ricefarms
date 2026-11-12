-- shader.lua: minimal reading-mode keeper for Lucid
-- only e-ink shader (reading_mode.glsl) on SUPER+K, preserves gaps/borders/rounding/wallpaper

local home       = os.getenv("HOME") or "/home/nicerice"
local shader_dir = home .. "/.config/hypr/shaders/"
local ambient_dir = home .. "/.cache/lucid/ambient-eink"
local auto_shader_file = ambient_dir .. "/auto_shader"
local reading_shader_file = ambient_dir .. "/reading_shader"

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
    gaps_in         = 7,
    gaps_out        = { top = 16, right = 25, bottom = 38, left = 25 },
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

-- The ambient service publishes the current auto and full-e-ink shader paths.
-- Reading Mode uses the latter with the same daytime black dimming; leaving it
-- returns to the former instead of falling back to a shaderless main.
local function ambient_shader(reading)
    local p = read_file(reading and reading_shader_file or auto_shader_file, "")
    if p ~= "" then return p end
    return shader_dir .. (reading and "reading_mode.glsl" or "main.glsl")
end

local function sync_ambient(reading)
    hl.exec_cmd(home .. "/.local/bin/lucid-ambient-eink --reading " .. (reading and "on" or "off"))
end

M.simple_shaders = {
    ["Main"] = "main.glsl",
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
                    screen_shader = ambient_shader(true),
                },
                animations = { enabled = false },
            })
            sync_ambient(true)
        end,
        deactivate = function()
            write_file(rm_state_file, "off")
            -- restore shadow/blur/animations, keep tiling intact, and go back
            -- to the ambient auto shader rather than a shaderless main.
            hl.config({
                decoration = {
                    dim_inactive = M.defaults.dim_inactive,
                    dim_around   = M.defaults.dim_around,
                    shadow       = { enabled = M.defaults.shadow },
                    blur         = { enabled = M.defaults.blur },
                    screen_shader = ambient_shader(false),
                },
                animations = { enabled = M.defaults.animations },
                debug      = { damage_tracking = M.defaults.damage_tracking },
            })
            sync_ambient(false)
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
    if M.current_shader == name then
        if M.complex_modes[name] then
            M.complex_modes[name].deactivate()
            M.active_mode = nil
            M.current_shader = "Main"
            -- deactivate() already restored the ambient auto shader
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


-- restore after reload (matugen triggers reload)
hl.on("config.reloaded", function()
    local rm = read_file(rm_state_file, "off")
    if rm == "on" then
        M.active_mode = "Reading Mode"
        M.current_shader = "Reading Mode"
        hl.config({
            decoration = { dim_inactive=false, shadow={enabled=false}, blur={enabled=false}, screen_shader = ambient_shader(true) },
            animations = { enabled=false },
        })
        sync_ambient(true)
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

    -- A reload rewrites screen_shader from the main config. If we are on the
    -- default view, put the ambient auto shader back at once and wake the
    -- service so it can retarget; don't leave the desktop shaderless.
    if persisted == "none" or persisted == "" or persisted == "Main" then
        hl.config({ decoration = { screen_shader = ambient_shader(false) } })
        sync_ambient(false)
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

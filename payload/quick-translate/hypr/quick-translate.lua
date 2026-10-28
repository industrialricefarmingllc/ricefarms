-- quick-translate: add this to ~/.config/hypr/custom.lua, or source it from
-- there with dofile(). install.sh writes the same block automatically.
local dir = os.getenv("HOME") .. "/src/quick-translate"

hl.bind("SUPER + T", hl.dsp.exec_cmd("qs -p " .. dir .. " ipc call quick-translate toggle"), {
    description = "Quick translate (SUPER+T)",
})

-- -n leaves an already-running daemon alone, so a config reload is harmless.
hl.exec_cmd("qs -p " .. dir .. " -n -d")

-- Lucid opens the launcher on a bare Super release. A SUPER+T chord must clear
-- that tap intent or the release opens the launcher too. install.sh inserts
-- this next to super_tap_disarm in hyprland.lua; it cannot be done from here
-- because that function is a chunk-local:
--
--   hl.bind("SUPER + T", super_tap_disarm,
--       { transparent = true, non_consuming = true })

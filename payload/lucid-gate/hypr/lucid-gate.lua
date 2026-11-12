-- lucid-gate: optional Hyprland glue.
--
--   dofile(os.getenv("HOME") .. "/src/lucid-gate/hypr/lucid-gate.lua")
--
-- from ~/.config/hypr/custom.lua.  Everything here is optional: the shell
-- widget and the overlay work without it.

-- Duolingo opens as a chromeless browser app.  Float it, so it lands as a card
-- over the window that asked instead of joining the tile layout.
pcall(function()
  hl.window_rule({
    name = "lucid-gate-duolingo",
    match = { class = "^(lucid-gate-duolingo)$" },
    float = true,
    size = "1100 800",
    center = true,
  })
end)

-- Wrap any command so it waits at the gate.  The command runs exactly once,
-- after a task is finished or credits are spent.
local function gated(place, command)
  local quoted = command:gsub("'", "'\\''")
  return hl.dsp.exec_cmd("sh -c '~/.local/bin/gate run --place " .. place .. " -- " .. quoted .. "'")
end

-- Examples.  Uncomment the ones you want, or build your own:
--
-- hl.bind("SUPER + SHIFT + D", gated("discord", "discord"))
-- hl.bind("SUPER + G", gated("steam", "steam --silent"))
-- hl.bind("SUPER + B", gated("browser", "helium-browser"))
--
-- To gate an app you launch from the dock instead, point the launcher's entry
-- at `~/.local/bin/gate run --place <name> -- <app>`; the dock does not need to
-- know anything about the gate.

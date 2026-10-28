-- written by Lucid Settings > Workspaces, and rewritten on every change there
return {
    keep = true,
    hide_on_switch = false,
    dim = 0.2,
    blur = false,
    gaps = 0,
    workspaces = {
        special = { enabled = true, apps = {} },
        music = { enabled = true, apps = {} },
        comms = { enabled = true, apps = {} },
        todo = { enabled = true, apps = {} },
        sysmon = { enabled = true, apps = {
            { name = "btop", cmd = "if command -v kitty >/dev/null 2>&1; then exec kitty --class 'lucid.btop' -e 'btop'; elif command -v foot >/dev/null 2>&1; then exec foot --app-id='lucid.btop' 'btop'; elif command -v alacritty >/dev/null 2>&1; then exec alacritty --class 'lucid.btop' -e 'btop'; elif command -v ghostty >/dev/null 2>&1; then exec ghostty --class='lucid.btop' -e 'btop'; fi", class = { "lucid.btop" } },
        } },
    },
}

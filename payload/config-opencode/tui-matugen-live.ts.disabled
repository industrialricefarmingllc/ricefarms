/** @jsxImportSource @opentui/solid */
import type { TuiPlugin } from "@opencode-ai/plugin/tui"
import { watch } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const tui: TuiPlugin = async (api, _opts, _meta) => {
  const themeName = "matugen"
  const themePath = join(homedir(), ".config", "opencode", "themes", "matugen.json")
  const themesDir = join(homedir(), ".config", "opencode", "themes")

  // Immediate feedback that plugin loaded
  // api.ui.toast({ message: "matugen-live active", variant: "info", duration: 1500 })

  let lastMtime = 0
  let lastContent = ""
  try {
    const f = Bun.file(themePath)
    if (await f.exists()) {
      lastContent = await f.text()
      const { stat } = await import("node:fs/promises")
      const st = await stat(themePath).catch(() => null)
      lastMtime = st ? st.mtimeMs : 0
    }
  } catch {}

  let debounce: ReturnType<typeof setTimeout> | null = null
  const triggerReload = async () => {
    if (debounce) clearTimeout(debounce)
    debounce = setTimeout(async () => {
      try {
        // Try multiple reload strategies
        // 1. Built-in watcher should have already re-read file, so set should pick up new colors
        if (api.theme.selected === themeName) {
          api.theme.set(themeName)
          // 2. Also try dispatching the reload-theme command if available
          try { (api as any).keymap?.dispatchCommand?.("theme.reload") } catch {}
          try { (api as any).keymap?.dispatchCommand?.("command.reload-theme") } catch {}
          // 3. Force re-install via temp file to ensure new content is loaded
          try {
            const content = await Bun.file(themePath).text()
            if (content !== lastContent) {
              lastContent = content
              // Write to a temp location and install
              const tmp = `/tmp/opencode-matugen-${Date.now()}.json`
              await Bun.write(tmp, content)
              // install expects relative path from plugin root, but we can try absolute via file://
              // Fallback: just set again after a short delay to allow built-in watcher to sync
              setTimeout(() => {
                try { api.theme.set(themeName) } catch {}
              }, 400)
            }
          } catch {}
        }
        // api.ui.toast({ message: "matugen theme updated", variant: "info", duration: 1000 })
      } catch {}
    }, 300)
  }

  const poll = setInterval(async () => {
    try {
      const { stat, readFile } = await import("node:fs/promises")
      const st = await stat(themePath).catch(() => null)
      const mtime = st ? st.mtimeMs : 0
      if (mtime && mtime !== lastMtime) {
        lastMtime = mtime
        // Also check content change to avoid false positives from mtime only
        try {
          const content = await readFile(themePath, "utf-8")
          if (content !== lastContent) {
            lastContent = content
            triggerReload()
          }
        } catch {
          triggerReload()
        }
      } else if (mtime === 0 && lastMtime !== 0) {
        lastMtime = 0
        triggerReload()
      }
    } catch {}
  }, 500)

  // Watch the theme file and the directory (matugen does atomic write via temp+rename)
  const watchers: ReturnType<typeof watch>[] = []
  try {
    const w1 = watch(themePath, (event) => {
      if (event === "change" || event === "rename") triggerReload()
    })
    watchers.push(w1)
  } catch {}

  try {
    const w2 = watch(themesDir, (_event, filename) => {
      if (!filename || filename === "matugen.json") triggerReload()
    })
    watchers.push(w2)
  } catch {}

  // Cleanup on plugin dispose
  api.lifecycle.onDispose(() => {
    for (const w of watchers) {
      try { w.close() } catch {}
    }
    if (debounce) clearTimeout(debounce)
    clearInterval(poll)
  })

  // Ensure matugen theme is available on startup
  // If theme exists but file was just generated, set it
  if (api.theme.has(themeName) && api.theme.selected !== themeName) {
    // do not auto-switch if user selected different theme; just ensure ready
  }
}

export default {
  id: "matugen-live",
  tui,
}

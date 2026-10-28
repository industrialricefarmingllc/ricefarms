-- ============================================================================
-- Zed-flavoured Neovim
--
-- A non-modal, VS Code/Zed-style Neovim configuration.  The goal is not to
-- turn Neovim into Zed, but to make the same workflows and the same muscle
-- memory work here: command palette, project panel, fuzzy finders, inline git
-- hunks, unified diffs, an AI agent dock, and remote SSH development.
--
-- Structure:
--   lua/config/options.lua   editor options / UI
--   lua/config/autocmds.lua  autosave, format, insert-on-enter, diagnostics
--   lua/config/keymaps.lua   the Zed keymap (applied to editor buffers)
--   lua/config/buffers.lua   tab/buffer management
--   lua/config/selection.lua syntax-node expand/shrink
--   lua/config/terminal.lua  bottom terminal + agent dock
--   lua/config/git.lua       git panel, unified diff, hunk helpers
--   lua/config/ai.lua        OpenCode integration
--   lua/config/remote.lua    :SSH / :Dev and remote-nvim glue
--   lua/plugins/*.lua        lazy.nvim specs
--
-- Docs: see ZED_KEYMAP.md next to this file.
-- ============================================================================

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "--branch=stable",
    "https://github.com/folke/lazy.nvim.git",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require("config.options")
require("config.autocmds")

require("lazy").setup("plugins", {
  install = { missing = true },
  checker = { enabled = false },
  change_detection = { notify = false },
  ui = { border = "rounded" },
  performance = {
    cache = { enabled = true },
    rtp = {
      disabled_plugins = { "gzip", "tarPlugin", "tohtml", "tutor", "zipPlugin" },
    },
  },
})

require("config.keymaps")
require("config.git")
require("config.remote")

-- AI: OpenCode, the same agent server used by Zed here.
local M = {}

function M.setup()
  local terminal = require("config.terminal")

  ---@type opencode.Opts
  vim.g.opencode_opts = {
    server = {
      url = vim.env.OPENCODE_SERVER_URL,
      connect = true,
      start = function()
        terminal.open_agent()
      end,
    },
    events = {
      enabled = true,
      reload = { enabled = true },
      permissions = {
        enabled = true,
        edits = { enabled = true },
      },
    },
    ask = {
      prompt = "Ask OpenCode: ",
    },
    select = {
      prompt = "OpenCode: ",
    },
  }

  local ok, opencode = pcall(require, "opencode")
  if not ok then
    return
  end

  vim.api.nvim_create_user_command("AI", function()
    opencode.select()
  end, { desc = "OpenCode: select an action" })

  vim.api.nvim_create_user_command("AIAsk", function(opts)
    opencode.prompt(opts.args)
  end, { nargs = "*", desc = "OpenCode: prompt" })

  vim.api.nvim_create_user_command("AICommit", function()
    require("config.git").commit_message()
  end, { desc = "OpenCode: generate a commit message" })

  vim.api.nvim_create_user_command("AIFocus", function()
    terminal.focus_agent()
  end, { desc = "OpenCode: focus the agent dock" })

  vim.api.nvim_create_user_command("AIToggle", function()
    terminal.toggle_agent()
  end, { desc = "OpenCode: toggle the agent dock" })
end

function M.ask_this()
  local ok, opencode = pcall(require, "opencode")
  if not ok then
    vim.notify("opencode.nvim is not loaded", vim.log.levels.WARN)
    return
  end
  opencode.ask("@this: ")
end

function M.focus()
  require("config.terminal").focus_agent()
end

function M.toggle()
  require("config.terminal").toggle_agent()
end

function M.select()
  local ok, opencode = pcall(require, "opencode")
  if not ok then
    return
  end
  opencode.select()
end

return M

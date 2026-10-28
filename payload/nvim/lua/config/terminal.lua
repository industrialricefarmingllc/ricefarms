-- Terminal panel + OpenCode agent dock.
local M = {}

local function termlib()
  local ok, lib = pcall(require, "toggleterm.terminal")
  if not ok then
    return nil
  end
  return lib.Terminal
end

local horizontal
local agent

local function get_horizontal()
  if horizontal then
    return horizontal
  end
  local Terminal = termlib()
  if not Terminal then
    return nil
  end
  horizontal = Terminal:new({
    id = 1,
    direction = "horizontal",
    size = 15,
    hidden = true,
    close_on_exit = true,
    start_in_insert = true,
    persist_size = true,
    desc = "Terminal",
  })
  return horizontal
end

function M.opencode_bin()
  local candidates = {
    "opencode",
    vim.fn.expand("~/.opencode/bin/opencode"),
    vim.fn.expand("~/.bun/bin/opencode"),
    "/usr/local/bin/opencode",
  }
  for _, candidate in ipairs(candidates) do
    if vim.fn.executable(candidate) == 1 then
      return candidate
    end
  end
  return nil
end

local function get_agent()
  if agent then
    return agent
  end
  local Terminal = termlib()
  if not Terminal then
    return nil
  end
  agent = Terminal:new({
    id = 2,
    direction = "vertical",
    size = function()
      return math.max(60, math.floor(vim.o.columns * 0.42))
    end,
    hidden = true,
    close_on_exit = true,
    start_in_insert = true,
    persist_size = true,
    cmd = M.opencode_bin() or "opencode",
    desc = "OpenCode",
  })
  return agent
end

function M.agent_available()
  return M.opencode_bin() ~= nil
end

function M.toggle_terminal()
  local term = get_horizontal()
  if not term then
    return
  end
  term:toggle()
end

function M.focus_terminal()
  local term = get_horizontal()
  if not term then
    return
  end
  term:open()
  vim.cmd("startinsert")
end

function M.new_terminal()
  local Terminal = termlib()
  if not Terminal then
    return
  end
  local term = Terminal:new({
    direction = "horizontal",
    size = 15,
    hidden = true,
    close_on_exit = true,
    start_in_insert = true,
  })
  term:toggle()
end

function M.open_agent()
  if not M.agent_available() then
    vim.notify(
      "OpenCode is not installed on this host. Install it with `curl -fsSL https://opencode.ai/install | bash`.",
      vim.log.levels.WARN
    )
    return
  end
  local term = get_agent()
  if not term then
    return
  end
  term:open()
end

function M.toggle_agent()
  if not M.agent_available() then
    vim.notify(
      "OpenCode is not installed on this host. Install it with `curl -fsSL https://opencode.ai/install | bash`.",
      vim.log.levels.WARN
    )
    return
  end
  local term = get_agent()
  if not term then
    return
  end
  term:toggle()
end

function M.focus_agent()
  if not M.agent_available() then
    vim.notify("OpenCode is not installed on this host.", vim.log.levels.WARN)
    return
  end
  local term = get_agent()
  if not term then
    return
  end
  if not term:is_open() then
    term:open()
  else
    local win = term.window
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
    end
    vim.cmd("startinsert")
  end
end

function M.agent_send(text)
  if not M.agent_available() then
    return
  end
  local term = get_agent()
  if not term then
    return
  end
  M.open_agent()
  term:send(text, true)
end

function M.setup_keymaps()
  local map = vim.keymap.set
  local function opts(desc)
    return { noremap = true, silent = true, desc = desc }
  end

  -- Terminal windows: Ctrl+` closes, like the Zed terminal panel.
  map("t", "<C-`>", function()
    vim.cmd("stopinsert")
    M.toggle_terminal()
  end, opts("Toggle terminal"))
  map("t", "<C-S-e>", function()
    vim.cmd("stopinsert")
    vim.cmd("wincmd p")
  end, opts("Leave terminal"))

  -- In the agent terminal, Ctrl+Shift+O hides the dock.
  map("t", "<C-S-o>", function()
    vim.cmd("stopinsert")
    M.toggle_agent()
  end, opts("Toggle OpenCode"))
  map("t", "<C-S-l>", function()
    vim.cmd("stopinsert")
    M.focus_agent()
  end, opts("Focus OpenCode"))
end

return M

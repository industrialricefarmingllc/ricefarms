-- Remote development.  `:SSH host` is the fast path (kept from the original
-- config); `:Dev` connects to the `dev` host directly.
local M = {}

local function ensure_remote_nvim()
  local ok = pcall(require, "remote-nvim")
  if ok then
    return true
  end
  pcall(function()
    require("lazy").load({ plugins = { "remote-nvim.nvim" } })
  end)
  return pcall(require, "remote-nvim")
end

local function remote_start(args)
  if not ensure_remote_nvim() then
    vim.notify("remote-nvim is not installed", vim.log.levels.ERROR)
    return
  end
  if args and args ~= "" then
    vim.cmd("RemoteStart " .. args)
  else
    vim.cmd("RemoteStart")
  end
end

M.remote_start = remote_start

vim.api.nvim_create_user_command("SSH", function(opts)
  remote_start(opts.args)
end, { nargs = "*", desc = "Alias: remote SSH (RemoteStart)" })

vim.api.nvim_create_user_command("Dev", function()
  remote_start("dev")
end, { desc = "Connect to the dev host with remote-nvim" })

vim.api.nvim_create_user_command("SSHStop", function()
  ensure_remote_nvim()
  vim.cmd("RemoteStop")
end, { nargs = "*", desc = "Stop a remote-nvim server" })

vim.api.nvim_create_user_command("SSHInfo", function()
  ensure_remote_nvim()
  vim.cmd("RemoteInfo")
end, { desc = "Show remote-nvim session information" })

vim.api.nvim_create_user_command("SSHCleanup", function()
  ensure_remote_nvim()
  vim.cmd("RemoteCleanup")
end, { desc = "Clean up remote-nvim resources" })

-- Lowercase :ssh is not a valid user command; rewrite it on <CR>.
-- NOTE: a cnoreabbrev cannot do this: an <expr> abbrev triggered by Enter
-- evaluates after submit, so getcmdtype() is no longer ":".
vim.keymap.set("c", "<CR>", function()
  if vim.fn.getcmdtype() == ":" then
    local line = vim.fn.getcmdline()
    if line == "ssh" then
      return vim.api.nvim_replace_termcodes("<C-U>RemoteStart<CR>", true, false, true)
    end
    local rest = line:match("^ssh%s+(.-)%s*$")
    if rest ~= nil then
      return vim.api.nvim_replace_termcodes("<C-U>RemoteStart " .. rest .. "<CR>", true, false, true)
    end
  end
  return vim.api.nvim_replace_termcodes("<CR>", true, false, true)
end, { noremap = true, expr = true, desc = "lowercase :ssh -> RemoteStart" })

-- Zed: Ctrl+Alt+Shift+O = Open Remote Project.
vim.keymap.set({ "n", "i", "v" }, "<C-A-S-o>", function()
  remote_start("")
end, { noremap = true, silent = true, desc = "Remote: open SSH project" })

return M

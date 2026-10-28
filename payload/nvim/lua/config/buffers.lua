-- Buffer ("tab") management.  Zed has tabs without a tab bar; these helpers
-- give Neovim the same commands without showing a tabline.
local api = vim.api
local M = {}

local closed = {}
local last_buffer = nil
local MAX_CLOSED = 50

local function is_real_buffer(buf)
  return api.nvim_buf_is_valid(buf)
    and vim.bo[buf].buflisted
    and vim.bo[buf].buftype == ""
end

local function listed_buffers()
  local out = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if is_real_buffer(buf) then
      out[#out + 1] = buf
    end
  end
  return out
end

function M.relative_path(buf)
  local name = api.nvim_buf_get_name(buf or 0)
  if name == "" then
    return ""
  end
  local cwd = vim.uv.cwd() or vim.fn.getcwd()
  local rel = vim.fs.relpath(cwd, name)
  return rel or name
end

function M.copy_relative_path()
  local path = M.relative_path(0)
  if path == "" then
    vim.notify("No file path for this buffer", vim.log.levels.WARN)
    return
  end
  vim.fn.setreg("+", path)
  vim.notify("Copied: " .. path, vim.log.levels.INFO)
end

function M.close()
  local buf = api.nvim_get_current_buf()
  if not is_real_buffer(buf) then
    vim.cmd("close")
    return
  end

  -- Never discard edits.  Saving may also run format-on-save.
  if vim.bo[buf].modified then
    if api.nvim_buf_get_name(buf) == "" then
      vim.notify("Not closing: buffer has no file name; write it first", vim.log.levels.WARN)
      return
    end
    api.nvim_buf_call(buf, function()
      vim.cmd("silent! write")
    end)
    if vim.bo[buf].modified then
      vim.notify("Not closing: could not save " .. api.nvim_buf_get_name(buf), vim.log.levels.ERROR)
      return
    end
  end

  local bufs = listed_buffers()
  if #bufs <= 1 then
    vim.cmd("enew")
  end
  local ok = pcall(api.nvim_buf_delete, buf, { force = false })
  if not ok then
    vim.cmd("bdelete " .. buf)
  end
end

function M.reopen()
  while #closed > 0 do
    local path = table.remove(closed)
    if path and vim.fn.filereadable(path) == 1 then
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      return
    end
  end
  vim.notify("No recently closed file", vim.log.levels.INFO)
end

function M.next()
  vim.cmd("bnext")
end

function M.prev()
  vim.cmd("bprevious")
end

function M.toggle_last()
  if last_buffer and api.nvim_buf_is_valid(last_buffer) then
    api.nvim_set_current_buf(last_buffer)
  end
end

function M.activate(index)
  local bufs = listed_buffers()
  local target = bufs[index]
  if target then
    api.nvim_set_current_buf(target)
  end
end

function M.activate_last()
  local bufs = listed_buffers()
  if #bufs > 0 then
    api.nvim_set_current_buf(bufs[#bufs])
  end
end

function M.close_others()
  local cur = api.nvim_get_current_buf()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if buf ~= cur and is_real_buffer(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
end

function M.close_to_left()
  local cur = api.nvim_get_current_buf()
  local seen = false
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if buf == cur then
      seen = true
    elseif not seen and is_real_buffer(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
end

function M.close_to_right()
  local cur = api.nvim_get_current_buf()
  local seen = false
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if buf == cur then
      seen = true
    elseif seen and is_real_buffer(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
end

function M.close_clean()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if is_real_buffer(buf) and not vim.bo[buf].modified then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
end

function M.close_all()
  vim.cmd("enew")
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if is_real_buffer(buf) and api.nvim_get_current_buf() ~= buf then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
end

function M.pick()
  require("telescope.builtin").buffers({
    sort_lastused = true,
    ignore_current_buffer = false,
    mappings = {
      i = {
        ["<C-d>"] = require("telescope.actions").delete_buffer,
      },
      n = {
        ["<C-d>"] = require("telescope.actions").delete_buffer,
      },
    },
  })
end

function M.reveal()
  local ok, neotree = pcall(require, "neo-tree.command")
  if not ok then
    return
  end
  neotree.execute({ action = "show", source = "filesystem", position = "left", reveal = true })
end

function M.open_file(path)
  if path and path ~= "" then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end
end

api.nvim_create_autocmd("BufDelete", {
  callback = function(args)
    local name = api.nvim_buf_get_name(args.buf)
    if name == "" or vim.bo[args.buf].buftype ~= "" then
      return
    end
    closed[#closed + 1] = name
    if #closed > MAX_CLOSED then
      table.remove(closed, 1)
    end
  end,
  desc = "Remember closed files for Ctrl+Shift+T",
})

local current_buffer = nil
api.nvim_create_autocmd("BufEnter", {
  callback = function(args)
    local buf = args.buf
    if not is_real_buffer(buf) then
      return
    end
    if current_buffer
      and current_buffer ~= buf
      and api.nvim_buf_is_valid(current_buffer)
      and is_real_buffer(current_buffer)
    then
      last_buffer = current_buffer
    end
    current_buffer = buf
  end,
  desc = "Track the previously focused buffer",
})

return M

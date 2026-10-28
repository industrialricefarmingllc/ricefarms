-- Syntax-aware selection expansion (Zed: Ctrl+Shift+D / Shift+Alt+Right).
-- Uses Neovim's bundled tree-sitter parsers when available and falls back to
-- word -> line -> paragraph, so it still works for languages without a parser.
local api = vim.api
local M = {}

local stacks = {}

local function clear(buf)
  stacks[buf] = nil
end

local function pos_in_range(row, col, range)
  local sr, sc, er, ec = range[1], range[2], range[3], range[4]
  if row < sr or row > er then
    return false
  end
  if row == sr and col < sc then
    return false
  end
  if row == er and col >= ec then
    return false
  end
  return true
end

local function normalize_range(sr, sc, er, ec)
  if er > sr and ec == 0 then
    er = er - 1
    local line = api.nvim_buf_get_lines(0, er, er + 1, false)[1] or ""
    ec = #line
  end
  if ec <= sc and er == sr then
    ec = sc + 1
  end
  return { sr, sc, er, ec }
end

local function select_range(range)
  local sr, sc, er, ec = range[1], range[2], range[3], range[4]
  if vim.fn.mode():match("[vV\22]") then
    vim.cmd("normal! \27")
  end
  local line_count = api.nvim_buf_line_count(0)
  sr = math.min(sr, line_count - 1)
  er = math.min(er, line_count - 1)
  api.nvim_win_set_cursor(0, { sr + 1, sc })
  vim.cmd("normal! v")
  local end_line = api.nvim_buf_get_lines(0, er, er + 1, false)[1] or ""
  local end_col = math.max(0, math.min(ec - 1, math.max(#end_line - 1, 0)))
  api.nvim_win_set_cursor(0, { er + 1, end_col })
end

local function node_range(node)
  local sr, sc, er, ec = node:range()
  return normalize_range(sr, sc, er, ec)
end

local function node_at_cursor()
  local ok, node = pcall(vim.treesitter.get_node, {
    bufnr = 0,
    ignore_injections = false,
  })
  if ok then
    return node
  end
  return nil
end

local function current_selection()
  if not vim.fn.mode():match("[vV\22]") then
    return nil
  end
  local s = vim.fn.getpos("v")
  local e = vim.fn.getpos(".")
  local sr, sc = s[2] - 1, math.max(s[3] - 1, 0)
  local er, ec = e[2] - 1, math.max(e[3] - 1, 0)
  if er < sr or (er == sr and ec < sc) then
    sr, er = er, sr
    sc, ec = ec, sc
  end
  return { sr, sc, er, ec + 1 }
end

local function covers(node, range)
  local sr, sc, er, ec = node:range()
  return sr <= range[1]
    and (sr < range[1] or sc <= range[2])
    and er >= range[3]
    and (er > range[3] or ec >= range[4])
end

local function word_range()
  local row = api.nvim_win_get_cursor(0)[1] - 1
  local line = api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""
  local word = vim.fn.expand("<cword>")
  if word == "" then
    return { row, 0, row, #line }
  end
  local init = api.nvim_win_get_cursor(0)[2]
  local start = line:find(word, math.max(init - #word, 1), true)
  if not start then
    start = line:find(word, 1, true) or 1
  end
  return { row, start - 1, row, start - 1 + #word }
end

local function line_range()
  local row = api.nvim_win_get_cursor(0)[1] - 1
  local line = api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""
  return { row, 0, row, #line }
end

local function paragraph_range()
  local row = api.nvim_win_get_cursor(0)[1]
  local start = row
  local finish = row
  local last = api.nvim_buf_line_count(0)
  while start > 1 and (api.nvim_buf_get_lines(0, start - 2, start - 1, false)[1] or ""):match("%S") do
    start = start - 1
  end
  while finish < last and (api.nvim_buf_get_lines(0, finish, finish + 1, false)[1] or ""):match("%S") do
    finish = finish + 1
  end
  local line = api.nvim_buf_get_lines(0, finish - 1, finish, false)[1] or ""
  return { start - 1, 0, finish - 1, #line }
end

local function fallback_expand(stack)
  local level = #stack
  if level == 0 then
    stack[#stack + 1] = { range = word_range() }
  elseif level == 1 then
    stack[#stack + 1] = { range = line_range() }
  elseif level == 2 then
    stack[#stack + 1] = { range = paragraph_range() }
  else
    return false
  end
  select_range(stack[#stack].range)
  return true
end

function M.expand()
  if vim.fn.mode():match("[iR]") then
    vim.cmd("stopinsert")
  end
  local buf = api.nvim_get_current_buf()
  local cursor = api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local stack = stacks[buf] or {}
  stacks[buf] = stack

  -- Cursor moved away from the last selection: start a new chain.
  if #stack > 0 and not pos_in_range(row, col, stack[#stack].range) then
    stack = {}
    stacks[buf] = stack
  end

  local node = node_at_cursor()
  local selection = current_selection()

  -- If there is a fresh manual selection, grow to the node that covers it.
  if node and #stack == 0 and selection and not covers(node, selection) then
    while node and not covers(node, selection) do
      node = node:parent()
    end
  end

  if node then
    local range = node_range(node)
    stack[#stack + 1] = { node = node, range = range }
    select_range(range)
    return
  end

  fallback_expand(stack)
end

function M.shrink()
  if vim.fn.mode():match("[iR]") then
    vim.cmd("stopinsert")
  end
  local buf = api.nvim_get_current_buf()
  local stack = stacks[buf] or {}
  if #stack <= 1 then
    stacks[buf] = nil
    if vim.fn.mode():match("[vV\22]") then
      vim.cmd("normal! \27")
      vim.cmd("startinsert")
    end
    return
  end
  table.remove(stack)
  select_range(stack[#stack].range)
end

function M.select_node_under_cursor()
  local node = node_at_cursor()
  if not node then
    vim.notify("No syntax parser for this buffer", vim.log.levels.INFO)
    return
  end
  if vim.fn.mode():match("[iR]") then
    vim.cmd("stopinsert")
  end
  local range = node_range(node)
  stacks[api.nvim_get_current_buf()] = { { node = node, range = range } }
  select_range(range)
end

api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufLeave" }, {
  callback = function(args)
    clear(args.buf)
  end,
  desc = "Invalidate syntax selection after edits",
})

return M

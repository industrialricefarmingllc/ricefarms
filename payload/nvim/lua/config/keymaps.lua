-- The Zed keymap.  Global workspace bindings live in setup(); editor bindings
-- are applied buffer-locally so pickers, panels, and terminals keep their own
-- keys.
local api = vim.api
local M = {}

local map = vim.keymap.set
local function o(desc)
  return { noremap = true, silent = true, desc = desc }
end

local function cmd(fn)
  return function()
    fn()
  end
end

local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "n", false)
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO)
end

local function project_root()
  local bufname = api.nvim_buf_get_name(0)
  local root = vim.fs.root(bufname ~= "" and bufname or 0, {
    ".git",
    "package.json",
    "pnpm-workspace.yaml",
    "Cargo.toml",
    "go.mod",
    "pyproject.toml",
    "Makefile",
  })
  return root or (vim.uv and vim.uv.cwd()) or vim.fn.getcwd()
end

-- ---------------------------------------------------------------------------
-- Small editing helpers
-- ---------------------------------------------------------------------------
function M.copy_line()
  local line = api.nvim_get_current_line()
  vim.fn.setreg("+", line, "l")
end

function M.cut_line()
  M.copy_line()
  vim.cmd("normal! \"_dd")
end

function M.delete_line()
  vim.cmd("normal! \"_dd")
end

function M.select_all()
  vim.cmd("normal! ggVG")
end

function M.move_line_down()
  local n = api.nvim_buf_line_count(0)
  local r = api.nvim_win_get_cursor(0)[1]
  if r < n then
    vim.cmd("m .+1")
    vim.cmd("normal! ==")
  end
end

function M.move_line_up()
  local r = api.nvim_win_get_cursor(0)[1]
  if r > 1 then
    vim.cmd("m .-2")
    vim.cmd("normal! ==")
  end
end

function M.duplicate_down()
  vim.cmd("normal! yyp")
end

function M.duplicate_up()
  vim.cmd("normal! yyP")
end

function M.insert_line_below()
  vim.cmd("normal! o")
end

function M.insert_line_above()
  vim.cmd("normal! O")
end

function M.undo()
  if vim.fn.mode():match("[iR]") then
    vim.cmd("undo")
  else
    vim.cmd("normal! u")
  end
end

function M.redo()
  if vim.fn.mode():match("[iR]") then
    vim.cmd("redo")
  else
    vim.cmd("normal! \18")
  end
end

function M.toggle_wrap()
  vim.wo.wrap = not vim.wo.wrap
  notify("Soft wrap " .. (vim.wo.wrap and "on" or "off"))
end

function M.go_to_line()
  local n = vim.fn.input("Go to line: ")
  if n ~= "" and tonumber(n) then
    local line = math.max(1, math.min(tonumber(n), api.nvim_buf_line_count(0)))
    api.nvim_win_set_cursor(0, { line, 0 })
    vim.cmd("normal! zz")
  end
  vim.cmd("startinsert")
end

function M.jump_back()
  local was_insert = vim.fn.mode():match("[iR]") ~= nil
  if was_insert then
    vim.cmd("stopinsert")
  end
  vim.cmd("normal! \15")
  if was_insert then
    vim.cmd("startinsert")
  end
end

function M.jump_forward()
  local was_insert = vim.fn.mode():match("[iR]") ~= nil
  if was_insert then
    vim.cmd("stopinsert")
  end
  vim.cmd("normal! \9")
  if was_insert then
    vim.cmd("startinsert")
  end
end

function M.save()
  vim.cmd("silent! write")
end

function M.save_all()
  vim.cmd("silent! wall")
end

function M.save_as()
  local current = api.nvim_buf_get_name(0)
  local path = vim.fn.input("Save as: ", current, "file")
  if path ~= "" then
    vim.cmd("saveas " .. vim.fn.fnameescape(path))
  end
  vim.cmd("startinsert")
end

function M.save_without_format()
  vim.b.disable_autoformat = true
  vim.cmd("silent! write")
  vim.b.disable_autoformat = nil
end

function M.new_file()
  vim.cmd("enew")
  vim.cmd("startinsert")
end

function M.new_window()
  vim.cmd("vsplit")
  vim.cmd("enew")
  vim.cmd("startinsert")
end

-- ---------------------------------------------------------------------------
-- Panels / finders
-- ---------------------------------------------------------------------------
function M.find_files()
  local ok, builtin = pcall(require, "telescope.builtin")
  if not ok then
    return
  end
  builtin.find_files({
    cwd = project_root(),
    hidden = true,
    no_ignore = false,
    find_command = {
      "rg", "--files", "--hidden", "--follow",
      "--glob", "!.git", "--glob", "!node_modules", "--glob", "!dist", "--glob", "!.next",
    },
  })
end

function M.recent_files()
  local ok, builtin = pcall(require, "telescope.builtin")
  if ok then
    builtin.oldfiles({})
  end
end

function M.command_palette()
  local ok, builtin = pcall(require, "telescope.builtin")
  if ok then
    builtin.commands({})
  end
end

function M.project_symbols()
  local ok, builtin = pcall(require, "telescope.builtin")
  if not ok then
    return
  end
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if #clients == 0 then
    notify("No language server attached", vim.log.levels.WARN)
    return
  end
  builtin.lsp_dynamic_workspace_symbols({})
end

function M.find_in_buffer()
  local default = nil
  local mode = vim.fn.mode()
  if mode:match("[vV\22]") then
    local s = vim.fn.getpos("v")
    local e = vim.fn.getpos(".")
    local lines = api.nvim_buf_get_text(0, s[2] - 1, math.max(s[3] - 1, 0), e[2] - 1, e[3], {})
    default = table.concat(lines, "\n")
    vim.cmd("normal! \27")
  end
  local ok, builtin = pcall(require, "telescope.builtin")
  if ok then
    builtin.current_buffer_fuzzy_find({ default_text = default })
  end
end

function M.project_search()
  local default = nil
  if vim.fn.mode():match("[vV\22]") then
    local s = vim.fn.getpos("v")
    local e = vim.fn.getpos(".")
    local lines = api.nvim_buf_get_text(0, s[2] - 1, math.max(s[3] - 1, 0), e[2] - 1, e[3], {})
    default = table.concat(lines, "\n")
    vim.cmd("normal! \27")
  end
  local ok, builtin = pcall(require, "telescope.builtin")
  if ok then
    builtin.live_grep({
      default_text = default,
      cwd = project_root(),
      additional_args = { "--hidden", "--glob", "!.git", "--glob", "!node_modules" },
    })
  end
end

function M.project_replace()
  local ok, grug = pcall(require, "grug-far")
  if not ok then
    notify("grug-far is not installed", vim.log.levels.WARN)
    return
  end
  local prefills = { paths = project_root() }
  if vim.fn.mode():match("[vV\22]") then
    local s = vim.fn.getpos("v")
    local e = vim.fn.getpos(".")
    local lines = api.nvim_buf_get_text(0, s[2] - 1, math.max(s[3] - 1, 0), e[2] - 1, e[3], {})
    prefills.search = table.concat(lines, "\n")
    vim.cmd("normal! \27")
  end
  grug.open({ prefills = prefills })
end

function M.buffer_replace()
  local ok, grug = pcall(require, "grug-far")
  if not ok then
    return
  end
  local name = api.nvim_buf_get_name(0)
  if name == "" then
    return
  end
  grug.open({ prefills = { paths = name } })
end

function M.toggle_project_panel()
  local ok, manager = pcall(require, "neo-tree.sources.manager")
  if not ok then
    return
  end
  local state = manager.get_state("filesystem")
  if state and state.winid and api.nvim_win_is_valid(state.winid) then
    if api.nvim_get_current_win() == state.winid then
      vim.cmd("Neotree close")
    else
      api.nvim_set_current_win(state.winid)
    end
  else
    vim.cmd("Neotree show filesystem left reveal=true")
    local new_state = manager.get_state("filesystem")
    if new_state and new_state.winid and api.nvim_win_is_valid(new_state.winid) then
      api.nvim_set_current_win(new_state.winid)
    end
  end
end

function M.toggle_outline()
  local ok = pcall(vim.cmd, "Trouble symbols toggle focus=true")
  if not ok then
    notify("trouble.nvim is not installed", vim.log.levels.WARN)
  end
end

function M.toggle_diagnostics()
  local ok = pcall(vim.cmd, "Trouble diagnostics toggle focus=true")
  if not ok then
    notify("trouble.nvim is not installed", vim.log.levels.WARN)
  end
end

function M.toggle_git_panel()
  require("config.git").status()
end

-- ---------------------------------------------------------------------------
-- Windows / panes
-- ---------------------------------------------------------------------------
function M.focus_left()
  vim.cmd("wincmd h")
end

function M.focus_right()
  vim.cmd("wincmd l")
end

function M.focus_up()
  vim.cmd("wincmd k")
end

function M.focus_down()
  vim.cmd("wincmd j")
end

function M.split_right()
  vim.cmd("vsplit")
end

function M.split_down()
  vim.cmd("split")
end

function M.move_pane_left()
  vim.cmd("wincmd H")
end

function M.move_pane_right()
  vim.cmd("wincmd L")
end

function M.move_pane_up()
  vim.cmd("wincmd K")
end

function M.move_pane_down()
  vim.cmd("wincmd J")
end

function M.focus_pane(index)
  local wins = api.nvim_tabpage_list_wins(0)
  local win = wins[index + 1]
  if win then
    api.nvim_set_current_win(win)
  end
end

function M.move_to_next_pane()
  vim.cmd("wincmd w")
end

function M.move_to_prev_pane()
  vim.cmd("wincmd W")
end

-- ---------------------------------------------------------------------------
-- LSP
-- ---------------------------------------------------------------------------
local function has_lsp()
  return #vim.lsp.get_clients({ bufnr = 0 }) > 0
end

function M.definition()
  if not has_lsp() then
    notify("No language server attached", vim.log.levels.WARN)
    return
  end
  vim.lsp.buf.definition()
end

function M.definition_split()
  if not has_lsp() then
    notify("No language server attached", vim.log.levels.WARN)
    return
  end
  local win = api.nvim_get_current_win()
  local buf = api.nvim_get_current_buf()
  local pos = api.nvim_win_get_cursor(win)
  vim.cmd("vsplit")
  vim.lsp.buf.definition()
  vim.defer_fn(function()
    if api.nvim_win_is_valid(win) and api.nvim_get_current_win() ~= win then
      if api.nvim_get_current_buf() == buf and vim.deep_equal(api.nvim_win_get_cursor(0), pos) then
        vim.cmd("close")
      end
    end
  end, 350)
end

function M.type_definition()
  if has_lsp() then
    vim.lsp.buf.type_definition()
  end
end

function M.implementation()
  if has_lsp() then
    vim.lsp.buf.implementation()
  end
end

function M.references()
  local ok, builtin = pcall(require, "telescope.builtin")
  if ok and has_lsp() then
    builtin.lsp_references({ include_declaration = true })
  end
end

function M.incoming_calls()
  if has_lsp() then
    vim.lsp.buf.incoming_calls()
  end
end

function M.hover()
  if has_lsp() then
    vim.lsp.buf.hover({ border = "rounded" })
  else
    notify("No language server attached", vim.log.levels.WARN)
  end
end

function M.signature_help()
  if has_lsp() then
    vim.lsp.buf.signature_help({ border = "rounded" })
  end
end

function M.rename()
  if has_lsp() then
    vim.lsp.buf.rename()
    return
  end
  local w = vim.fn.expand("<cword>")
  if w == "" then
    return
  end
  local replacement = vim.fn.input("Rename " .. w .. " to: ")
  if replacement ~= "" then
    vim.cmd(("%%s/\\<%s\\>/%s/g"):format(vim.fn.escape(w, "/"), vim.fn.escape(replacement, "/")))
  end
  vim.cmd("startinsert")
end

function M.show_completions()
  local ok, blink = pcall(require, "blink.cmp")
  if ok and type(blink.show) == "function" then
    local shown = pcall(blink.show)
    if shown then
      return
    end
  end
  feed("<C-x><C-o>")
end

function M.code_action()
  if has_lsp() then
    vim.lsp.buf.code_action()
  end
end

function M.organize_imports()
  if has_lsp() then
    vim.lsp.buf.code_action({
      context = { only = { "source.organizeImports" }, diagnostics = {} },
      apply = true,
    })
  end
end

function M.inlay_hints()
  local enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = 0 })
  vim.lsp.inlay_hint.enable(not enabled, { bufnr = 0 })
end

function M.next_diagnostic()
  vim.diagnostic.goto_next({ wrap = true })
end

function M.prev_diagnostic()
  vim.diagnostic.goto_prev({ wrap = true })
end

function M.diagnostic_float()
  vim.diagnostic.open_float({ border = "rounded", scope = "cursor" })
end

function M.format()
  local ok, conform = pcall(require, "conform")
  if ok then
    conform.format({ async = true, lsp_format = "fallback", timeout_ms = 3000 })
  elseif has_lsp() then
    vim.lsp.buf.format({ async = true })
  else
    -- Last resort: reindent the buffer.
    local pos = api.nvim_win_get_cursor(0)
    vim.cmd("normal! gg=G")
    pcall(api.nvim_win_set_cursor, 0, pos)
  end
end

function M.format_range()
  local ok, conform = pcall(require, "conform")
  if not ok then
    return
  end
  conform.format({
    async = true,
    lsp_format = "fallback",
    range = {
      start = { vim.fn.line("'<") - 1, vim.fn.col("'<") - 1 },
      ["end"] = { vim.fn.line("'>"), vim.fn.col("'>") },
    },
  })
end

-- ---------------------------------------------------------------------------
-- Comments / folds
-- ---------------------------------------------------------------------------
function M.comment_line()
  vim.cmd("normal! gcc")
end

function M.comment_block()
  local ok, comment = pcall(require, "Comment.api")
  if ok then
    comment.toggle.blockwise.current()
  else
    vim.cmd("normal! gcc")
  end
end

function M.comment_block_visual()
  local esc = api.nvim_replace_termcodes("<Esc>", true, false, true)
  api.nvim_feedkeys(esc, "nx", false)
  local ok, comment = pcall(require, "Comment.api")
  if ok then
    comment.toggle.blockwise(vim.fn.visualmode())
  else
    vim.cmd("normal! gc")
  end
  vim.cmd("startinsert")
end

function M.toggle_fold()
  vim.cmd("normal! za")
end

function M.toggle_fold_all()
  if vim.wo.foldenable then
    vim.cmd("normal! zM")
  else
    vim.cmd("normal! zR")
  end
end

-- ---------------------------------------------------------------------------
-- Multi-cursor helpers
-- ---------------------------------------------------------------------------
local function mc()
  local ok, m = pcall(require, "multicursor-nvim")
  if ok then
    return m
  end
  return nil
end

function M.mc_add_next()
  local m = mc()
  if m then
    m.matchAddCursor(1)
  end
end

function M.mc_add_all()
  local m = mc()
  if m then
    m.matchAllAddCursors()
  end
end

function M.mc_add_above()
  local m = mc()
  if m then
    m.lineAddCursor(-1)
  end
end

function M.mc_add_below()
  local m = mc()
  if m then
    m.lineAddCursor(1)
  end
end

function M.mc_clear()
  local m = mc()
  if m then
    pcall(m.clearCursors)
  end
end

-- ---------------------------------------------------------------------------
-- Escape / insert-first
-- ---------------------------------------------------------------------------
local function escape_normal()
  local m = mc()
  if m then
    pcall(m.clearCursors)
  end
  pcall(function()
    require("blink.cmp").hide()
  end)
  if vim.v.hlsearch == 1 then
    vim.cmd("nohlsearch")
  end
  if not vim.fn.mode():match("[iR]") then
    vim.cmd("startinsert")
  end
end

local function escape_visual()
  vim.cmd("normal! \27")
  vim.cmd("startinsert")
end

-- ---------------------------------------------------------------------------
-- Keymap installation
-- ---------------------------------------------------------------------------
local function apply_editor(buf)
  local function b(modes, lhs, rhs, opts)
    map(modes, lhs, rhs, vim.tbl_extend("force", { buffer = buf, noremap = true, silent = true }, opts or {}))
  end

  -- Zed's Editor-context overrides that differ from workspace defaults.
  b({ "n", "i", "v" }, "<C-p>", cmd(M.toggle_outline), o("Outline panel"))
  b({ "n", "i", "v" }, "<C-q>", cmd(function() require("config.git").diff() end), o("Git: unified diff"))
  b({ "n", "v" }, "<C-i>", cmd(M.hover), o("Hover"))
  b({ "n", "i", "v" }, "<C-S-i>", cmd(M.hover), o("Hover"))
  b({ "n", "i" }, "<A-i>", cmd(M.hover), o("Hover"))

  -- File / buffer lifecycle
  b({ "n", "i" }, "<C-s>", cmd(M.save, "Save"), o("Save"))
  b({ "n", "i" }, "<C-S-s>", cmd(M.save_as, "Save as"), o("Save as"))
  b({ "n", "i" }, "<C-A-s>", cmd(M.save_all, "Save all"), o("Save all"))
  b({ "n", "i" }, "<C-n>", cmd(M.new_file, "New file"), o("New file"))
  b({ "n", "i" }, "<C-S-n>", cmd(M.new_window, "New window"), o("New window"))
  b({ "n", "i" }, "<C-w>", cmd(function() vim.cmd("wqa") end, "Save all and quit"), o("Save all and quit Neovim"))
  b({ "n", "i" }, "<C-f4>", cmd(require("config.buffers").close, "Close editor"), o("Close editor (saves first)"))
  b({ "n", "i" }, "<C-S-t>", cmd(require("config.buffers").reopen, "Reopen closed editor"), o("Reopen closed editor"))
  b({ "n", "i" }, "<C-Tab>", cmd(require("config.buffers").pick, "Next editor"), o("Switch editor"))
  b({ "n", "i" }, "<C-S-Tab>", cmd(require("config.buffers").prev, "Previous editor"), o("Previous editor"))
  b({ "n", "i" }, "<C-pageup>", cmd(require("config.buffers").prev, "Previous editor"), o("Previous editor"))
  b({ "n", "i" }, "<C-pagedown>", cmd(require("config.buffers").next, "Next editor"), o("Next editor"))

  -- Editing
  b({ "n", "i" }, "<C-z>", cmd(M.undo, "Undo"), o("Undo"))
  b({ "n", "i" }, "<C-y>", cmd(M.redo, "Redo"), o("Redo"))
  b({ "n", "i" }, "<C-S-z>", cmd(M.redo, "Redo"), o("Redo"))
  b({ "n", "i" }, "<C-a>", cmd(M.select_all, "Select all"), o("Select all"))
  b("i", "<C-c>", cmd(M.copy_line, "Copy line"), o("Copy line"))
  b("n", "<C-c>", cmd(M.copy_line, "Copy line"), o("Copy line"))
  b("v", "<C-c>", "\"+y<Cmd>startinsert<CR>", o("Copy"))
  b("i", "<C-x>", cmd(M.cut_line, "Cut line"), o("Cut line"))
  b("n", "<C-x>", cmd(M.cut_line, "Cut line"), o("Cut line"))
  b("v", "<C-x>", "\"+d<Cmd>startinsert<CR>", o("Cut"))
  b("i", "<C-v>", "<C-r>+", o("Paste"))
  b("n", "<C-v>", "\"+p<Cmd>startinsert<CR>", o("Paste"))
  b("v", "<C-v>", "\"_d\"+P<Cmd>startinsert<CR>", o("Paste"))
  b("i", "<C-S-k>", cmd(M.delete_line, "Delete line"), o("Delete line"))
  b({ "n", "v" }, "<C-S-k>", cmd(M.delete_line, "Delete line"), o("Delete line"))
  b("i", "<A-k>", cmd(M.delete_line, "Delete line"), o("Delete line"))
  b({ "n", "v" }, "<A-k>", cmd(M.delete_line, "Delete line"), o("Delete line"))

  b({ "n", "i" }, "<A-Down>", cmd(M.move_line_down, "Move line down"), o("Move line down"))
  b({ "n", "i" }, "<A-Up>", cmd(M.move_line_up, "Move line up"), o("Move line up"))
  b("v", "<A-Down>", ":m '>+1<CR>gv=gv", o("Move selection down"))
  b("v", "<A-Up>", ":m '<-2<CR>gv=gv", o("Move selection up"))

  b({ "n", "i" }, "<C-A-S-Down>", cmd(M.duplicate_down, "Duplicate line down"), o("Duplicate line down"))
  b({ "n", "i" }, "<C-A-S-Up>", cmd(M.duplicate_up, "Duplicate line up"), o("Duplicate line up"))
  b("v", "<C-A-S-Down>", ":t'>+1<CR>gv=gv", o("Duplicate selection down"))
  b("v", "<C-A-S-Up>", ":t'<-2<CR>gv=gv", o("Duplicate selection up"))

  b("v", "<Tab>", ">gv", o("Indent selection"))
  b("v", "<S-Tab>", "<gv", o("Outdent selection"))
  b({ "n", "v" }, "<C-]>", ">>", o("Indent line"))
  b({ "n", "i" }, "<A-]>", cmd(function() vim.cmd("normal! >>") end, "Indent line"), o("Indent line"))
  b({ "n", "i" }, "<A-[>", cmd(function() vim.cmd("normal! <<") end, "Outdent line"), o("Outdent line"))

  b({ "n", "i" }, "<C-CR>", cmd(M.insert_line_below, "Insert line below"), o("Insert line below"))
  b({ "n", "i" }, "<C-S-CR>", cmd(M.insert_line_above, "Insert line above"), o("Insert line above"))
  b("v", "<C-CR>", "<Esc>o", o("Insert line below"))
  b("v", "<C-S-CR>", "<Esc>O", o("Insert line above"))

  b({ "n", "i" }, "<C-/>", cmd(M.comment_line, "Toggle comment"), o("Toggle comment"))
  b({ "n", "i" }, "<C-_>", cmd(M.comment_line, "Toggle comment"), o("Toggle comment"))
  b("v", "<C-/>", "gc", o("Toggle comment"))
  b("v", "<C-_>", "gc", o("Toggle comment"))
  b({ "n", "i" }, "<C-S-a>", cmd(M.comment_block, "Toggle block comment"), o("Toggle block comment"))
  b("v", "<C-S-a>", cmd(M.comment_block_visual), o("Toggle block comment"))

  b({ "n", "i" }, "<A-S-f>", cmd(M.format), o("Format document"))
  b("v", "<A-S-f>", cmd(M.format_range), o("Format selection"))
  b({ "n", "i" }, "<F2>", cmd(M.rename), o("Rename symbol"))
  b({ "n", "i" }, "<C-.>", cmd(M.code_action), o("Code action"))
  b({ "n", "i" }, "<C-Space>", cmd(M.show_completions), o("Show completions"))
  b({ "n", "i" }, "<C-S-Space>", cmd(M.signature_help), o("Signature help"))
  b({ "n", "i" }, "<A-S-o>", cmd(M.organize_imports), o("Organize imports"))
  b({ "n", "i" }, "<C-:>", cmd(M.inlay_hints), o("Toggle inlay hints"))
  b({ "n", "i" }, "<A-z>", cmd(M.toggle_wrap), o("Toggle soft wrap"))
  b("v", "<A-z>", cmd(M.toggle_wrap), o("Toggle soft wrap"))

  -- Multi-cursor / selection
  b({ "n", "i", "v" }, "<C-d>", cmd(M.mc_add_next, "Add next occurrence"), o("Add next occurrence"))
  b({ "n", "i", "v" }, "<C-f2>", cmd(M.mc_add_all, "Select all occurrences"), o("Select all occurrences"))
  b({ "n", "i", "v" }, "<S-A-Down>", cmd(M.mc_add_below, "Add cursor below"), o("Add cursor below"))
  b({ "n", "i", "v" }, "<S-A-Up>", cmd(M.mc_add_above, "Add cursor above"), o("Add cursor above"))
  b({ "n", "i", "v" }, "<C-S-d>", cmd(function() require("config.selection").expand() end, "Expand selection"), o("Expand selection"))
  b({ "n", "i", "v" }, "<A-S-Right>", cmd(function() require("config.selection").expand() end, "Expand selection"), o("Expand selection"))
  b({ "n", "i", "v" }, "<A-S-Left>", cmd(function() require("config.selection").shrink() end, "Shrink selection"), o("Shrink selection"))

  -- Search / navigation
  b({ "n", "i", "v" }, "<C-f>", cmd(M.find_in_buffer, "Find in file"), o("Find in file"))
  b({ "n", "i", "v" }, "<C-S-f>", cmd(M.project_search, "Find in project"), o("Find in project"))
  b({ "n", "i", "v" }, "<C-h>", cmd(M.buffer_replace, "Replace in file"), o("Replace in file"))
  b({ "n", "i", "v" }, "<C-S-h>", cmd(M.project_replace, "Replace in project"), o("Replace in project"))
  b({ "n", "i" }, "<C-g>", cmd(M.go_to_line, "Go to line"), o("Go to line"))
  b({ "n", "i" }, "<A-Left>", cmd(M.jump_back, "Go back"), o("Go back"))
  b({ "n", "i" }, "<A-Right>", cmd(M.jump_forward, "Go forward"), o("Go forward"))
  b({ "n", "i" }, "<F3>", "n", o("Next match"))
  b({ "n", "i" }, "<S-F3>", "N", o("Previous match"))
  b({ "n", "i" }, "<C-S-c>", cmd(require("config.buffers").copy_relative_path, "Copy relative path"), o("Copy relative path"))

  -- LSP navigation
  b({ "n", "i" }, "<F12>", cmd(M.definition, "Go to definition"), o("Go to definition"))
  b({ "n", "i" }, "<A-F12>", cmd(M.definition_split, "Go to definition split"), o("Go to definition split"))
  b({ "n", "i" }, "<C-F12>", cmd(M.type_definition, "Go to type definition"), o("Go to type definition"))
  b({ "n", "i" }, "<S-F12>", cmd(M.implementation, "Go to implementation"), o("Go to implementation"))
  b({ "n", "i" }, "<A-S-F12>", cmd(M.references, "Find references"), o("Find references"))
  b({ "n", "i" }, "<A-S-h>", cmd(M.incoming_calls, "Incoming calls"), o("Incoming calls"))
  b({ "n", "i" }, "<F8>", cmd(M.next_diagnostic, "Next diagnostic"), o("Next diagnostic"))
  b({ "n", "i" }, "<S-F8>", cmd(M.prev_diagnostic, "Previous diagnostic"), o("Previous diagnostic"))
  b({ "n", "i" }, "<A-CR>", cmd(M.diagnostic_float, "Diagnostic details"), o("Diagnostic details"))

  -- Git hunks
  b({ "n", "i" }, "<C-j>", cmd(function() require("config.git").stage_hunk() end, "Stage hunk and next"), o("Stage hunk and next"))
  b({ "n", "i" }, "<A-y>", cmd(function() require("config.git").stage_hunk() end, "Stage hunk and next"), o("Stage hunk and next"))
  b({ "n", "i" }, "<A-S-y>", cmd(function() require("config.git").unstage_hunk() end, "Unstage hunk and next"), o("Unstage hunk and next"))
  b({ "n", "i" }, "<C-'>", cmd(function() require("config.git").reset_hunk() end, "Restore hunk"), o("Restore hunk"))
  b({ "n", "i" }, "<A-.>", cmd(function() require("config.git").next_hunk() end, "Next hunk"), o("Next hunk"))
  b({ "n", "i" }, "<A-,>", cmd(function() require("config.git").prev_hunk() end, "Previous hunk"), o("Previous hunk"))
  b({ "n", "i" }, "<A-g>b", cmd(function() require("config.git").blame() end, "Blame line"), o("Blame line"))
  b({ "n", "i" }, "<A-g>r", cmd(function() require("config.git").review() end, "Review diff"), o("Review diff"))
  b({ "n", "i" }, "<A-g>m", cmd(M.toggle_git_panel, "Modified files"), o("Modified files"))

  -- Folds
  b({ "n", "i" }, "<A-pageup>", cmd(M.toggle_fold, "Toggle fold"), o("Toggle fold"))
  b({ "n", "i" }, "<C-A-pageup>", cmd(M.toggle_fold_all, "Toggle all folds"), o("Toggle all folds"))

  -- Panes
  b({ "n", "i" }, "<C-\\>", cmd(M.split_right, "Split right"), o("Split right"))
  b({ "n", "i" }, "<C-S-q>", cmd(M.split_right, "Split right"), o("Split right"))
  b({ "n", "i" }, "<C-S-w>", cmd(M.focus_left, "Focus pane left"), o("Focus pane left"))
  b({ "n", "i" }, "<C-S-r>", cmd(M.focus_right, "Focus pane right"), o("Focus pane right"))
  b({ "n", "i" }, "<C-A-Left>", cmd(M.move_pane_left, "Move pane left"), o("Move pane left"))
  b({ "n", "i" }, "<C-A-Right>", cmd(M.move_pane_right, "Move pane right"), o("Move pane right"))
  b({ "n", "i" }, "<C-A-Up>", cmd(M.move_pane_up, "Move pane up"), o("Move pane up"))
  b({ "n", "i" }, "<C-A-Down>", cmd(M.move_pane_down, "Move pane down"), o("Move pane down"))
  b({ "n", "i" }, "<C-A-h>", cmd(M.focus_left, "Focus pane left"), o("Focus pane left"))
  b({ "n", "i" }, "<C-A-l>", cmd(M.focus_right, "Focus pane right"), o("Focus pane right"))
  b({ "n", "i" }, "<C-A-k>", cmd(M.focus_up, "Focus pane up"), o("Focus pane up"))
  b({ "n", "i" }, "<C-A-j>", cmd(M.focus_down, "Focus pane down"), o("Focus pane down"))
  for i = 1, 9 do
    b({ "n", "i" }, "<A-" .. i .. ">", cmd(function() M.focus_pane(i - 1) end, "Focus pane " .. i), o("Focus pane " .. i))
  end

  -- Escape: return to insert and clear transient state.
  b("n", "<Esc>", cmd(escape_normal, "Back to insert"), o("Back to insert"))
  b("v", "<Esc>", cmd(escape_visual, "Back to insert"), o("Back to insert"))
  b("n", "<CR>", "i<CR>", o("New line"))
  b("n", "<BS>", "i<BS>", o("Backspace"))
end

function M.setup()
  local terminal = require("config.terminal")
  local ai = require("config.ai")

  -- Workspace / global bindings.
  map({ "n", "i", "v" }, "<C-S-e>", cmd(M.toggle_project_panel, "Project panel"), o("Project panel"))
  map({ "n", "i", "v" }, "<C-S-g>", cmd(M.toggle_git_panel, "Git panel"), o("Git panel"))
  map({ "n", "i", "v" }, "<C-S-b>", cmd(M.toggle_outline, "Outline panel"), o("Outline panel"))
  map({ "n", "i", "v" }, "<C-S-m>", cmd(M.toggle_diagnostics, "Diagnostics"), o("Diagnostics"))
  map({ "n", "i", "v" }, "<C-S-o>", cmd(ai.toggle, "Toggle agent"), o("Toggle agent"))
  map({ "n", "i", "v" }, "<C-S-l>", cmd(ai.focus, "Focus agent"), o("Focus agent"))
  map({ "n", "i", "v" }, "<C-A-i>", cmd(ai.focus, "Focus agent"), o("Focus agent"))
  map({ "n", "i", "v" }, "<C-S-.>", cmd(ai.ask_this, "Ask OpenCode"), o("Ask OpenCode"))
  map({ "n", "i", "v" }, "<C-`>", cmd(terminal.toggle_terminal, "Toggle terminal"), o("Toggle terminal"))
  map({ "n", "i", "v" }, "<C-~>", cmd(terminal.new_terminal, "New terminal"), o("New terminal"))
  map({ "n", "i", "v" }, "<C-A-S-o>", cmd(function() require("config.remote").remote_start("") end, "Open remote project"), o("Open remote project"))

  -- Workspace finders.  Editor buffers override Ctrl+P with the outline.
  map({ "n", "i", "v" }, "<C-p>", cmd(M.find_files, "File finder"), o("File finder"))
  map({ "n", "i", "v" }, "<C-e>", cmd(M.find_files, "File finder"), o("File finder"))
  map({ "n", "i", "v" }, "<C-r>", cmd(M.recent_files, "Recent files"), o("Recent files"))
  map({ "n", "i", "v" }, "<C-u>", cmd(M.command_palette, "Command palette"), o("Command palette"))
  map({ "n", "v" }, "<C-o>", cmd(M.project_symbols, "Project symbols"), o("Project symbols"))
  map({ "i" }, "<C-A-o>", cmd(M.project_symbols, "Project symbols"), o("Project symbols"))
  map({ "n", "i", "v" }, "<C-n>", cmd(M.new_file, "New file"), o("New file"))
  map({ "n", "i", "v" }, "<C-S-n>", cmd(M.new_window, "New window"), o("New window"))

  -- Apply editor-local bindings.
  local excluded = {
    ["TelescopePrompt"] = true,
    ["TelescopeResults"] = true,
    ["neo-tree"] = true,
    ["Trouble"] = true,
    ["trouble"] = true,
    ["grug-far"] = true,
    ["diff"] = true,
    ["DiffviewFiles"] = true,
    ["DiffviewFilePanel"] = true,
    ["help"] = true,
    ["lazy"] = true,
    ["mason"] = true,
  }
  local group = api.nvim_create_augroup("ZedKeymaps", { clear = true })
  api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
    group = group,
    callback = function(args)
      local buf = args.buf
      if api.nvim_buf_is_valid(buf)
        and vim.bo[buf].buftype == ""
        and not excluded[vim.bo[buf].filetype]
      then
        apply_editor(buf)
      end
    end,
    desc = "Install Zed editor keymaps",
  })

  -- Also cover the initial empty buffer.
  apply_editor(api.nvim_get_current_buf())

  terminal.setup_keymaps()
end

M.setup()

return M

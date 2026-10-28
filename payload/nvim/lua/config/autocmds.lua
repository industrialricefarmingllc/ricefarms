-- Autocommands: the behaviour that makes Neovim feel like a normal editor.
local api = vim.api
local uv = vim.uv or vim.loop

-- ---------------------------------------------------------------------------
-- Transparent background (kept from the existing config)
-- ---------------------------------------------------------------------------
local transparent_groups = {
  "Normal", "NormalNC", "NormalFloat", "FloatBorder", "FloatTitle",
  "SignColumn", "EndOfBuffer", "LineNr", "FoldColumn", "Folded",
  "WinSeparator", "VertSplit", "StatusLine", "StatusLineNC",
  "TabLine", "TabLineFill", "TabLineSel", "MsgSeparator",
  "CursorColumn", "ColorColumn",
  "TelescopeNormal", "TelescopeBorder", "TelescopePromptNormal",
  "TelescopeResultsNormal", "TelescopePreviewNormal",
  "NeoTreeNormal", "NeoTreeNormalNC", "NeoTreeWinSeparator",
  "LazyNormal", "MasonNormal", "WhichKeyNormal", "NoiceNormal",
  "Pmenu", "PmenuSbar", "PmenuThumb",
  "TroubleNormal", "TroubleNormalNC",
  "DiffviewNormal", "DiffviewStatusLine", "DiffviewStatusLineNC",
  "GrugFarNormal", "GrugFarHelpWinNormal",
}

local function make_transparent()
  for _, name in ipairs(transparent_groups) do
    api.nvim_set_hl(0, name, { bg = "none", ctermbg = "none" })
  end
  api.nvim_set_hl(0, "CursorLine", { bg = "none", ctermbg = "none" })
  api.nvim_set_hl(0, "CursorLineNr", { bg = "none", ctermbg = "none", bold = true })
  api.nvim_set_hl(0, "PmenuSel", { bg = "none", reverse = true })
end

make_transparent()
api.nvim_create_autocmd({ "ColorScheme", "VimEnter", "UIEnter" }, {
  callback = make_transparent,
  desc = "Force transparent background",
})

-- ---------------------------------------------------------------------------
-- Diagnostics: inline text, compact signs, rounded floats
-- ---------------------------------------------------------------------------
vim.diagnostic.config({
  severity_sort = true,
  update_in_insert = false,
  underline = true,
  virtual_text = {
    spacing = 2,
    prefix = "●",
    source = "if_many",
  },
  float = {
    border = "rounded",
    source = true,
    header = "",
    focusable = false,
  },
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = "E",
      [vim.diagnostic.severity.WARN] = "W",
      [vim.diagnostic.severity.INFO] = "I",
      [vim.diagnostic.severity.HINT] = "H",
    },
    texthl = {
      [vim.diagnostic.severity.ERROR] = "DiagnosticSignError",
      [vim.diagnostic.severity.WARN] = "DiagnosticSignWarn",
      [vim.diagnostic.severity.INFO] = "DiagnosticSignInfo",
      [vim.diagnostic.severity.HINT] = "DiagnosticSignHint",
    },
  },
})

-- ---------------------------------------------------------------------------
-- Insert-first behaviour (the "no Vim mode" request)
-- ---------------------------------------------------------------------------
local non_editor_filetypes = {
  ["neo-tree"] = true,
  ["TelescopePrompt"] = true,
  ["TelescopeResults"] = true,
  ["TelescopePreview"] = true,
  ["Trouble"] = true,
  ["trouble"] = true,
  ["grug-far"] = true,
  ["grug-far-help"] = true,
  ["lazy"] = true,
  ["mason"] = true,
  ["help"] = true,
  ["man"] = true,
  ["qf"] = true,
  ["diff"] = true,
  ["diffview"] = true,
  ["DiffviewFiles"] = true,
  ["DiffviewFilePanel"] = true,
  ["fugitive"] = true,
  ["fugitiveblame"] = true,
  ["git"] = true,
  ["gitcommit"] = false,
  ["gitrebase"] = false,
  ["NeogitStatus"] = true,
  ["NeogitCommitMessage"] = false,
  ["NvimTree"] = true,
  ["minifiles"] = true,
  ["snacks_picker_input"] = true,
  ["snacks_picker_list"] = true,
  ["snacks_input"] = true,
  ["dap-repl"] = true,
  ["dapui_scopes"] = true,
  ["dapui_breakpoints"] = true,
  ["dapui_stacks"] = true,
  ["dapui_watches"] = true,
  ["dapui_console"] = true,
  ["dapui_help"] = true,
  ["opencode"] = true,
  ["checkhealth"] = true,
}

local function should_start_insert(buf)
  if not api.nvim_buf_is_valid(buf) then
    return false
  end
  if vim.bo[buf].buftype ~= "" then
    return false
  end
  if non_editor_filetypes[vim.bo[buf].filetype] then
    return false
  end
  if vim.bo[buf].readonly then
    return false
  end
  if vim.fn.mode() ~= "n" then
    return false
  end
  return true
end

-- On a remote-nvim server, wait for remote-nvim's readiness probe before
-- entering Insert.  The probe is sent as `:lua vim.g.remote_neovim_host=true`
-- via --remote-send; if we are already in Insert it would be typed into the
-- buffer instead of executed.
local is_remote = (vim.env.SSH_CONNECTION or vim.env.SSH_TTY) ~= nil
local remote_ready = not is_remote

local function start_insert()
  if not remote_ready then
    return
  end
  if should_start_insert(api.nvim_get_current_buf()) then
    vim.cmd("startinsert")
  end
end

if is_remote then
  local function mark_remote_ready()
    if remote_ready then
      return
    end
    remote_ready = true
    start_insert()
  end

  vim.defer_fn(mark_remote_ready, 4000)
  local timer = uv.new_timer()
  if timer then
    timer:start(300, 250, vim.schedule_wrap(function()
      if vim.g.remote_neovim_host then
        if not timer:is_closing() then
          timer:stop()
          timer:close()
        end
        mark_remote_ready()
      end
    end))
  end
end

api.nvim_create_autocmd({ "VimEnter", "BufEnter", "WinEnter" }, {
  callback = start_insert,
  desc = "Start in Insert mode, like a normal editor",
})

-- Don't auto-insert while an autocmd/plugin is opening a picker or prompt.
-- (UI buffers such as Telescope set their own mode; we only skip our
-- insert-on-enter rule, never force stopinsert.)

-- ---------------------------------------------------------------------------
-- Autosave on focus change / leaving Insert (Zed: on_focus_change)
-- ---------------------------------------------------------------------------
local function buffer_is_savable(buf)
  if not api.nvim_buf_is_valid(buf) or not vim.bo[buf].modifiable then
    return false
  end
  if vim.bo[buf].readonly or vim.bo[buf].buftype ~= "" then
    return false
  end
  local name = api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].filetype == "fugitive" then
    return false
  end
  return vim.bo[buf].modified
end

local function save_buffer(buf)
  if buffer_is_savable(buf) then
    api.nvim_buf_call(buf, function()
      vim.cmd("silent! update")
    end)
  end
end

local function save_all()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    save_buffer(buf)
  end
end

api.nvim_create_autocmd({ "InsertLeave", "FocusLost", "BufLeave", "VimLeavePre" }, {
  callback = function()
    save_buffer(api.nvim_get_current_buf())
  end,
  desc = "Autosave when leaving Insert or changing focus",
})
api.nvim_create_autocmd("VimLeavePre", {
  callback = save_all,
  desc = "Autosave everything on exit",
})

-- ---------------------------------------------------------------------------
-- Remove trailing whitespace on save (Zed: remove_trailing_whitespace_on_save)
-- ---------------------------------------------------------------------------
api.nvim_create_autocmd("BufWritePre", {
  callback = function(args)
    if vim.bo[args.buf].buftype ~= "" then
      return
    end
    if vim.bo[args.buf].filetype == "diff" or vim.bo[args.buf].filetype == "fugitive" then
      return
    end
    local view = vim.fn.winsaveview()
    local lines = api.nvim_buf_get_lines(args.buf, 0, -1, false)
    local changed = false
    for i, line in ipairs(lines) do
      local trimmed = line:gsub("%s+$", "")
      if trimmed ~= line then
        lines[i] = trimmed
        changed = true
      end
    end
    if changed then
      api.nvim_buf_set_lines(args.buf, 0, -1, false, lines)
      vim.fn.winrestview(view)
    end
  end,
  desc = "Strip trailing whitespace on save",
})

-- ---------------------------------------------------------------------------
-- Restore cursor position
-- ---------------------------------------------------------------------------
api.nvim_create_autocmd("BufReadPost", {
  callback = function(args)
    local mark = api.nvim_buf_get_mark(args.buf, '"')
    local lnum = mark[1]
    if lnum > 0 and lnum <= api.nvim_buf_line_count(args.buf) then
      pcall(api.nvim_win_set_cursor, 0, { lnum, mark[2] })
    end
  end,
  desc = "Restore last cursor position",
})

-- ---------------------------------------------------------------------------
-- Highlight yanked text
-- ---------------------------------------------------------------------------
api.nvim_create_autocmd("TextYankPost", {
  callback = function()
    vim.hl.on_yank({ higroup = "IncSearch", timeout = 150 })
  end,
  desc = "Briefly highlight yanked text",
})

-- ---------------------------------------------------------------------------
-- Filetype tweaks
-- ---------------------------------------------------------------------------
api.nvim_create_autocmd("FileType", {
  callback = function(args)
    local ft = vim.bo[args.buf].filetype
    local bo = vim.bo[args.buf]
    local wo = vim.wo

    if ft == "python" or ft == "rust" or ft == "java" or ft == "c" or ft == "cpp" then
      bo.expandtab = true
      bo.shiftwidth = 4
      bo.tabstop = 4
      bo.softtabstop = 4
    elseif ft == "go" then
      bo.expandtab = false
      bo.shiftwidth = 4
      bo.tabstop = 4
      bo.softtabstop = 4
    elseif ft == "make" or ft == "makefile" then
      bo.expandtab = false
      bo.tabstop = 4
      bo.shiftwidth = 4
    elseif ft == "yaml" or ft == "json" or ft == "jsonc" or ft == "lua" or ft == "javascript"
      or ft == "typescript" or ft == "javascriptreact" or ft == "typescriptreact"
      or ft == "svelte" or ft == "css" or ft == "scss" or ft == "html" then
      bo.expandtab = true
      bo.shiftwidth = 2
      bo.tabstop = 2
      bo.softtabstop = 2
    end

    if ft == "gitcommit" or ft == "gitrebase" then
      bo.textwidth = 72
      bo.wrapmargin = 0
      wo.wrap = true
      wo.linebreak = true
    end

    if ft == "markdown" then
      wo.wrap = true
      wo.linebreak = true
      wo.conceallevel = 0
    end
  end,
  desc = "Language-specific indentation and wrapping",
})

-- Terminal buffers should look like a terminal, not a code buffer.
api.nvim_create_autocmd("TermOpen", {
  callback = function()
    vim.opt_local.number = false
    vim.opt_local.relativenumber = false
    vim.opt_local.signcolumn = "no"
    vim.opt_local.cursorline = false
    vim.opt_local.spell = false
    vim.opt_local.wrap = false
  end,
  desc = "Terminal buffer appearance",
})

-- Don't show the "Press ENTER" prompt for common messages.
api.nvim_create_autocmd("CmdlineLeave", {
  callback = function()
    vim.o.cmdheight = 1
  end,
})

-- Redraw statusline after write (shows the saved indicator).
api.nvim_create_autocmd({ "BufWritePost", "BufEnter" }, {
  callback = function()
    vim.cmd("redrawstatus!")
  end,
})

-- When running inside a remote-nvim UI, make it obvious in the title.
api.nvim_create_autocmd("VimEnter", {
  callback = function()
    if vim.g.remote_neovim_host or vim.env.SSH_CONNECTION or vim.env.SSH_TTY then
      local host = vim.uv.os_gethostname()
      vim.o.title = true
      vim.o.titlestring = ("nvim [remote:%s] %%"):format(host)
    end
  end,
})

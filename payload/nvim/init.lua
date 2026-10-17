-- Plugin manager (lazy.nvim) bootstrap
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

require("lazy").setup({
  {
    "amitds1997/remote-nvim.nvim",
    version = "*",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
      "nvim-telescope/telescope.nvim",
    },
    -- Open the remote UI in its own Kitty window instead of a nested
    -- floating popup. NOTE: keep this nvim open (it owns the tunnel and
    -- the remote server dies with it); do your work in the new window.
    config = function()
      require("remote-nvim").setup({
        client_callback = function(port, _)
          vim.fn.jobstart(("kitty -e nvim --server localhost:%s --remote-ui"):format(port), {
            detach = true,
            on_exit = function(_, exit_code, _)
              if exit_code ~= 0 then
                vim.notify(("Remote client exited with code %s"):format(exit_code), vim.log.levels.ERROR)
              end
            end,
          })
        end,
      })
    end,
  },
  {
    "nvim-telescope/telescope.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      require("telescope").setup({
        defaults = {
          file_ignore_patterns = { "node_modules/", ".git/" },
        },
      })
    end,
  },
})

-- :SSH / :ssh shortcut for :RemoteStart (custom commands must be uppercase,
-- so :SSH is the real command; lowercase :ssh is rewritten by the <CR>
-- intercept below. NOTE: a cnoreabbrev can't do this: an <expr> abbrev
-- triggered by Enter evaluates after submit, so getcmdtype() is no longer
-- ":" and bare :ssh<CR> fails with E492.)
vim.api.nvim_create_user_command("SSH", function(opts)
  vim.cmd("RemoteStart " .. opts.args)
end, { nargs = "*", desc = "Alias: remote SSH (RemoteStart)" })
-- NOTE: vim.keymap.set directly: `map` helper is defined further down
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

-- Always transparent background
vim.opt.termguicolors = true

local groups = {
  "Normal",
  "NormalNC",
  "NormalFloat",
  "FloatBorder",
  "FloatTitle",
  "SignColumn",
  "EndOfBuffer",
  "LineNr",
  "FoldColumn",
  "Folded",
  "WinSeparator",
  "VertSplit",
  "StatusLine",
  "StatusLineNC",
  "TabLine",
  "TabLineFill",
  "TabLineSel",
  "MsgSeparator",
  "CursorColumn",
  "ColorColumn",
  -- Common plugins (ignored if not installed)
  "TelescopeNormal",
  "TelescopeBorder",
  "NvimTreeNormal",
  "NvimTreeNormalNC",
  "NeoTreeNormal",
  "NeoTreeNormalNC",
  "LazyNormal",
  "MasonNormal",
  "WhichKeyNormal",
  "NoiceNormal",
  "Pmenu",
}

local function make_transparent()
  for _, name in ipairs(groups) do
    vim.api.nvim_set_hl(0, name, { bg = "none", ctermbg = "none" })
  end
  -- Active line: no grey wash at all (a `>` in the gutter marks it instead)
  vim.api.nvim_set_hl(0, "CursorLine", { bg = "none", ctermbg = "none" })
  vim.api.nvim_set_hl(0, "CursorLineNr", { bg = "none", ctermbg = "none" })
  -- Keep selection readable but still transparent-friendly
  vim.api.nvim_set_hl(0, "PmenuSel", { bg = "none", reverse = true })
end

-- Apply now
make_transparent()

-- Re-apply on every colorscheme change + startup so it's *always* transparent
vim.api.nvim_create_autocmd({ "ColorScheme", "VimEnter", "UIEnter" }, {
  pattern = "*",
  callback = make_transparent,
  desc = "Force transparent background",
})

-- VSCode-like behavior (stay in Insert, no Vim motions required)
vim.opt.mouse = "a"
vim.opt.clipboard = "unnamedplus"
vim.opt.number = true
vim.opt.cursorline = true -- stays on for the CursorLineNr tint; no background wash
vim.opt.cursorcolumn = false
-- `>` gutter marker on the active line instead of an underline.
-- v:relnum == 0 is only ever true on the real cursor line, and the
-- v:virtnum guard keeps wrapped continuation rows unmarked.
vim.opt.statuscolumn = "%s%#CursorLineNr#%{(v:virtnum == 0 && v:relnum == 0) ? '> ' : '  '}%*%=%l "
vim.opt.wrap = true
vim.opt.linebreak = true
vim.opt.expandtab = true
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.softtabstop = 2
vim.opt.smartindent = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.hlsearch = true
vim.opt.incsearch = true
vim.opt.undofile = true
vim.opt.showmode = false
-- Autosave: write on leave / pause / focus loss, silently
vim.opt.autowrite = true
vim.opt.autowriteall = true
vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged", "TextChangedI", "BufLeave", "FocusLost" }, {
  pattern = "*",
  callback = function()
    if vim.bo.modifiable and not vim.bo.readonly and vim.fn.expand("%") ~= "" and vim.bo.buftype == "" then
      vim.cmd("silent! wall")
    end
  end,
  desc = "Autosave all changed files",
})
vim.opt.splitbelow = true
vim.opt.splitright = true
vim.opt.scrolloff = 4
vim.opt.updatetime = 200
-- Quick-open helpers
vim.opt.wildmenu = true
vim.opt.wildmode = "longest:full,full"
vim.opt.path:append("**")
vim.opt.wildignore:append({ "*/node_modules/*", "*/.git/*", "*/dist/*", "*/build/*" })
-- Shift+Arrows select like VSCode / Windows
vim.opt.keymodel = "startsel,stopsel"
vim.opt.selection = "inclusive"
-- rg for find-in-files when available
if vim.fn.executable("rg") == 1 then
  vim.opt.grepprg = "rg --vimgrep --smart-case"
  vim.opt.grepformat = "%f:%l:%c:%m"
end

-- Start in Insert like a normal editor
vim.api.nvim_create_autocmd({ "VimEnter", "BufEnter", "WinEnter" }, {
  pattern = "*",
  callback = function()
    if vim.fn.mode() == "n" and vim.bo.buftype == "" then
      vim.cmd("startinsert")
    end
  end,
  desc = "Always enter Insert mode",
})

local map = vim.keymap.set
local opts = { noremap = true, silent = true }
local function O(desc)
  return vim.tbl_extend("force", opts, { desc = desc })
end

-- ============ helpers (stock nvim, no plugins) ============
local function move_line_down()
  local n = vim.api.nvim_buf_line_count(0)
  local r = vim.api.nvim_win_get_cursor(0)[1]
  if r < n then
    vim.cmd("m .+1")
    vim.cmd("normal! ==")
  end
end

local function move_line_up()
  local r = vim.api.nvim_win_get_cursor(0)[1]
  if r > 1 then
    vim.cmd("m .-2")
    vim.cmd("normal! ==")
  end
end

local function format_buffer()
  -- Prefer LSP when attached, else reindent
  local ok = false
  pcall(function()
    ok = #vim.lsp.get_clients({ bufnr = 0 }) > 0
  end)
  if ok then
    vim.lsp.buf.format({ async = false })
  else
    local pos = vim.api.nvim_win_get_cursor(0)
    vim.cmd("normal! gg=G")
    pcall(vim.api.nvim_win_set_cursor, 0, pos)
  end
end

local function rename_symbol()
  local ok = false
  pcall(function()
    ok = #vim.lsp.get_clients({ bufnr = 0 }) > 0
  end)
  if ok then
    vim.lsp.buf.rename()
  else
    local w = vim.fn.expand("<cword>")
    vim.fn.feedkeys(":%s/\\<" .. w .. "\\>//g" .. vim.api.nvim_replace_termcodes("<Left><Left>", true, false, true), "n")
  end
end

local function go_to_line()
  local n = vim.fn.input("Go to line: ")
  if n ~= "" and tonumber(n) then
    vim.cmd(n)
  end
end

local function find_in_files()
  local q = vim.fn.input("Find in files: ")
  if q ~= "" then
    vim.cmd("grep! " .. vim.fn.shellescape(q))
    vim.cmd("copen")
  end
end

local function toggle_terminal()
  -- Close terminal buffer if visible, else open one below
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].buftype == "terminal" then
      vim.api.nvim_buf_delete(b, { force = false })
      return
    end
  end
  vim.cmd("botright 12split | terminal")
  vim.cmd("startinsert")
end

local function toggle_explorer()
  -- Built-in netrw, no plugins needed
  local ok, _ = pcall(vim.cmd, "Lexplore")
  if not ok then
    vim.cmd("Explore")
  end
end

-- ============ FILE ============
-- New / Open / Save / Save As / Save All
map({ "n", "v", "i" }, "<C-n>", "<Esc><Cmd>enew<CR>", O("VSCode: New file"))
map({ "n", "v" }, "<C-o>", ":e ", { noremap = true, silent = false, desc = "VSCode: Open file" })
-- NOTE: no <C-o> in Insert: <C-O> is the temp-Normal prefix Insert maps rely on
map({ "n", "v" }, "<C-p>", ":find ", { noremap = true, silent = false, desc = "VSCode: Quick open" })
-- Quick file navigator (Telescope fuzzy finder, VSCode Ctrl+P-style).
-- NOTE: no `c` map: <C-r> is the register prefix on the command line.
-- Trade-off: Normal <C-r> is no longer redo (redo stays on Ctrl+Y).
map("n", "<C-r>", "<Cmd>Telescope find_files<CR>", O("VSCode: Quick file navigator"))
map("v", "<C-r>", "<Esc><Cmd>Telescope find_files<CR>", O("VSCode: Quick file navigator"))
map("i", "<C-r>", "<Esc><Cmd>Telescope find_files<CR>", O("VSCode: Quick file navigator"))
map("i", "<C-s>", "<C-O><Cmd>w<CR>", O("VSCode: Save"))
map({ "n", "v" }, "<C-s>", "<Cmd>w<CR>", O("VSCode: Save"))
-- Ctrl+Shift+S rarely reaches terminal as distinct from Ctrl+S, so Alt+S fallback
map({ "n", "v" }, "<C-S-s>", ":saveas ", { noremap = true, silent = false, desc = "VSCode: Save As" })
map({ "n", "v" }, "<M-s>", ":saveas ", { noremap = true, silent = false, desc = "VSCode: Save As (Alt fallback)" })
map({ "n", "v", "i" }, "<C-k>s", "<Esc><Cmd>wa<CR>", O("VSCode: Save All (Ctrl+K S)"))
-- Close / reopen / quit
-- NOTE: <C-w> force-quits (q!). This intentionally takes over Vim's window
-- prefix (<C-w>w etc still works inside mappings' RHS, but you can't type
-- <C-w> manually for window commands anymore).
map({ "n", "v" }, "<C-w>", "<Cmd>q!<CR>", O("VSCode: Quit without saving"))
map("i", "<C-w>", "<Esc><Cmd>q!<CR>", O("VSCode: Quit without saving"))
map("t", "<C-w>", "<C-\\><C-n><Cmd>q!<CR>", O("VSCode: Quit without saving"))
map({ "n", "v", "i" }, "<C-q>", "<Esc><Cmd>q<CR>", O("VSCode: Quit"))
map({ "n", "v", "i" }, "<C-S-w>", "<Esc><Cmd>qa<CR>", O("VSCode: Close window"))
map({ "n", "v" }, "<C-S-t>", "<Cmd>e #<CR>", O("VSCode: Reopen closed editor"))
map({ "n", "v" }, "<M-t>", "<Cmd>e #<CR>", O("VSCode: Reopen closed editor (Alt)"))

-- ============ BASIC EDIT ============
-- Undo / Redo
map("i", "<C-z>", "<C-O>u", O("VSCode: Undo"))
map("n", "<C-z>", "u", O("VSCode: Undo"))
map("v", "<C-z>", "<Esc>u", O("VSCode: Undo"))
map("i", "<C-y>", "<C-O><C-r>", O("VSCode: Redo"))
map({ "n", "v" }, "<C-y>", "<C-r>", O("VSCode: Redo"))
map("i", "<C-S-z>", "<C-O><C-r>", O("VSCode: Redo"))
map({ "n", "v" }, "<C-S-z>", "<C-r>", O("VSCode: Redo"))

-- Select all
map("i", "<C-a>", "<Esc>ggVG", O("VSCode: Select all"))
map({ "n", "v" }, "<C-a>", "ggVG", O("VSCode: Select all"))

-- Copy / Cut / Paste (VSCode copies the line when nothing selected)
map("v", "<C-c>", '"+y', O("VSCode: Copy"))
map("n", "<C-c>", '"+yy', O("VSCode: Copy line"))
map("i", "<C-c>", "<C-O>\"+yy", O("VSCode: Copy line"))
map("v", "<C-x>", '"+d', O("VSCode: Cut"))
map("n", "<C-x>", '"+dd', O("VSCode: Cut line"))
map("i", "<C-x>", "<C-O>\"+dd", O("VSCode: Cut line"))
map("i", "<C-v>", "<C-R>+", O("VSCode: Paste"))
map("c", "<C-v>", "<C-R>+", O("VSCode: Paste"))
map("n", "<C-v>", '"+p', O("VSCode: Paste"))
map("v", "<C-v>", '"_d"+P', O("VSCode: Paste over selection"))

-- Delete line: Ctrl+Shift+K (GUI) + Alt+K (terminal fallback)
map({ "n", "v" }, "<C-S-k>", '"_dd', O("VSCode: Delete line"))
map("i", "<C-S-k>", "<C-O>\"_dd", O("VSCode: Delete line"))
map({ "n", "v" }, "<M-k>", '"_dd', O("VSCode: Delete line (Alt)"))
map("i", "<M-k>", "<C-O>\"_dd", O("VSCode: Delete line (Alt)"))

-- Duplicate line down/up: Shift+Alt+Down/Up (+ Alt+D / Alt+Shift+D fallback)
map({ "n", "i" }, "<S-A-Down>", "<Cmd>t.<CR>", O("VSCode: Copy line down"))
map({ "n", "i" }, "<S-A-Up>", "<Cmd>t.-1<CR>", O("VSCode: Copy line up"))
map({ "n", "i" }, "<M-d>", "<Cmd>t.<CR>", O("VSCode: Copy line down (Alt)"))
map({ "n", "i" }, "<M-D>", "<Cmd>t.-1<CR>", O("VSCode: Copy line up (Alt)"))
map("v", "<S-A-Down>", ":t'><CR>gv=gv", O("VSCode: Copy selection down"))
map("v", "<S-A-Up>", ":t'<-1<CR>gv=gv", O("VSCode: Copy selection up"))

-- Move line down/up: Alt+Down/Up
map({ "n", "i" }, "<A-Down>", move_line_down, O("VSCode: Move line down"))
map({ "n", "i" }, "<A-Up>", move_line_up, O("VSCode: Move line up"))
map("v", "<A-Down>", ":m '>+1<CR>gv=gv", O("VSCode: Move selection down"))
map("v", "<A-Up>", ":m '<-2<CR>gv=gv", O("VSCode: Move selection up"))

-- Indent / outdent
map("v", "<Tab>", ">gv", O("VSCode: Indent"))
map("v", "<S-Tab>", "<gv", O("VSCode: Outdent"))
map({ "n", "v" }, "<C-]>", ">>", O("VSCode: Indent line"))
map({ "n", "i" }, "<M-]>", "<Cmd>normal! >><CR>", O("VSCode: Indent (Alt)"))
map({ "n", "i" }, "<M-[>", "<Cmd>normal! <<<CR>", O("VSCode: Outdent (Alt)"))
-- NOTE: no <C-[> map: terminal Esc IS <C-[>

-- Comment: Ctrl+/ (+ block comment Shift+Alt+A)
map("n", "<C-_>", "gcc", vim.tbl_extend("force", opts, { remap = true, desc = "VSCode: Toggle comment" }))
map("n", "<C-/>", "gcc", vim.tbl_extend("force", opts, { remap = true, desc = "VSCode: Toggle comment" }))
map("v", "<C-_>", "gc", vim.tbl_extend("force", opts, { remap = true, desc = "VSCode: Toggle comment" }))
map("v", "<C-/>", "gc", vim.tbl_extend("force", opts, { remap = true, desc = "VSCode: Toggle comment" }))
map("i", "<C-_>", "<C-O>gcc", vim.tbl_extend("force", opts, { remap = true, desc = "VSCode: Toggle comment" }))
map("i", "<C-/>", "<C-O>gcc", vim.tbl_extend("force", opts, { remap = true, desc = "VSCode: Toggle comment" }))
map({ "n", "v" }, "<S-A-a>", "gc", vim.tbl_extend("force", opts, { remap = true, desc = "VSCode: Block comment" }))
map("i", "<S-A-a>", "<C-O>gc", vim.tbl_extend("force", opts, { remap = true, desc = "VSCode: Block comment" }))

-- Format / Rename / Quick fix
map({ "n", "i" }, "<S-A-f>", format_buffer, O("VSCode: Format (Shift+Alt+F)"))
map({ "n", "i" }, "<M-F>", format_buffer, O("VSCode: Format (Alt)"))
map({ "n", "i" }, "<F2>", rename_symbol, O("VSCode: Rename (F2)"))
map({ "n", "i" }, "<C-.>", "<Cmd>lua pcall(vim.lsp.buf.code_action)<CR>", O("VSCode: Quick fix"))
-- Trigger suggest like VSCode Ctrl+Space (insert completion kept off Ctrl+N/P)
map("i", "<C-Space>", "<C-n>", O("VSCode: Trigger suggest"))

-- Word wrap toggle: Alt+Z
map({ "n", "i" }, "<M-z>", "<Cmd>set wrap!<CR>", O("VSCode: Toggle wrap"))

-- Word jump / word delete
map("i", "<C-Left>", "<C-O>b", opts)
map("i", "<C-Right>", "<C-O>w", opts)
map("i", "<C-BS>", "<C-W>", opts)
map("i", "<C-Del>", "<C-O>dw", opts)

-- Nano-like block jump: Ctrl+Up/Down = prev/next block (blank-line separated)
map("i", "<C-Up>", "<C-O>{", O("Nano: prev block"))
map("i", "<C-Down>", "<C-O>}", O("Nano: next block"))
map({ "n", "v" }, "<C-Up>", "{", O("Nano: prev block"))
map({ "n", "v" }, "<C-Down>", "}", O("Nano: next block"))

-- Multi-occurrence (stock approx, no multicursor plugin: highlights all matches)
-- VSCode Ctrl+D = add next occurrence, Ctrl+Shift+L = select all occurrences
map({ "n", "v" }, "<C-d>", "*", O("VSCode: Select next occurrence"))
map("i", "<C-d>", "<C-O>*", O("VSCode: Select next occurrence"))
map({ "n", "v" }, "<C-S-l>", "*", O("VSCode: Select all occurrences"))
map("i", "<C-S-l>", "<C-O>*", O("VSCode: Select all occurrences"))
map({ "n", "v", "i" }, "<M-l>", "*", O("VSCode: Select all occurrences (Alt)"))

-- Insert line below/above like VSCode Ctrl+Enter / Ctrl+Shift+Enter
-- (<C-CR> and <C-Enter> are the same key; both mapped so it works regardless
-- of which name your terminal sends. <M-CR> fallback for terminals that
-- can't send Ctrl+Enter distinctly.)
map("n", "<C-CR>", "o", O("VSCode: Insert line below"))
map("n", "<C-Enter>", "o", O("VSCode: Insert line below"))
map("v", "<C-CR>", "<Esc>o", O("VSCode: Insert line below"))
map("v", "<C-Enter>", "<Esc>o", O("VSCode: Insert line below"))
map("i", "<C-CR>", "<C-O>o", O("VSCode: Insert line below"))
map("i", "<C-Enter>", "<C-O>o", O("VSCode: Insert line below"))
map("n", "<M-CR>", "o", O("VSCode: Insert line below (Alt)"))
map("n", "<M-Enter>", "o", O("VSCode: Insert line below (Alt)"))
map("v", "<M-CR>", "<Esc>o", O("VSCode: Insert line below (Alt)"))
map("v", "<M-Enter>", "<Esc>o", O("VSCode: Insert line below (Alt)"))
map("i", "<M-CR>", "<C-O>o", O("VSCode: Insert line below (Alt)"))
map("i", "<M-Enter>", "<C-O>o", O("VSCode: Insert line below (Alt)"))
map("n", "<C-S-CR>", "O", O("VSCode: Insert line above"))
map("n", "<C-S-Enter>", "O", O("VSCode: Insert line above"))
map("v", "<C-S-CR>", "<Esc>O", O("VSCode: Insert line above"))
map("v", "<C-S-Enter>", "<Esc>O", O("VSCode: Insert line above"))
map("i", "<C-S-CR>", "<C-O>O", O("VSCode: Insert line above"))
map("i", "<C-S-Enter>", "<C-O>O", O("VSCode: Insert line above"))

-- ============ FIND / REPLACE ============
-- Find / Replace in file (no Insert <C-h>: terminal sends Backspace as <C-h>)
-- Insert Ctrl+F lands in Normal find-mode (Enter = next): <C-O>/ would return
-- to Insert, where Enter must stay newline.
map("i", "<C-f>", "<Esc>/", O("VSCode: Find"))
map({ "n", "v" }, "<C-f>", "/", O("VSCode: Find"))
map("n", "<C-h>", ":%s/", { noremap = true, silent = false, desc = "VSCode: Replace" })
-- Find in files: Ctrl+Shift+F (+ Alt+F fallback), Replace in files Alt+H
map({ "n", "v" }, "<C-S-f>", find_in_files, O("VSCode: Find in files"))
map({ "n", "v", "i" }, "<M-f>", find_in_files, O("VSCode: Find in files (Alt)"))
map("n", "<M-h>", ":cfdo %s/", { noremap = true, silent = false, desc = "VSCode: Replace in files" })
-- Next / prev match
map({ "n", "v" }, "<F3>", "nzz", O("VSCode: Next match"))
map({ "n", "v" }, "<S-F3>", "Nzz", O("VSCode: Prev match"))
map("i", "<F3>", "<C-O>n", O("VSCode: Next match"))
map("i", "<S-F3>", "<C-O>N", O("VSCode: Prev match"))

-- VSCode find-mode: after / confirms you're on a match in Normal.
-- Enter = next, Shift+Enter = prev, arrows/Esc = leave find-mode.
-- Normal Enter only hijacks when a search is actually highlighted,
-- otherwise it keeps its default behavior.
map("n", "<CR>", function()
  if vim.v.hlsearch == 1 and vim.fn.getreg("/") ~= "" and vim.bo.buftype == "" then
    return "nzz"
  end
  return vim.api.nvim_replace_termcodes("<CR>", true, false, true)
end, { noremap = true, silent = true, expr = true, desc = "VSCode: Next match (Enter)" })
map("n", "<S-CR>", "Nzz", O("VSCode: Prev match (Shift+Enter)"))
map("n", "<S-Enter>", "Nzz", O("VSCode: Prev match (Shift+Enter)"))
map("v", "<CR>", "<Esc>nzz", O("VSCode: Next match (Enter)"))
map("v", "<S-CR>", "<Esc>Nzz", O("VSCode: Prev match (Shift+Enter)"))
map("v", "<S-Enter>", "<Esc>Nzz", O("VSCode: Prev match (Shift+Enter)"))
-- Shift+Enter while still typing the / pattern: confirm then step back
map("c", "<S-CR>", function()
  local t = vim.fn.getcmdtype()
  if t == "/" or t == "?" then
    return vim.api.nvim_replace_termcodes("<CR>Nzz", true, false, true)
  end
  return vim.api.nvim_replace_termcodes("<S-CR>", true, false, true)
end, { noremap = true, expr = true, desc = "VSCode: Prev match in find" })
map("c", "<S-Enter>", function()
  local t = vim.fn.getcmdtype()
  if t == "/" or t == "?" then
    return vim.api.nvim_replace_termcodes("<CR>Nzz", true, false, true)
  end
  return vim.api.nvim_replace_termcodes("<S-Enter>", true, false, true)
end, { noremap = true, expr = true, desc = "VSCode: Prev match in find" })
-- Arrows / Home / End leave find-mode: clear highlight, back to Insert, then move
map("n", "<Up>", "<Cmd>noh<CR>i<Up>", O("Exit find, move up"))
map("n", "<Down>", "<Cmd>noh<CR>i<Down>", O("Exit find, move down"))
map("n", "<Left>", "<Cmd>noh<CR>i<Left>", O("Exit find, move left"))
map("n", "<Right>", "<Cmd>noh<CR>i<Right>", O("Exit find, move right"))
map("n", "<Home>", "<Cmd>noh<CR>i<Home>", O("Exit find, line start"))
map("n", "<End>", "<Cmd>noh<CR>i<End>", O("Exit find, line end"))

-- ============ NAV / VIEW ============
-- Command palette / command bar with prefilled `:` (no `c` map: Ctrl+U keeps
-- its native "clear line" while you're already editing a command)
map({ "n", "v" }, "<C-S-p>", ":",
  { noremap = true, silent = false, desc = "VSCode: Command palette" })
map({ "n", "v" }, "<M-p>", ":",
  { noremap = true, silent = false, desc = "VSCode: Command palette (Alt)" })
map({ "n", "v" }, "<C-u>", ":",
  { noremap = true, silent = false, desc = "VSCode: Command bar" })
map("i", "<C-u>", "<C-O>:",
  { noremap = true, silent = false, desc = "VSCode: Command bar" })
map({ "n", "v", "i" }, "<C-g>", go_to_line, O("VSCode: Go to line"))
map({ "n", "v" }, "<C-S-o>", "/\\(def \\|function \\|class \\)",
  { noremap = true, silent = false, desc = "VSCode: Go to symbol" })
-- Definition / references / back-forward
map("n", "<F12>", "gd", O("VSCode: Go to definition"))
map("i", "<F12>", "<C-O>gd", O("VSCode: Go to definition"))
map("n", "<S-F12>", "*", O("VSCode: References"))
map("n", "<A-Left>", "<C-O>", O("VSCode: Back"))
map("n", "<A-Right>", "<C-I>", O("VSCode: Forward"))
-- Sidebar / terminal / splits / groups / buffers
map({ "n", "v", "i" }, "<C-b>", toggle_explorer, O("VSCode: Toggle sidebar"))
map({ "n", "v", "i" }, "<C-`>", toggle_terminal, O("VSCode: Toggle terminal"))
map({ "n", "v", "i" }, "<M-`>", toggle_terminal, O("VSCode: Toggle terminal (Alt)"))
map("t", "<C-`>", function()
  vim.cmd("stopinsert")
  toggle_terminal()
end, O("VSCode: Toggle terminal"))
map("t", "<Esc>", "<C-\\><C-n>", O("Exit terminal mode"))
map({ "n", "v" }, "<C-\\>", "<Cmd>vsplit<CR>", O("VSCode: Split right"))
map({ "n", "v" }, "<M-\\>", "<Cmd>split<CR>", O("VSCode: Split down"))
map({ "n", "v", "i" }, "<C-1>", "<Esc>1<C-w>w", O("VSCode: Focus group 1"))
map({ "n", "v", "i" }, "<C-2>", "<Esc>2<C-w>w", O("VSCode: Focus group 2"))
map({ "n", "v", "i" }, "<C-3>", "<Esc>3<C-w>w", O("VSCode: Focus group 3"))
map({ "n", "v" }, "<C-Tab>", "<Cmd>bnext<CR>", O("VSCode: Next editor"))
map({ "n", "v" }, "<C-S-Tab>", "<Cmd>bprev<CR>", O("VSCode: Prev editor"))

-- Esc: clear search highlight + back to Insert so you never get stuck in Vim mode
map("n", "<Esc>", "<Cmd>noh<CR>i", O("Back to insert, clear highlight"))

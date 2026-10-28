-- Editor options.  The defaults mirror the important Zed settings:
-- no relative numbers, no tab bar, no minimap, 2-space indent, soft wrap,
-- system clipboard, autosave, format on save, and a quiet UI.
local opt = vim.opt
local g = vim.g

g.mapleader = " "
g.maplocalleader = " "

opt.termguicolors = true
opt.mouse = "a"
opt.clipboard = "unnamedplus"

-- Remote sessions: use OSC52 so yanks go to the local terminal clipboard.
-- Neovim 0.10+ implements this natively.
if vim.env.SSH_TTY or vim.env.SSH_CONNECTION or vim.g.remote_neovim_host then
  vim.g.clipboard = "osc52"
end

-- Gutter / numbers -----------------------------------------------------------
opt.number = true
opt.relativenumber = false
opt.signcolumn = "yes"
opt.foldcolumn = "0"
opt.cursorline = true
opt.cursorcolumn = false
-- A `>` marks the active line instead of a background wash.
opt.statuscolumn = "%s%#CursorLineNr#%{(v:virtnum == 0 && v:relnum == 0) ? '> ' : '  '}%*%=%l "
opt.fillchars = { eob = " ", fold = " ", diff = "╱" }
opt.wrap = true
opt.linebreak = true
opt.breakindent = true
opt.scrolloff = 6
opt.sidescrolloff = 8

-- Indentation ----------------------------------------------------------------
opt.expandtab = true
opt.shiftwidth = 2
opt.tabstop = 2
opt.softtabstop = 2
opt.smartindent = true
opt.autoindent = true
opt.copyindent = true
opt.shiftround = true

-- Search ---------------------------------------------------------------------
opt.ignorecase = true
opt.smartcase = true
opt.hlsearch = true
opt.incsearch = true
opt.inccommand = "split"

-- Files / editing ------------------------------------------------------------
opt.undofile = true
opt.swapfile = false
opt.backup = false
opt.writebackup = false
opt.hidden = true
opt.autoread = true
opt.updatetime = 250
opt.timeoutlen = 400
opt.ttimeoutlen = 20
opt.confirm = true
opt.wildmenu = true
opt.wildmode = "longest:full,full"
opt.path:append("**")
opt.wildignore:append({ "*/node_modules/*", "*/.git/*", "*/dist/*", "*/build/*", "*/.next/*" })
opt.completeopt = "menuone,noinsert,noselect"
opt.pumheight = 12
opt.showmode = false
opt.shortmess:append("cCIS")
opt.report = 0
opt.more = false
opt.title = true
opt.splitbelow = true
opt.splitright = true
opt.equalalways = false

-- Diff: unified-ish, histogram, and inline filler ----------------------------
opt.diffopt:append({
  "internal",
  "filler",
  "closeoff",
  "algorithm:histogram",
  "linematch:60",
  "vertical",
})

-- Status line: one global bar at the bottom, like Zed.
opt.laststatus = 3
opt.showtabline = 0
opt.cmdheight = 1

-- Selection behaves like a normal editor with the mouse / Shift+Arrows.
opt.keymodel = "startsel,stopsel"
opt.selection = "inclusive"
opt.selectmode = "mouse,key"
opt.mousemodel = "extend"

-- Folds are available but not enabled by default (Zed setting: folds off).
opt.foldenable = false
opt.foldlevel = 99
opt.foldlevelstart = 99

-- Diagnostics are configured in autocmds.lua so they can react to colorschemes.

-- Spelling is opt-in.
opt.spell = false

-- Keep a little history and a persistent jumplist.
opt.history = 2000
opt.viminfo = "'100,<50,s10,h"

-- Use rg for :grep.
if vim.fn.executable("rg") == 1 then
  opt.grepprg = "rg --vimgrep --smart-case --hidden --glob !.git"
  opt.grepformat = "%f:%l:%c:%m"
end

-- No Nerd Font is assumed.  Plugins read this flag.
if g.have_nerd_font == nil then
  g.have_nerd_font = false
end

-- Remote-nvim sets this on the remote server.
g.remote_neovim_host = g.remote_neovim_host or false

-- Make sure parent directories exist for `:write` (Zed does this).
vim.api.nvim_create_autocmd("BufWritePre", {
  callback = function(args)
    local file = vim.api.nvim_buf_get_name(args.buf)
    if file ~= "" and vim.bo[args.buf].buftype == "" then
      local dir = vim.fs.dirname(file)
      if dir and vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
      end
    end
  end,
  desc = "Create missing parent directories on write",
})

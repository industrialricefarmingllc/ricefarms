-- Core UI: finders, project panel, completion, terminals, statusline.
return {
  -- Fuzzy finder (Zed: Ctrl+P / Ctrl+Shift+F / Ctrl+U).
  {
    "nvim-telescope/telescope.nvim",
    lazy = false,
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      local telescope = require("telescope")
      telescope.setup({
        defaults = {
          file_ignore_patterns = {
            "node_modules/", "%.git/", "dist/", "build/", "%.next/", "target/", "vendor/",
          },
          file_icons = false,
          color_devicons = false,
          path_display = { "truncate" },
          layout_strategy = "horizontal",
          layout_config = {
            prompt_position = "top",
            width = 0.9,
            height = 0.82,
          },
          sorting_strategy = "ascending",
          prompt_prefix = "  ",
          selection_caret = "> ",
          mappings = {
            i = {
              ["<C-j>"] = "move_selection_next",
              ["<C-k>"] = "move_selection_previous",
              ["<C-q>"] = "close",
              ["<Esc>"] = "close",
            },
            n = {
              ["<C-j>"] = "move_selection_next",
              ["<C-k>"] = "move_selection_previous",
              ["<C-q>"] = "close",
              ["<Esc>"] = "close",
            },
          },
        },
        pickers = {
          buffers = {
            sort_lastused = true,
            ignore_current_buffer = false,
            mappings = {
              i = { ["<C-d>"] = require("telescope.actions").delete_buffer },
              n = { ["<C-d>"] = require("telescope.actions").delete_buffer },
            },
          },
          live_grep = {
            additional_args = function()
              return { "--hidden", "--glob", "!.git", "--glob", "!node_modules" }
            end,
          },
        },
        extensions = {
          ["ui-select"] = {
            require("telescope.themes").get_dropdown({}),
          },
        },
      })
      pcall(telescope.load_extension, "ui-select")
    end,
  },
  {
    "nvim-telescope/telescope-ui-select.nvim",
    lazy = false,
    dependencies = { "nvim-telescope/telescope.nvim" },
  },

  -- Project panel / outline (Zed: Ctrl+Shift+E, Ctrl+Shift+B, Ctrl+P).
  {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    lazy = false,
    dependencies = {
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
    },
    config = function()
      require("neo-tree").setup({
        close_if_last_window = true,
        popup_border_style = "rounded",
        enable_git_status = true,
        enable_diagnostics = true,
        open_files_do_not_replace_types = { "terminal", "Trouble", "trouble", "qf" },
        sort_case_insensitive = true,
        default_component_configs = {
          container = { enable_character_fade = false },
          indent = {
            indent_size = 2,
            padding = 1,
            with_markers = true,
            indent_marker = "│",
            last_indent_marker = "└",
            with_expanders = true,
            expander_collapsed = "▸",
            expander_expanded = "▾",
          },
          icon = { enabled = false },
          modified = { symbol = "●" },
          name = { use_git_status_colors = true, trailing_slash = false },
          git_status = {
            symbols = {
              added = "A",
              modified = "M",
              deleted = "D",
              renamed = "R",
              untracked = "U",
              ignored = "I",
              unstaged = "U",
              staged = "S",
              conflict = "!",
            },
          },
          file_size = { enabled = false },
          type = { enabled = false },
          last_modified = { enabled = false },
          created = { enabled = false },
          symlink_target = { enabled = false },
        },
        commands = {
          copy_relative_path = function(state)
            local node = state.tree:get_node()
            if not node then
              return
            end
            local path = node.path
            if not path then
              return
            end
            local rel = vim.fs.relpath(vim.fn.getcwd(), path) or path
            vim.fn.setreg("+", rel)
            vim.notify("Copied: " .. rel)
          end,
        },
        window = {
          position = "left",
          width = 34,
          mapping_options = { noremap = true, nowait = true },
          mappings = {
            ["<CR>"] = "open",
            ["<Space>"] = "open",
            ["<C-n>"] = "add",
            ["<C-S-n>"] = "add_directory",
            ["<F2>"] = "rename",
            ["<Delete>"] = "delete",
            ["<C-Delete>"] = "delete",
            ["<C-c>"] = "copy_to_clipboard",
            ["<C-x>"] = "cut_to_clipboard",
            ["<C-v>"] = "paste_from_clipboard",
            ["<C-S-c>"] = "copy_relative_path",
            ["<C-left>"] = "close_all_nodes",
            ["<C-right>"] = "expand_all_nodes",
            ["<Left>"] = "close_node",
            ["<Right>"] = "open",
            ["q"] = "close_window",
            ["?"] = "show_help",
            ["R"] = "refresh",
            ["H"] = "toggle_hidden",
          },
        },
        filesystem = {
          filtered_items = {
            visible = false,
            hide_dotfiles = false,
            hide_gitignored = true,
            hide_by_pattern = { "node_modules", ".git", "dist", "build", ".next" },
          },
          follow_current_file = { enabled = true },
          group_empty_dirs = true,
          hijack_netrw_behavior = "open_default",
          use_libuv_file_watcher = true,
        },
      })
    end,
  },

  -- Project-wide search/replace (Zed: Ctrl+Shift+H).
  {
    "MagicDuck/grug-far.nvim",
    lazy = false,
    config = function()
      require("grug-far").setup({})
    end,
  },

  -- Terminal panel + agent dock.
  {
    "akinsho/toggleterm.nvim",
    lazy = false,
    opts = {
      size = function(term)
        if term.direction == "horizontal" then
          return 15
        end
        return math.max(60, math.floor(vim.o.columns * 0.42))
      end,
      open_mapping = false,
      direction = "horizontal",
      shade_terminals = false,
      start_in_insert = true,
      persist_size = true,
      persist_mode = true,
      close_on_exit = true,
      insert_mappings = false,
      terminal_mappings = true,
      autochdir = true,
    },
  },

  -- Chord hints for the Alt+g git prefix and other multi-key maps.
  {
    "folke/which-key.nvim",
    lazy = false,
    config = function()
      require("which-key").setup({
        preset = "modern",
        delay = 450,
        icons = { mappings = false },
      })
    end,
  },

  -- Status bar (Zed's bottom bar).
  {
    "nvim-lualine/lualine.nvim",
    lazy = false,
    config = function()
      local function remote_component()
        if vim.g.remote_neovim_host or vim.env.SSH_CONNECTION or vim.env.SSH_TTY then
          return "remote:" .. vim.uv.os_gethostname()
        end
        return ""
      end

      require("lualine").setup({
        options = {
          theme = "auto",
          globalstatus = true,
          section_separators = "",
          component_separators = "|",
          icons_enabled = false,
          disabled_filetypes = {
            statusline = { "neo-tree", "Trouble", "telescope", "lazy", "mason", "grug-far" },
          },
        },
        sections = {
          lualine_a = {},
          lualine_b = {
            { "branch", icon = "" },
            { "diff", symbols = { added = "+", modified = "~", removed = "-" } },
            {
              "diagnostics",
              symbols = { error = "E", warn = "W", info = "I", hint = "H" },
            },
          },
          lualine_c = {
            { "filename", path = 1, symbols = { modified = "●", readonly = "", unnamed = "[No Name]" } },
          },
          lualine_x = {
            remote_component,
            "filetype",
          },
          lualine_y = { "progress" },
          lualine_z = { "location" },
        },
      })
    end,
  },

  -- Diagnostics / references / symbols panel.
  {
    "folke/trouble.nvim",
    lazy = false,
    config = function()
      require("trouble").setup({
        modes = {
          diagnostics = { focus = true, auto_close = true },
          symbols = { focus = true, auto_close = true },
        },
        icons = {
          indent = {
            top = "  ",
            middle = "  ",
            last = "  ",
            fold_open = "v ",
            fold_closed = "> ",
            ws = "  ",
          },
          folder_closed = "",
          folder_open = "",
          kinds = {
            Array = "", Boolean = "", Class = "", Constant = "", Constructor = "",
            Enum = "", EnumMember = "", Event = "", Field = "", File = "",
            Function = "", Interface = "", Key = "", Method = "", Module = "",
            Namespace = "", Null = "", Number = "", Object = "", Operator = "",
            Package = "", Property = "", Reference = "", Snippet = "", String = "",
            Struct = "", Text = "", TypeParameter = "", Unit = "", Value = "", Variable = "",
          },
        },
      })
    end,
  },

  -- Line/block comments.  Built-in `gc` handles line comments; Comment.nvim
  -- provides blockwise toggling for Ctrl+Shift+A.
  {
    "numToStr/Comment.nvim",
    lazy = false,
    opts = {
      mappings = { basic = false, extra = false },
    },
  },

  -- Auto-close brackets like Zed.
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    config = function()
      require("nvim-autopairs").setup({
        check_ts = true,
        enable_check_bracket_line = false,
      })
    end,
  },

  -- Multi-cursor (Zed: Ctrl+D, Ctrl+Shift+L / Ctrl+F2, Shift+Alt+Up/Down).
  {
    "jake-stewart/multicursor.nvim",
    branch = "1.0",
    lazy = false,
    config = function()
      local mc = require("multicursor-nvim")
      mc.setup()

      local hl = vim.api.nvim_set_hl
      hl(0, "MultiCursorCursor", { reverse = true })
      hl(0, "MultiCursorVisual", { link = "Visual" })
      hl(0, "MultiCursorSign", { link = "SignColumn" })
      hl(0, "MultiCursorMatchPreview", { link = "Search" })
      hl(0, "MultiCursorDisabledCursor", { reverse = true })
      hl(0, "MultiCursorDisabledVisual", { link = "Visual" })
      hl(0, "MultiCursorDisabledSign", { link = "SignColumn" })

      mc.addKeymapLayer(function(layerSet)
        layerSet({ "n", "x" }, "<left>", mc.prevCursor)
        layerSet({ "n", "x" }, "<right>", mc.nextCursor)
        layerSet({ "n", "x" }, "<leader>x", mc.deleteCursor)
        layerSet("n", "<esc>", function()
          if not mc.cursorsEnabled() then
            mc.enableCursors()
          else
            mc.clearCursors()
          end
        end)
      end)
    end,
  },

  -- Completion.
  {
    "saghen/blink.cmp",
    branch = "main",
    commit = "4b18c32adef2898f95cdef6192cbd5796c1a332d",
    lazy = false,
    dependencies = {
      "L3MON4D3/LuaSnip",
      "rafamadriz/friendly-snippets",
    },
    config = function()
      require("luasnip.loaders.from_vscode").lazy_load()
      require("blink.cmp").setup({
        keymap = {
          preset = "none",
          ["<C-Space>"] = { "show", "show_documentation", "hide_documentation" },
          ["<C-y>"] = { "select_and_accept" },
          ["<CR>"] = { "accept", "fallback" },
          ["<Tab>"] = { "select_next", "snippet_forward", "fallback" },
          ["<S-Tab>"] = { "select_prev", "snippet_backward", "fallback" },
          ["<Down>"] = { "select_next", "fallback" },
          ["<Up>"] = { "select_prev", "fallback" },
        },
        appearance = {
          nerd_font_variant = "none",
        },
        completion = {
          documentation = { auto_show = true, auto_show_delay_ms = 300 },
          ghost_text = { enabled = false },
        },
        signature = { enabled = false },
        sources = {
          default = { "lsp", "path", "snippets", "buffer" },
        },
        snippets = { preset = "luasnip" },
        fuzzy = { implementation = "lua" },
      })
    end,
  },
}

-- Language servers, diagnostics, formatting.
local servers = {
  "lua_ls",
  "ts_ls",
  "svelte",
  "jsonls",
  "yamlls",
  "html",
  "cssls",
  "tailwindcss",
  "bashls",
  "pyright",
  "gopls",
  "rust_analyzer",
  "clangd",
  "marksman",
  "emmet_ls",
}

local auto_install = vim.env.NVIM_NO_MASON ~= "1"

return {
  {
    "mason-org/mason.nvim",
    lazy = false,
    build = ":MasonUpdate",
    opts = {
      ui = { border = "rounded" },
    },
  },
  {
    "neovim/nvim-lspconfig",
    lazy = false,
  },
  {
    "mason-org/mason-lspconfig.nvim",
    lazy = false,
    dependencies = {
      "mason-org/mason.nvim",
      "neovim/nvim-lspconfig",
    },
    opts = {
      ensure_installed = auto_install and servers or {},
      automatic_enable = true,
    },
    config = function(_, opts)
      local capabilities
      local ok, blink = pcall(require, "blink.cmp")
      if ok and type(blink.get_lsp_capabilities) == "function" then
        capabilities = blink.get_lsp_capabilities()
      else
        capabilities = vim.lsp.protocol.make_client_capabilities()
      end

      vim.lsp.config("*", {
        capabilities = capabilities,
        flags = { debounce_text_changes = 150 },
      })

      vim.lsp.config("lua_ls", {
        settings = {
          Lua = {
            runtime = { version = "LuaJIT" },
            workspace = {
              checkThirdParty = false,
              library = vim.api.nvim_get_runtime_file("", true),
            },
            telemetry = { enable = false },
            diagnostics = { globals = { "vim" } },
          },
        },
      })

      vim.lsp.config("ts_ls", {
        single_file_support = true,
        init_options = { hostInfo = "neovim" },
      })

      vim.lsp.config("pyright", {
        settings = {
          python = {
            analysis = {
              typeCheckingMode = "basic",
              autoSearchPaths = true,
              useLibraryCodeForTypes = true,
              diagnosticMode = "openFilesOnly",
            },
          },
        },
      })

      vim.lsp.config("rust_analyzer", {
        settings = {
          ["rust-analyzer"] = {
            check = { command = "clippy" },
            cargo = { allFeatures = true },
            procMacro = { enable = true },
            inlayHints = { bindingModeHints = { enable = false } },
          },
        },
      })

      vim.lsp.config("tailwindcss", {
        settings = {
          tailwindCSS = {
            includeLanguages = {
              svelte = "html",
              typescript = "javascript",
              typescriptreact = "javascript",
            },
          },
        },
      })

      vim.lsp.config("yamlls", {
        settings = {
          yaml = {
            schemaStore = { enable = true },
            validate = true,
          },
        },
      })

      require("mason-lspconfig").setup(opts)

      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          local client = vim.lsp.get_client_by_id(args.data.client_id)
          if not client then
            return
          end
          vim.bo[args.buf].omnifunc = "v:lua.vim.lsp.omnifunc"
          if client.server_capabilities.documentFormattingProvider then
            vim.bo[args.buf].formatexpr = "v:lua.vim.lsp.formatexpr()"
          end
        end,
        desc = "LSP buffer defaults",
      })
    end,
  },
  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    lazy = false,
    dependencies = { "mason-org/mason.nvim" },
    opts = {
      ensure_installed = {
        "stylua",
        "prettier",
        "prettierd",
        "ruff",
        "gofumpt",
        "goimports",
        "shfmt",
        "clang-format",
      },
      auto_install = true,
      run_on_start = auto_install,
      start_delay = 1500,
    },
  },
  {
    "stevearc/conform.nvim",
    lazy = false,
    config = function()
      require("conform").setup({
        notify_on_error = false,
        default_format_opts = {
          lsp_format = "fallback",
        },
        format_on_save = function(bufnr)
          if vim.b[bufnr].disable_autoformat or vim.g.disable_autoformat then
            return nil
          end
          return { timeout_ms = 3000, lsp_format = "fallback" }
        end,
        formatters_by_ft = {
          lua = { "stylua" },
          javascript = { "prettierd", "prettier", stop_after_first = true },
          javascriptreact = { "prettierd", "prettier", stop_after_first = true },
          typescript = { "prettierd", "prettier", stop_after_first = true },
          typescriptreact = { "prettierd", "prettier", stop_after_first = true },
          svelte = { "prettierd", "prettier", stop_after_first = true },
          json = { "prettierd", "prettier", stop_after_first = true },
          jsonc = { "prettierd", "prettier", stop_after_first = true },
          yaml = { "prettierd", "prettier", stop_after_first = true },
          markdown = { "prettierd", "prettier", stop_after_first = true },
          css = { "prettierd", "prettier", stop_after_first = true },
          scss = { "prettierd", "prettier", stop_after_first = true },
          html = { "prettierd", "prettier", stop_after_first = true },
          python = { "ruff_format" },
          go = { "gofumpt", "goimports", stop_after_first = true },
          rust = { "rustfmt" },
          sh = { "shfmt" },
          bash = { "shfmt" },
          c = { "clang-format" },
          cpp = { "clang-format" },
        },
      })

      vim.api.nvim_create_user_command("FormatDisable", function(args)
        if args.bang then
          vim.g.disable_autoformat = true
        else
          vim.b.disable_autoformat = true
        end
        vim.notify("Autoformat disabled" .. (args.bang and " globally" or " for this buffer"))
      end, { bang = true, desc = "Disable format-on-save" })

      vim.api.nvim_create_user_command("FormatEnable", function()
        vim.b.disable_autoformat = nil
        vim.g.disable_autoformat = nil
        vim.notify("Autoformat enabled")
      end, { desc = "Enable format-on-save" })

      vim.api.nvim_create_user_command("Format", function()
        require("config.keymaps").format()
      end, { desc = "Format buffer" })
    end,
  },
}

-- Remote SSH development via remote-nvim.
return {
  {
    "amitds1997/remote-nvim.nvim",
    version = "*",
    lazy = false,
    dependencies = {
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
      "nvim-telescope/telescope.nvim",
    },
    config = function()
      local function launch_client(port)
        if vim.env.NVIM_REMOTE_TEST == "1" then
          vim.fn.writefile({ tostring(port) }, "/tmp/opencode/remote-nvim-port")
          return
        end

        if vim.fn.executable("kitty") == 1 then
          vim.fn.jobstart(
            ("kitty --title 'nvim [remote]' -e nvim --server localhost:%s --remote-ui"):format(port),
            {
              detach = true,
              on_exit = function(_, exit_code)
                if exit_code ~= 0 then
                  vim.notify(
                    ("Remote client exited with code %s"):format(exit_code),
                    vim.log.levels.ERROR
                  )
                end
              end,
            }
          )
        else
          require("remote-nvim.ui").float_term(
            ("nvim --server localhost:%s --remote-ui"):format(port),
            function(exit_code)
              if exit_code ~= 0 then
                vim.notify(("Remote client exited with code %s"):format(exit_code), vim.log.levels.ERROR)
              end
            end
          )
        end
      end

      require("remote-nvim").setup({
        ssh_config = {
          ssh_binary = "ssh",
          scp_binary = "scp",
          ssh_config_file_paths = { "$HOME/.ssh/config" },
        },
        progress_view = { type = "popup" },
        remote = {
          app_name = "nvim",
          copy_dirs = {
            config = {
              base = vim.fn.stdpath("config"),
              dirs = "*",
              compression = { enabled = false },
            },
            data = {
              base = vim.fn.stdpath("data"),
              dirs = {},
              compression = { enabled = true },
            },
            cache = {
              base = vim.fn.stdpath("cache"),
              dirs = {},
              compression = { enabled = true },
            },
            state = {
              base = vim.fn.stdpath("state"),
              dirs = {},
              compression = { enabled = true },
            },
          },
        },
        client_callback = function(port, _)
          launch_client(port)
        end,
      })
    end,
  },
}

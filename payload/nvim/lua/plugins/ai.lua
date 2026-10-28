-- AI: OpenCode, matching the agent server configured in Zed.
return {
  {
    "nickjvandyke/opencode.nvim",
    lazy = false,
    config = function()
      require("config.ai").setup()
    end,
  },
}

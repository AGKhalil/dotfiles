-- Label the <leader>o prefix so which-key shows it as a group instead of "+o".
return {
  "folke/which-key.nvim",
  opts = {
    spec = {
      { "<leader>o", group = "opencode", mode = { "n", "x" } },
    },
  },
}

return {
  "iamcco/markdown-preview.nvim",
  cmd = { "MarkdownPreviewToggle", "MarkdownPreview", "MarkdownPreviewStop" },
  ft = { "markdown" },
  init = function()
    vim.g.mkdp_port = "8585"
    vim.g.mkdp_echo_preview_url = 1
  end,
  build = function()
    vim.fn["mkdp#util#install"]()
  end,
}

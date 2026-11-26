-- LazyVim ships persistence.nvim but only restores on demand (<leader>qs).
-- Restore the cwd's session automatically when nvim starts with no file args.
return {
  "folke/persistence.nvim",
  init = function()
    if vim.fn.argc(-1) > 0 then
      return
    end
    local group = vim.api.nvim_create_augroup("persistence_restore", { clear = true })
    vim.api.nvim_create_autocmd("StdinReadPre", {
      group = group,
      callback = function()
        vim.g.persistence_skip = true
      end,
    })
    vim.api.nvim_create_autocmd("VimEnter", {
      group = group,
      nested = true,
      callback = function()
        if not vim.g.persistence_skip then
          require("persistence").load()
        end
      end,
    })
  end,
}

-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Over ssh, yank to the local clipboard with OSC 52 (tmux forwards it when
-- set-clipboard is on). LazyVim leaves 'clipboard' empty on ssh, so plain y
-- would not copy; OSC 52 also avoids a `tmux load-buffer` spawn per yank.
if vim.env.SSH_TTY then
  local osc52 = require("vim.ui.clipboard.osc52")
  vim.g.clipboard = {
    name = "OSC 52",
    copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
    paste = { ["+"] = osc52.paste("+"), ["*"] = osc52.paste("*") },
  }
  vim.opt.clipboard = "unnamedplus"
end

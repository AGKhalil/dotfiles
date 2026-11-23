-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- ctrl+hjkl crosses nvim windows and tmux panes, alt+hjkl resizes both. Set
-- here, not in the plugin spec, since LazyVim's own maps load after it and
-- would shadow them.
for key, dir in pairs({ h = "left", j = "bottom", k = "top", l = "right" }) do
  vim.keymap.set("n", "<C-" .. key .. ">", function()
    require("tmux")["move_" .. dir]()
  end, { desc = "Go to window/pane " .. key })
  vim.keymap.set("n", "<M-" .. key .. ">", function()
    require("tmux")["resize_" .. dir]()
  end, { desc = "Resize window/pane " .. key })
end

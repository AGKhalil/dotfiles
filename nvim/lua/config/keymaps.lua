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

-- <leader>oy copies an opencode file reference (@path:start-end plus a trailing
-- space) for the current line or visual selection, ready to paste in a prompt.
local function yank_reference()
  local mode = vim.fn.mode()
  local first, last
  if mode == "v" or mode == "V" or mode == "\22" then
    -- Still in visual mode, so '< and '> are stale; use the live cursor ends.
    first = vim.fn.line("v")
    last = vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  else
    first = vim.fn.line(".")
    last = first
  end
  if first > last then
    first, last = last, first
  end

  local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.")
  if path == "" then
    vim.notify("Buffer has no file name", vim.log.levels.WARN)
    return
  end

  local ref = ("@%s:%d-%d "):format(path, first, last)
  vim.fn.setreg("+", ref)
  vim.fn.setreg('"', ref)
  vim.notify("Copied " .. vim.trim(ref))
end

vim.keymap.set({ "n", "x" }, "<leader>oy", yank_reference, { desc = "Yank opencode reference" })

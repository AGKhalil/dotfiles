-- =============================================================================
-- Sensible Defaults
-- =============================================================================

-- Line numbers
vim.opt.number = true
vim.opt.relativenumber = false

-- Indentation
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.expandtab = true
vim.opt.smartindent = true

-- Search
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.hlsearch = true
vim.opt.incsearch = true

-- UI
vim.opt.termguicolors = true
vim.opt.signcolumn = "yes"
vim.opt.scrolloff = 8
vim.opt.sidescrolloff = 8
vim.opt.cursorline = true
vim.opt.wrap = true

-- Clipboard: OSC 52 for copy over SSH (yank on server → local clipboard).
-- Paste: Cmd+V in insert mode uses terminal bracketed paste.
if os.getenv("SSH_TTY") then
  local osc52 = require('vim.ui.clipboard.osc52')
  vim.g.clipboard = {
    name = 'OSC 52',
    copy = {
      ['+'] = osc52.copy('+'),
      ['*'] = osc52.copy('*'),
    },
    paste = {
      ['+'] = function() return nil end,
      ['*'] = function() return nil end,
    },
  }
end
vim.opt.clipboard = "unnamedplus"

-- Fix paste over SSH through tmux: tmux re-encodes pasted newlines as CSI u
-- sequences (^[[27;5;106~) when nvim has CSI u mode enabled. Override the
-- paste handler to decode these back to newlines.
local orig_paste = vim.paste
vim.paste = function(lines, phase)
  local cleaned = {}
  for i, line in ipairs(lines) do
    -- Replace CSI u encoded Ctrl+J (newline) sequences that tmux inserts
    cleaned[i] = line:gsub('\027%[27;5;106~', '\n')
  end
  -- Re-split on the decoded newlines
  local result = {}
  for _, line in ipairs(cleaned) do
    for part in (line .. '\n'):gmatch('(.-)\n') do
      table.insert(result, part)
    end
  end
  -- Remove trailing empty string from the split
  if #result > 0 and result[#result] == '' then
    table.remove(result)
  end
  return orig_paste(result, phase)
end

-- Splits
vim.opt.splitbelow = true
vim.opt.splitright = true

-- File handling
vim.opt.autoread = true -- Required for opencode.nvim edit reloading
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.undofile = true

-- Performance
vim.opt.updatetime = 250
vim.opt.timeoutlen = 300

-- Leader key (space)
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- =============================================================================
-- Bootstrap lazy.nvim
-- =============================================================================

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- =============================================================================
-- Load plugins from lua/plugins/
-- =============================================================================

require("lazy").setup("plugins")

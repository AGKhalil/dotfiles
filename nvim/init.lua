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

-- Clipboard (use system clipboard)
vim.opt.clipboard = "unnamedplus"

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

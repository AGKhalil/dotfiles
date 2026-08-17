-- =============================================================================
-- Data directory: keep Neovim out of opencode profiles
-- =============================================================================
-- opencode profile wrappers (e.g. ~/.local/bin/opencode-work) export
-- XDG_DATA_HOME=~/.local/share/opencode-<profile> to isolate opencode's connect
-- keys/data. XDG_DATA_HOME is generic, so a nvim launched inside that env would
-- otherwise store its plugins under ~/.local/share/opencode-<profile>/nvim and
-- look like it has "no plugins installed". Neovim never needs the profile:
--   * opencode servers get their profile from the wrapper they're spawned with.
--   * opencode.nvim's snapshot lookup falls back to scanning ~/.local/share/*.
-- Clear it before lazy bootstraps so nvim always uses ~/.local/share/nvim, and
-- so child tools (tuicr, opencode) inherit the default, non-profiled data home.
vim.env.XDG_DATA_HOME = nil

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

-- Switch between splits
vim.keymap.set("n", "<leader>h", "<C-w>h", { desc = "Go to left pane / sidebar" })
vim.keymap.set("n", "<leader>j", "<C-w>j", { desc = "Go to lower pane" })
vim.keymap.set("n", "<leader>k", "<C-w>k", { desc = "Go to upper pane" })
vim.keymap.set("n", "<leader>l", "<C-w>l", { desc = "Go to right pane / main editor" })

-- Resize splits in big steps (Alt+h/j/k/l, tmux-style). Hold to keep resizing.
-- tmux leaves plain Alt+hjkl free, so these pass through to Neovim.
local width_step, height_step = 10, 5
vim.keymap.set("n", "<M-h>", function() vim.cmd("vertical resize -" .. width_step) end, { desc = "Pane narrower" })
vim.keymap.set("n", "<M-l>", function() vim.cmd("vertical resize +" .. width_step) end, { desc = "Pane wider" })
vim.keymap.set("n", "<M-k>", function() vim.cmd("resize +" .. height_step) end, { desc = "Pane taller" })
vim.keymap.set("n", "<M-j>", function() vim.cmd("resize -" .. height_step) end, { desc = "Pane shorter" })

-- Pane/window keymap cheatsheet popup (<leader>?)
local function pane_help()
  local lines = {
    "",
    "  Pane / Window Commands",
    "  ──────────────────────────────────────────────────────",
    "",
    "  Neovim panes",
    "    <leader> h j k l    move   left / down / up / right",
    "    Alt+h / Alt+l       resize narrower / wider  (10 cols)",
    "    Alt+k / Alt+j       resize taller / shorter  (5 rows)",
    "    <leader>oz          fullscreen opencode chat  (toggle)",
    "    <leader>Z           fullscreen file buffer    (toggle)",
    "",
    "  opencode messages",
    "    <leader>oT          open session timeline",
    "      <C-u>             undo to selected message (edit + resend)",
    "      <C-f>             fork from selected message",
    "",
    "  tmux panes  (press prefix = Ctrl+Space, then:)",
    "    H J K L             resize by 1  (Shift; tap to repeat)",
    "    :                   open command prompt, then run:",
    "        resize-pane -L/R/U/D N     resize by N cells",
    "    h j k l             move between panes",
    "    z                   zoom / maximize pane",
    "",
    "  q / <Esc>  close",
    "",
  }
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = width + 2
  local height = #lines
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " Keymaps ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = false
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true, silent = true })
  end
end
vim.keymap.set("n", "<leader>?", pane_help, { desc = "Pane/window keymap help" })

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

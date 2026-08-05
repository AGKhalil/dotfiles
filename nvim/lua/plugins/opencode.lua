return {
  "sudo-tee/opencode.nvim",
  config = function()
    require("opencode").setup({
      keymap = {
        editor = {
          ["<leader>od"] = false,
          ["<leader>oD"] = { "diff_open", desc = "Open diff view" },
        },
      },
    })

    local Promise = require("opencode.promise")
    local sha1 = require("opencode.sha1")
    local state = require("opencode.state")
    local config_file = require("opencode.config_file")
    local snapshot = require("opencode.snapshot")
    local git_review = require("opencode.git_review")

    local function session_dir()
      local s = state.active_session
      return (s and s.directory and s.directory ~= "") and s.directory or vim.fn.getcwd()
    end

    local function worktree()
      local ok, proj = pcall(function()
        return config_file.get_opencode_project():wait()
      end)
      if ok and proj and proj.worktree and proj.worktree ~= "" then
        return proj.worktree
      end
      local res = vim.system({ "git", "-C", session_dir(), "rev-parse", "--show-toplevel" }):wait()
      if res and res.code == 0 then
        local root = vim.trim(res.stdout)
        if root and root ~= "" then
          return root
        end
      end
      return session_dir()
    end

    local function project_id()
      local s = state.active_session
      if s and s.projectID and s.projectID ~= "" then
        return s.projectID
      end
      local ok, proj = pcall(function()
        return config_file.get_opencode_project():wait()
      end)
      return (ok and proj and proj.id) or nil
    end

    local function snapshot_dir()
      local pid = project_id()
      if not pid then
        return ""
      end
      local hash = sha1(worktree())
      if not hash then
        return ""
      end
      local base = require("opencode.config").snapshot_path
      if not base or base == "" then
        local xdg = vim.uv.os_getenv("XDG_DATA_HOME")
        base = (xdg and xdg ~= "") and vim.fs.joinpath(xdg, "opencode")
          or vim.fs.joinpath(vim.uv.os_homedir(), ".local", "share", "opencode")
      end
      local rel = vim.fs.joinpath("snapshot", pid, hash)
      local dir = vim.fs.normalize(vim.fs.joinpath(base, rel))
      if vim.fn.isdirectory(dir) == 1 then
        return dir
      end
      for entry in vim.fs.dir(vim.fs.joinpath(vim.uv.os_homedir(), ".local", "share")) do
        local candidate = vim.fs.normalize(
          vim.fs.joinpath(vim.uv.os_homedir(), ".local", "share", entry, "opencode", rel)
        )
        if vim.fn.isdirectory(candidate) == 1 then
          return candidate
        end
      end
      return dir
    end

    local function git_run(args, cwd)
      local dir = snapshot_dir()
      if dir == "" then
        vim.notify("No snapshot path for the active session.")
        return nil
      end
      local cmd = { "git", "--git-dir", dir, "--work-tree", worktree() }
      vim.list_extend(cmd, args)
      return vim.system(cmd, { cwd = cwd or worktree() }):wait()
    end

    local function rel_path(file_path)
      local abs = vim.fn.fnamemodify(file_path, ":p"):gsub("\\", "/")
      local prefix = worktree():gsub("/+$", "")
      if vim.startswith(abs, prefix .. "/") then
        return abs:sub(#prefix + 2)
      end
      return vim.fn.fnamemodify(file_path, ":."):gsub("\\", "/")
    end

    config_file.get_workspace_snapshot_path = Promise.async(function()
      return snapshot_dir()
    end)

    git_review.__is_git_project = true

    snapshot.patch = function(hash)
      local sd = session_dir()
      local add = git_run({ "add", "." }, sd)
      if add and add.code ~= 0 then
        vim.notify("Failed to add files: " .. (add.stderr or ""), vim.log.levels.WARN)
      end
      local diff = git_run({ "diff", "--cached", "--no-ext-diff", "--name-only", hash, "--", "." }, sd)
      if not diff or diff.code ~= 0 then
        vim.notify(
          "Failed to get diff: " .. ((diff and diff.stderr) or "unknown error"),
          vim.log.levels.ERROR
        )
        return nil
      end
      local files = {}
      for line in diff.stdout:gmatch("[^\r\n]+") do
        local file = vim.trim(line)
        if file ~= "" then
          table.insert(files, worktree() .. "/" .. file)
        end
      end
      return { hash = hash, files = files }
    end

    snapshot.diff_file = function(snapshot_id, file_path)
      local result = git_run({ "show", snapshot_id .. ":" .. rel_path(file_path) })
      local temp = vim.fn.tempname()
      local f = io.open(temp, "w")
      if f then
        f:write(result and result.code == 0 and result.stdout or "")
        f:close()
      end
      return { left = file_path, right = temp, file_type = vim.fn.fnamemodify(file_path, ":e") }
    end

    vim.api.nvim_create_autocmd("FileType", {
      pattern = { "opencode_output" },
      callback = function(args)
        vim.treesitter.start(args.buf, "markdown")
      end,
    })
    vim.api.nvim_set_hl(0, "@markup.strong", { fg = "#ffd700", bold = true })
  end,
  dependencies = {
    {
      "MeanderingProgrammer/render-markdown.nvim",
      opts = {
        anti_conceal = { enabled = false },
        file_types = { 'markdown', 'opencode_output' },
      },
      ft = { 'markdown', 'Avante', 'copilot-chat', 'opencode_output' },
    },
    -- Optional, for file mentions and commands completion, pick only one
    'saghen/blink.cmp',
    -- 'hrsh7th/nvim-cmp',

    -- Optional, for file mentions picker, pick only one
    'folke/snacks.nvim',
    -- 'nvim-telescope/telescope.nvim',
    -- 'ibhagwan/fzf-lua',
    -- 'nvim_mini/mini.nvim',
  },
}

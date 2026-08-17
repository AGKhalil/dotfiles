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
      ui = {
        -- <leader>oz (toggle_zoom) expands the chat pane to this fraction of
        -- the screen width. 1.0 = effectively full screen.
        zoom_width = 1.0,
        questions = {
          use_vim_ui_select = true,
        },
      },
    })

    local Promise = require("opencode.promise")
    local sha1 = require("opencode.sha1")
    local state = require("opencode.state")
    local config_file = require("opencode.config_file")
    local snapshot = require("opencode.snapshot")
    local git_review = require("opencode.git_review")
    local completion = require("opencode.ui.completion")
    local icons = require("opencode.ui.icons")
    local custom_kind = require("opencode.ui.completion.kind")

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

    local tuicr_cache = { items = nil, at = 0 }
    local TUICR_CACHE_TTL = 60

    local function tuicr_review_list()
      local root = vim.system({ "git", "-C", session_dir(), "rev-parse", "--show-toplevel" }):wait()
      if not root or root.code ~= 0 then
        return {}
      end
      local res = vim.system({
        "env",
        "-u",
        "XDG_DATA_HOME",
        "tuicr",
        "review",
        "list",
        "--repo",
        vim.trim(root.stdout),
      }, { text = true }):wait()
      if not res or res.code ~= 0 then
        return {}
      end
      local ok, sessions = pcall(vim.json.decode, res.stdout)
      if not ok or type(sessions) ~= "table" then
        return {}
      end
      return sessions
    end

    local function tuicr_session_items()
      local now = os.time()
      if tuicr_cache.items and (now - tuicr_cache.at) < TUICR_CACHE_TTL then
        return tuicr_cache.items
      end
      local items = {}
      for _, s in ipairs(tuicr_review_list()) do
        table.insert(items, {
          label = "tuicr: " .. s.anchor,
          detail = s.slug,
          documentation = string.format(
            "%d comment%s%s",
            s.comment_count,
            s.comment_count == 1 and "" or "s",
            s.active and " (active)" or ""
          ),
          kind_icon = icons.get("skill"),
          insert_text = "",
          source_name = "tuicr",
          priority = 12,
          data = { slug = s.slug },
        })
      end
      tuicr_cache = { items = items, at = now }
      return items
    end

    local tuicr_instructions = {
      "---",
      "",
      "Address the review comments above:",
      "1. Fix every [issue] comment directly.",
      "2. Implement every [suggestion] or explain why you chose not to.",
      "3. Answer every [note] without changing code.",
      "4. Acknowledge [praise] briefly.",
      "5. Only modify code inside the commented areas. If a fix requires changes elsewhere, stop and ask first.",
      "6. End with a per-comment summary of what you changed.",
    }

    local function push_wrapped(lines, text)
      for _, sub in ipairs(vim.split(text or "", "\n", { plain = true })) do
        table.insert(lines, sub)
      end
    end

    local function build_tuicr_prompt(slug, comments)
      local lines = { "# tuicr review: " .. slug, "" }
      for _, c in ipairs(comments) do
        local tag = ""
        local ct = c.comment_type
        if ct and ct ~= "" and ct ~= "none" then
          tag = "[" .. ct:upper() .. "] "
        end
        local anchor, side = "", ""
        if c.start_line ~= nil then
          anchor = ":" .. tostring(c.start_line)
          if c.end_line ~= nil and c.end_line ~= c.start_line then
            anchor = anchor .. "-" .. tostring(c.end_line)
          end
          side = " (" .. tostring(c.side) .. ")"
        end
        table.insert(lines, "### " .. tag .. (c.path or "review") .. anchor .. side)
        table.insert(lines, "")
        push_wrapped(lines, c.content or "")
        table.insert(lines, "")
      end
      vim.list_extend(lines, tuicr_instructions)
      return lines
    end

    -- Insert the selected review (comments + how-to-proceed prompt) into the
    -- current session's input buffer. Does NOT open a new session.
    local function insert_tuicr_review(slug)
      vim.system({
        "env",
        "-u",
        "XDG_DATA_HOME",
        "tuicr",
        "review",
        "comments",
        "--session",
        slug,
        "--repo",
        worktree(),
      }, { text = true }, function(res)
        vim.schedule(function()
          if not res or res.code ~= 0 then
            vim.notify("tuicr: failed to load comments for " .. slug, vim.log.levels.ERROR)
            return
          end
          local ok, comments = pcall(vim.json.decode, res.stdout)
          if not ok or type(comments) ~= "table" or #comments == 0 then
            vim.notify("tuicr: no comments in " .. slug, vim.log.levels.WARN)
            return
          end
          local input_win = require("opencode.ui.input_window")
          local lines = build_tuicr_prompt(slug, comments)
          input_win.set_content(lines)
          local win = state.windows and state.windows.input_win
          if win and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_set_current_win, win)
            pcall(vim.api.nvim_win_set_cursor, win, { #lines, #(lines[#lines] or "") })
          end
        end)
      end)
    end

    completion.register_source({
      name = "tuicr",
      priority = 12,
      is_incomplete = true,
      custom_kind = custom_kind.register("tuicr", icons.get("skill")),
      complete = Promise.async(function(context)
        if context.trigger_char ~= "@" then
          return {}
        end
        local word = (context.input or ""):lower()
        if word ~= "" and not vim.startswith(word, "t") then
          return {}
        end
        return tuicr_session_items()
      end),
      on_complete = function(item)
        if item and item.data and item.data.slug then
          insert_tuicr_review(item.data.slug)
        end
      end,
      get_trigger_character = function()
        return "@"
      end,
    })
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

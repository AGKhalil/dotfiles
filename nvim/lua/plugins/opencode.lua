return {
  "nickjvandyke/opencode.nvim",
  version = "*", -- Latest stable release
  dependencies = {
    {
      ---@module "snacks"
      "folke/snacks.nvim",
      optional = true,
      opts = {
        input = {},
        picker = {
          actions = {
            opencode_send = function(...)
              return require("opencode").snacks_picker_send(...)
            end,
          },
          win = {
            input = {
              keys = {
                ["<a-a>"] = { "opencode_send", mode = { "n", "i" } },
              },
            },
          },
        },
      },
    },
  },
  config = function()
    ---@type opencode.Opts
    vim.g.opencode_opts = {
      -- Plugin will auto-discover opencode running with --port
    }

    -- Keymaps

    -- Ask opencode about selection/cursor context
    vim.keymap.set({ "n", "x" }, "<C-a>", function()
      require("opencode").ask("@this: ", { submit = true })
    end, { desc = "Ask opencode..." })

    -- Select from prompts, commands, server controls
    vim.keymap.set({ "n", "x" }, "<C-x>", function()
      require("opencode").select()
    end, { desc = "Execute opencode action..." })

    -- Toggle opencode terminal (if using embedded mode)
    vim.keymap.set({ "n", "t" }, "<C-.>", function()
      require("opencode").toggle()
    end, { desc = "Toggle opencode" })

    -- Operator mode: go{motion} to send range to opencode
    vim.keymap.set({ "n", "x" }, "go", function()
      return require("opencode").operator("@this ")
    end, { desc = "Add range to opencode", expr = true })

    vim.keymap.set("n", "goo", function()
      return require("opencode").operator("@this ") .. "_"
    end, { desc = "Add line to opencode", expr = true })

    -- Scroll opencode messages
    vim.keymap.set("n", "<S-C-u>", function()
      require("opencode").command("session.half.page.up")
    end, { desc = "Scroll opencode up" })

    vim.keymap.set("n", "<S-C-d>", function()
      require("opencode").command("session.half.page.down")
    end, { desc = "Scroll opencode down" })

    -- Remap increment/decrement since <C-a> and <C-x> are taken
    vim.keymap.set("n", "+", "<C-a>", { desc = "Increment under cursor", noremap = true })
    vim.keymap.set("n", "-", "<C-x>", { desc = "Decrement under cursor", noremap = true })
  end,
}

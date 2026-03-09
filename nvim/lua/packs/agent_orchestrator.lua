vim.pack.add({ "https://github.com/sudo-tee/opencode.nvim" })

local agent_orchestrator = require("opencode")

agent_orchestrator.setup({
	preferred_picker = "fzf",
	preferred_completion = "blink",
	keymap_prefix = "<leader>a",
})

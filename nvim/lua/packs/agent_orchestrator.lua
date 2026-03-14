vim.pack.add({ "https://github.com/carlos-algms/agentic.nvim" })

local agent_orchestrator = require("agentic")
agent_orchestrator.setup({
	provider = "gemini-acp",
	headers = {
		chat = {
			title = "Agent Orchestrator",
			suffix = "<S-Tab>: change mode",
		},
	},
	keymaps = {
		widget = {
			close = "q", -- String for a single keybinding
			switch_provider = "<leader>ap", -- Switch ACP provider
			switch_model = "<leader>am", -- Switch model
		},
	},
})

vim.keymap.set("n", "<leader>at", agent_orchestrator.toggle, { desc = "toggle agent orchestrator" })
vim.keymap.set("v", "<leader>as", agent_orchestrator.add_selection, { desc = "add current selection to context" })
vim.keymap.set("n", "<leader>ac", agent_orchestrator.stop_generation, { desc = "cancel agent request" })

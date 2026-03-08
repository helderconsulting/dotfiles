vim.pack.add({ "https://github.com/ThePrimeagen/99" })

local agent_orchestrator = require("99")
local picker = require("99.extensions.fzf_lua")

agent_orchestrator.setup({
	provider = agent_orchestrator.Providers.GeminiCLIProvider,
	auto_add_skills = true,
})

vim.keymap.set("v", "<leader>a", function()
	agent_orchestrator.visual()
end, { desc = "agentic visual selection" })

vim.keymap.set("n", "<leader>aw", function()
	agent_orchestrator.Extensions.Worker.set_work()
end, { desc = "set work for the project" })

vim.keymap.set("n", "<leader>as", function()
	agent_orchestrator.stop_all_requests()
end, { desc = "stop all requests" })

vim.keymap.set("n", "<leader>af", function()
	agent_orchestrator.search()
end, { desc = "search the codebase with a prompt" })

vim.keymap.set("n", "<leader>am", function()
	picker.select_model()
end, { desc = "select a different model" })

vim.keymap.set("n", "<leader>ap", function()
	picker.select_provider()
end, { desc = "select another provider" })

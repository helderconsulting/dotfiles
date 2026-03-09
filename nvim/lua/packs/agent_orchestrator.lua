vim.pack.add({ "https://github.com/sudo-tee/opencode.nvim" })

local agent_orchestrator = require("opencode")

agent_orchestrator.setup({
	preferred_picker = "fzf",
	preferred_completion = "blink",
	keymap = {
		editor = {
			["<leader>aa"] = { "add_visual_selection", mode = { "v" }, desc = "Agentic Add visual selection" },

			["<leader>as"] = { "select_session", desc = "Agentic Session select" },
			["<leader>an"] = { "open_input_new_session", desc = "Agentic New session" },
			["<leader>ar"] = { "rename_session", desc = "Agentic Rename session" },
			["<leader>ah"] = { "share", desc = "Agentic Share session" },

			["<leader>ac"] = { "cancel", desc = "Agentic Cancel requests" },
			["<leader>ao"] = { "toggle", desc = "Agentic Open/Toggle" },
			["<leader>at"] = { "timeline", desc = "Agentic Timeline" },
			["<leader>ai"] = { "initialize", desc = "Agentic Initialize" },
			["<leader>af"] = { "search", desc = "Agentic Find/Search" },
			["<leader>aq"] = { "quick_chat", desc = "Agentic Quick chat" },
			["<leader>ad"] = { "diff_open", desc = "Agentic Diff open" },

			["<leader>am"] = { "configure_variant", desc = "Agentic Model/Variant" },
			["<leader>ap"] = { "configure_provider", desc = "Agentic Provider" },

			["<leader>aw"] = {
				function()
					agent_orchestrator.Extensions.Worker.set_work()
				end,
				desc = "Agentic Work set",
			},
		},
	},
})

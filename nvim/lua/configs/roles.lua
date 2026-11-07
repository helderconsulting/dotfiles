local role = require("workspace.workbench.presentation.nvim.app").role

local roles = {
	editor = {
		modules = { "workspace.workflow.presentation.nvim.review_marks" },
		packs = { "packs.fzf", "packs.oil", "packs.whichkey", "packs.paste" },
		later = { "packs.git", "packs.dap", "packs.rustacean", "packs.neotest" },
		mason = true,
	},
	sidebar = {
		modules = { "workspace.workbench.presentation.nvim.lifeline" },
		packs = { "packs.whichkey" },
		start = "workspace.workbench.presentation.nvim.sidebar",
	},
	conversation = {
		modules = { "workspace.workflow.presentation.nvim.review_marks", "workspace.workbench.presentation.nvim.lifeline" },
		packs = { "packs.whichkey" },
		start = "workspace.conversations.presentation.nvim.conversation_pane",
	},
	docker = {
		modules = { "workspace.workbench.presentation.nvim.lifeline" },
		packs = { "packs.whichkey" },
		later = { "packs.git" },
		start = "workspace.infra.presentation.nvim.infra_panel",
	},
}

return roles[role] or roles.editor

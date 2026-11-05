local role = require("configs.app").role

local roles = {
	editor = {
		modules = { "configs.review" },
		packs = { "packs.fzf", "packs.oil", "packs.whichkey", "packs.paste" },
		later = { "packs.git", "packs.dap", "packs.rustacean", "packs.neotest" },
		mason = true,
	},
	sidebar = {
		modules = { "configs.lifeline" },
		packs = { "packs.whichkey" },
		start = "configs.sidebar",
	},
	conversation = {
		modules = { "configs.review", "configs.lifeline" },
		packs = { "packs.whichkey" },
		start = "configs.conversation",
	},
	docker = {
		modules = { "configs.lifeline" },
		packs = { "packs.whichkey" },
		later = { "packs.git" },
		start = "configs.docker",
	},
}

return roles[role] or roles.editor

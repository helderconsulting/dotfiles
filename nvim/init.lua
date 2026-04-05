vim.loader.enable()
vim.g.projects_dir = vim.env.HOME .. "/Code"
require("vim._core.ui2").enable({
	enable = true,
	msg = {
		targets = "msg",
		msg = {
			height = 0.5,
			timeout = 4000,
		},
		dialog = {
			height = 0.5,
		},
		pager = {
			height = 0.5,
		},
	},
})
vim.o.confirm = true
require("configs")
require("packs")

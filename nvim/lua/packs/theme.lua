vim.pack.add({
	"https://github.com/metalelf0/black-metal-theme-neovim",
})

local theme = require("black-metal")
theme.setup({
	theme = "burzum",
	variant = "dark",
	colors = {
		string = "#77DD77",
	},
})

theme.load()

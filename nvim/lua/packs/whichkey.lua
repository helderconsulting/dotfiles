vim.pack.add({
	"https://github.com/folke/which-key.nvim",
})

require("which-key").setup({
	icons = {
		mappings = false,
	},
	opts = {
		triggers = {
			{ "<leader>", mode = { "n", "v", "d" } },
			{ "<C-space>", mode = { "n" } },
		},
	},
})

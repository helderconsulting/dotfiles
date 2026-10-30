vim.pack.add({
	"https://github.com/folke/which-key.nvim",
})

require("which-key").setup({
	icons = {
		mappings = false,
	},
	-- In the docker view only its own actions (configs/docker.lua), not the editor's.
	filter = function(mapping)
		return not vim.b.docker_view or (mapping.buffer or 0) ~= 0
	end,
	opts = {
		triggers = {
			{ "<leader>", mode = { "n", "v", "d" } },
			{ "<C-space>", mode = { "n" } },
		},
	},
})

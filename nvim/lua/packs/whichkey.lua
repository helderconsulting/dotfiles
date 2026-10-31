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
	-- Its default triggers plus terminal mode, which only has prefixed mappings in the docker view's
	-- terminals (configs/docker.lua): without it the 50ms timeoutlen ends a leader there before the
	-- next key comes.
	triggers = {
		{ "<auto>", mode = "nxsot" },
	},
})

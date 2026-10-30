vim.pack.add({
	"https://github.com/MeanderingProgrammer/render-markdown.nvim",
	"https://github.com/3rd/diagram.nvim",
	"https://github.com/3rd/image.nvim",
})

require("render-markdown").setup({
	completions = { lsp = { enabled = true } },
	render_modes = { "n" },
})

require("diagram").setup({
	integrations = {
		require("diagram.integrations.markdown"),
	},
	events = {
		render_buffer = { "InsertLeave", "BufWinEnter", "BufEnter" },
		clear_buffer = { "InsertEnter", "BufLeave" },
	},
	renderer_options = {
		mermaid = {
			background = "transparent",
			theme = "dark",
			scale = 4,
		},
	},
})

require("image").setup({
	backend = "sixel",
	integrations = {
		markdown = {
			enabled = true,
			clear_in_insert_mode = true,
			only_render_image_at_cursor = false,
			floating_windows = false,
			filetypes = { "markdown" },
		},
	},
	max_width_window_percentage = 100,
	max_height_window_percentage = 100,
})

vim.pack.add({
	"https://github.com/nvim-lualine/lualine.nvim",
})

local ok_lualine, lualine = pcall(require, "lualine")
if ok_lualine then
	lualine.setup({
		options = {
			theme = "tokyonight",
			section_separators = "",
			component_separators = "",
		},
		sections = {
			lualine_b = { {
				"branch",
			} },
			lualine_x = {
				{
					"diagnostics",
				},
			},
		},
		tabline = {
			lualine_a = {
				{
					"buffers",
					hide_filename_extension = true,
					mode = 0,
					symbols = {
						modified = " ●",
					},
				},
			},
		},
	})
end

vim.pack.add({
	"https://github.com/nvim-lualine/lualine.nvim",
	"https://github.com/nvim-tree/nvim-web-devicons",
})

local function hl_color(group, attr)
	local color = vim.api.nvim_get_hl(0, { name = group, link = false })[attr]
	return color and string.format("#%06x", color) or nil
end

local ok_lualine, lualine = pcall(require, "lualine")
if ok_lualine then
	lualine.setup({
		options = {
			section_separators = "",
			component_separators = "",
		},
		sections = {
			lualine_b = { {
				"branch",
			} },
			lualine_x = {
				{
					function()
						return vim.lsp.status()
					end,
				},
				{
					"diagnostics",
				},
			},
		},
		tabline = {
			lualine_a = {
				{
					"buffers",
					mode = 0,
					show_filename_only = true,
					hide_filename_extension = false,
					show_modified_status = true,
					icons_enabled = false,
					max_length = vim.o.columns,
					symbols = {
						modified = " ●",
						alternate_file = "",
						directory = "",
					},
					buffers_color = {
						active = function()
							return { fg = hl_color("Normal", "fg"), bg = hl_color("Visual", "bg"), gui = "bold" }
						end,
						inactive = function()
							return { fg = hl_color("Comment", "fg"), bg = hl_color("TabLineFill", "bg") }
						end,
					},
					padding = { left = 2, right = 2 },
				},
			},
		},
	})
end

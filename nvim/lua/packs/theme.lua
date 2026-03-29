vim.pack.add({
	"https://github.com/nyoom-engineering/oxocarbon.nvim",
	"https://github.com/kungfusheep/mfd.nvim",
})

vim.opt.guicursor = {
	"n:block-CursorNormal",
	"v:block-CursorVisual",
	"i:block-CursorInsert",
	"r-cr:block-CursorReplace",
	"c:block-CursorCommand",
}

local theme = require("mfd")
theme.enable_cursor_sync()
theme.setup({
	bright_comments = true,
})

vim.cmd([[colorscheme mfd-hud]])

local function override_mfd_hud()
	vim.api.nvim_set_hl(0, "Visual", { bg = "#1A3A1A" })
	vim.api.nvim_set_hl(0, "VisualNOS", { bg = "#1A3A1A" })

	vim.api.nvim_set_hl(0, "LineNr", { fg = "#2E5C2E" })
	vim.api.nvim_set_hl(0, "CursorLineNr", { fg = "#77DD77", bold = true })
end

override_mfd_hud()

vim.api.nvim_create_autocmd("ColorScheme", {
	pattern = "mfd-hud",
	callback = override_mfd_hud,
})

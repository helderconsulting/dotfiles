vim.pack.add({
	"https://github.com/NeogitOrg/neogit",
	"https://github.com/esmuellert/codediff.nvim",
	"https://github.com/nvim-lua/plenary.nvim",
})
local ok_codediff, codediff = pcall(require, "codediff")
if ok_codediff then
	-- Explorer styled like oil: plain tree, every icon in the theme's string green.
	local formatters = require("codediff.ui.explorer.formatters")
	local function oil_icons(format)
		return function(ctx)
			ctx.icon_hl = "String"
			return format(ctx)
		end
	end

	-- Line colors come from DiffAdd/DiffDelete (packs.theme); characters get a stronger tint.
	codediff.setup({
		highlights = {
			line_insert = "DiffAdd",
			line_delete = "DiffDelete",
			char_insert = "#1F5A26",
			char_delete = "#5C3418",
		},
		explorer = {
			position = "right",
			view_mode = "tree",
			indent_markers = false,
			formatters = {
				file = oil_icons(formatters.file),
				folder = oil_icons(formatters.folder),
			},
			width = 35,
			initial_focus = "modified",
			focus_on_select = true,
		},
	})

	-- codediff only knows "left" and "bottom" panels. The split itself opens on the right fine, but
	-- layout.arrange sizes any non-left panel as a bottom one, so let it size a right panel as left.
	local layout = require("codediff.ui.layout")
	local arrange = layout.arrange
	layout.arrange = function(tabpage)
		local explorer = require("codediff.config").options.explorer
		if explorer.position ~= "right" then
			return arrange(tabpage)
		end
		explorer.position = "left"
		local ok, err = pcall(arrange, tabpage)
		explorer.position = "right"
		if not ok then
			error(err, 0)
		end
	end
end

local ok_neogit, neogit = pcall(require, "neogit")
if ok_neogit then
	neogit.setup({})
end
vim.keymap.set("n", "<leader>gp", function()
	if ok_neogit then
		neogit.open()
	else
		vim.notify("neogit not available", vim.log.levels.WARN)
	end
end, { desc = "open git panel" })
vim.keymap.set("n", "<leader>gd", ":CodeDiff<cr>", { desc = "open git diff" })
vim.keymap.set("n", "<leader>gh", ":CodeDiff history %<cr>", { desc = "file history" })
vim.keymap.set("n", "<leader>gH", ":CodeDiff history<cr>", { desc = "repo history" })

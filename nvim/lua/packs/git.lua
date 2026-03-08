vim.pack.add({
	"https://github.com/NeogitOrg/neogit",
	"https://github.com/sindrets/diffview.nvim",
	"https://github.com/nvim-lua/plenary.nvim",
})
local ok_diffview, diffview = pcall(require, "diffview")
if ok_diffview then
	diffview.setup({
		enhanced_diff_hl = true,
		use_icons = true,
		file_panel = {
			listing_style = "tree",
			win_config = { width = 35 },
		},
		default_args = {
			DiffviewOpen = { "--imply-local" },
		},
	})
end

local ok_neogit, neogit = pcall(require, "neogit")
if ok_neogit then
	neogit.setup({
		integrations = {
			diffview = ok_diffview,
		},
	})
end
vim.keymap.set("n", "<leader>gp", function()
	if ok_neogit then
		neogit.open()
	else
		vim.notify("neogit not available", vim.log.levels.WARN)
	end
end, { desc = "open git panel" })
vim.keymap.set("n", "<leader>gd", ":DiffviewOpen<cr>", { desc = "open git diff" })
vim.keymap.set("n", "<leader>gD", ":DiffviewClose<cr>", { desc = "close git diff" })
vim.keymap.set("n", "<leader>gh", ":DiffviewFileHistory %<cr>", { desc = "file history" })
vim.keymap.set("n", "<leader>gH", ":DiffviewFileHistory<cr>", { desc = "repo history" })
vim.keymap.set("n", "<leader>gF", ":DiffviewToggleFiles<cr>", { desc = "toggle diff files" })

vim.pack.add({
	"https://github.com/tpope/vim-dadbod",
	"https://github.com/kristijanhusak/vim-dadbod-ui",
	"https://github.com/kristijanhusak/vim-dadbod-completion",
})

vim.g.db_ui_save_queries_state = 1
vim.g.db_ui_use_nerd_fonts = 1
vim.g.db_ui_show_database_navigation = 1

vim.api.nvim_create_autocmd("FileType", {
	pattern = "dbout",
	callback = function()
		vim.opt_local.wrap = false
		vim.opt_local.foldmethod = "syntax"
		vim.opt_local.foldlevel = 2
	end,
})
vim.keymap.set("n", "<leader>D", ":DBUIToggle<cr>", { desc = "toggle db client" })

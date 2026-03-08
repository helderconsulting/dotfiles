vim.pack.add({
	"https://github.com/tpope/vim-dadbod",
	"https://github.com/kristijanhusak/vim-dadbod-ui",
	"https://github.com/kristijanhusak/vim-dadbod-completion",
})

vim.keymap.set("n", "<leader>D", ":DBUIToggle<cr>", { desc = "toggle db client" })

vim.pack.add({ "https://github.com/mrcjkb/rustaceanvim" })
vim.api.nvim_create_autocmd("FileType", {
	pattern = "rust",
	callback = function()
		vim.keymap.set("n", "<C-space>r", ":RustLsp run<cr>", { buffer = true, desc = "run target under cursor" })
		vim.keymap.set("n", "<C-space>R", ":RustLsp runnables<cr>", { buffer = true, desc = "select available targets" })
	end,
})

vim.pack.add({ "https://github.com/mrcjkb/rustaceanvim" })

vim.api.nvim_create_autocmd("FileType", {
	pattern = "rust",
	callback = function(args)
		vim.keymap.set("n", "<C-space>r", ":RustLsp run<cr>", { buf = args.buf, desc = "run target under cursor" })
		vim.keymap.set("n", "<C-space>R", ":RustLsp runnables<cr>", { buf = args.buf, desc = "select run targets" })
		vim.keymap.set("n", "<C-space>d", ":RustLsp debug<cr>", { buf = args.buf, desc = "debug target under cursor" })
		vim.keymap.set("n", "<C-space>D", ":RustLsp debuggables<cr>", { buf = args.buf, desc = "select debug targets" })
	end,
})

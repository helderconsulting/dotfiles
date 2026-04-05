vim.pack.add({ "https://github.com/mrcjkb/rustaceanvim" })

vim.api.nvim_create_autocmd("FileType", {
	pattern = "rust",
	callback = function(args)
		vim.keymap.set("n", "<leader>ar", ":RustLsp run<cr>", { buf = args.buf, desc = "run target under cursor" })
		vim.keymap.set("n", "<leader>aR", ":RustLsp runnables<cr>", { buf = args.buf, desc = "select run targets" })
		vim.keymap.set("n", "<leader>ad", ":RustLsp debug<cr>", { buf = args.buf, desc = "debug target under cursor" })
		vim.keymap.set("n", "<leader>aD", ":RustLsp debuggables<cr>", { buf = args.buf, desc = "select debug targets" })
	end,
})

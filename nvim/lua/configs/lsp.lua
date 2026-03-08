vim.api.nvim_create_autocmd("LspAttach", {
	group = vim.api.nvim_create_augroup("Lsp", { clear = true }),
	callback = function(args)
		local client = vim.lsp.get_client_by_id(args.data.client_id)
		if client then
			client.server_capabilities.semanticTokensProvider = nil
			if vim.g.completion_mode == "native" and client:supports_method("textDocument/completion") then
				vim.lsp.completion.enable(true, client.id, args.buf, { autotrigger = true })
			end

			if client:supports_method("textDocument/documentColor") then
				vim.lsp.document_color.enable(true, args.buf, {
					style = "background",
				})
			end
			vim.keymap.set("n", "<leader>d", vim.lsp.buf.definition, { desc = "go to definition", buffer = args.buf })
			vim.keymap.set("n", "<leader>i", vim.lsp.buf.implementation, { desc = "go to implementation", buffer = args.buf })
			vim.keymap.set("n", "<leader>r", vim.lsp.buf.references, { desc = "go to references", buffer = args.buf })
			vim.keymap.set(
				"n",
				"<leader>T",
				vim.lsp.buf.type_definition,
				{ desc = "go to type definition", buffer = args.buf }
			)
		end
	end,
})

vim.lsp.enable({
	"c_ls",
	"lua_ls",
	"rust_ls",
	"typescript_ls",
	"eslint_ls",
	"yaml_ls",
})

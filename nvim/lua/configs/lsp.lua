vim.api.nvim_create_autocmd("LspAttach", {
	group = vim.api.nvim_create_augroup("Lsp", { clear = true }),
	callback = function(args)
		local client = vim.lsp.get_client_by_id(args.data.client_id)
		if client then
			client.server_capabilities.semanticTokensProvider = nil
			if client.name == "typescript_ls" or client.name == "vtsls" then
				client.server_capabilities.documentFormattingProvider = false
				client.server_capabilities.documentRangeFormattingProvider = false
			end

			if client:supports_method("textDocument/inlayHint") then
				vim.lsp.inlay_hint.enable(false, { bufnr = args.buf })
			end

			if vim.g.completion_mode == "native" and client:supports_method("textDocument/completion") then
				vim.lsp.completion.enable(true, client.id, args.buf, { autotrigger = true })
			end

			if client:supports_method("textDocument/documentHighlight") then
				vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
					buffer = args.buf,
					callback = vim.lsp.buf.document_highlight,
				})
				vim.api.nvim_create_autocmd("CursorMoved", {
					buffer = args.buf,
					callback = vim.lsp.buf.clear_references,
				})
			end
			if client:supports_method("textDocument/documentColor") then
				vim.lsp.document_color.enable(true, {
					bufnr = args.buf,
					style = "background",
				})
			end

			vim.keymap.set("n", "<leader>d", vim.lsp.buf.definition, { desc = "go to definition", buf = args.buf })
			vim.keymap.set("n", "<leader>i", vim.lsp.buf.implementation, { desc = "go to implementation", buffer = args.buf })
			vim.keymap.set("n", "<leader>r", vim.lsp.buf.references, { desc = "go to references", buf = args.buf })
			vim.keymap.set("n", "<leader>l", vim.lsp.codelens.run, { desc = "run codelens", buf = args.buf })
			vim.keymap.set(
				"n",
				"<leader>T",
				vim.lsp.buf.type_definition,
				{ desc = "go to type definition", buffer = args.buf }
			)
		end
	end,
})

vim.api.nvim_create_autocmd("LspProgress", {
	callback = function()
		vim.cmd.redrawstatus()
	end,
})

vim.lsp.enable({
	"c_ls",
	"lua_ls",
	"typescript_ls",
	"eslint_ls",
	"yaml_ls",
})

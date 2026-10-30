vim.api.nvim_create_autocmd("LspAttach", {
	group = vim.api.nvim_create_augroup("Lsp", { clear = true }),
	callback = function(args)
		local client = vim.lsp.get_client_by_id(args.data.client_id)
		if client then
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

			if client:supports_method("textDocument/definition") then
				vim.keymap.set("n", "<leader>d", vim.lsp.buf.definition, { desc = "go to definition", buf = args.buf })
			end
			if client:supports_method("textDocument/implementation") then
				vim.keymap.set(
					"n",
					"<leader>i",
					vim.lsp.buf.implementation,
					{ desc = "go to implementation", buffer = args.buf }
				)
			end
			if client:supports_method("textDocument/references") then
				vim.keymap.set("n", "<leader>R", vim.lsp.buf.references, { desc = "go to references", buf = args.buf })
			end
			if client:supports_method("textDocument/codeLens") then
				vim.keymap.set("n", "<leader>l", vim.lsp.codelens.run, { desc = "run codelens", buf = args.buf })
			end
			if client:supports_method("textDocument/typeDefinition") then
				vim.keymap.set(
					"n",
					"<leader>T",
					vim.lsp.buf.type_definition,
					{ desc = "go to type definition", buffer = args.buf }
				)
			end
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
	"svelte_ls",
	"markdown_ls",
	"go_ls",
	"css_ls",
	"css_variables",
	"cssmodules_ls",
	"html_ls",
	"emmet_ls",
	"postgres_ls",
})

-- LSP info popups (hover, signature help, diagnostic details) styled like the review comment
-- popup: a blank border in the popup's own color for padding, tinted green instead of purple.
local open_floating_preview = vim.lsp.util.open_floating_preview
---@diagnostic disable-next-line: duplicate-set-field
vim.lsp.util.open_floating_preview = function(contents, syntax, opts)
	opts = opts or {}
	opts.border = opts.border or "solid"
	local buf, win = open_floating_preview(contents, syntax, opts)
	vim.wo[win].winhighlight = "Normal:InfoFloat,NormalFloat:InfoFloat,FloatBorder:InfoFloat,EndOfBuffer:InfoFloat"
	return buf, win
end

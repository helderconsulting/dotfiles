---@type vim.lsp.Config
return {
	cmd = { "vtsls", "--stdio" },
	filetypes = { "typescript", "typescriptreact", "javascript", "javascriptreact" },
	root_markers = { "package-lock.json", "tsconfig.json", "package.json" },
	settings = {
		complete_function_calls = true,
		vtsls = {
			enableMoveToFileCodeAction = true,
			autoUseWorkspaceTsdk = true,
			experimental = {
				completion = {
					enableServerSideFuzzyMatch = true,
				},
			},
			tsserver = {
				globalPlugins = {
					{
						name = "typescript-svelte-plugin",
						location = vim.fn.stdpath("data") .. "/mason/packages/svelte-language-server/libexec/lib/node_modules/typescript-svelte-plugin",
						enableForWorkspaceTypeScriptVersions = true,
					},
				},
			},
		},
		typescript = {
			updateImportsOnFileMove = { enabled = "always" },
			suggest = {
				completeFunctionCalls = true,
			},
			inlayHints = {
				enabled = false,
			},
		},
	},
}

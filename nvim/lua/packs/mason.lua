vim.pack.add({
	"https://github.com/mason-org/mason.nvim",
})
require("mason").setup({
	ui = {
		border = "none",
		icons = {
			package_installed = "✓",
			package_pending = "➜",
			package_uninstalled = "✗",
		},
	},
	ensure_installed = {
		"vtsls",
		"lua_ls",
		"lua-language-server",
		"yaml-language-server",
		"ember-language-server",
		"svelte-language-server",
		"rust_analyzer",
		"js-debug-adapter",
		"eslint_d",
		"selene",
		"prettier",
		"stylua",
		"postgres-language-server",
		"sql-formatter",
		"css-lsp",
		"css-variables-language-server",
		"cssmodules-language-server",
		"html-lsp",
		"emmet-language-server",
	},
})
vim.keymap.set("n", "<leader>L", function()
	require("mason.ui").open()
end, { desc = "Open language tools" })

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
		"rust_analyzer",
		"js-debug-adapter",
		"eslint_d",
		"selene",
		"prettier",
		"stylua",
	},
})
vim.keymap.set("n", "<leader>l", function()
	require("mason.ui").open()
end, { desc = "Open language tools" })

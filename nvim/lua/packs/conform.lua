vim.pack.add({
	"https://github.com/stevearc/conform.nvim",
})
require("conform").setup({
	formatters_by_ft = {
		lua = { "stylua" },
		javascript = { "prettier", stop_after_first = true },
		typescript = { "prettier", stop_after_first = true },
		json = { "prettier", stop_after_first = true },
		yaml = { "prettier", stop_after_first = true },
		handlebars = { "djlint" },
		moustache = { "djlint" },
		c = { "clang-format" },
	},
	format_on_save = {
		timeout_ms = 500,
		lsp_format = "fallback",
	},
})

vim.o.formatexpr = "v:lua.require'conform'.formatexpr()"

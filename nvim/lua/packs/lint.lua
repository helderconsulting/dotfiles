vim.pack.add({
	"https://github.com/mfussenegger/nvim-lint",
})

local lint = require("lint")

lint.linters_by_ft = {
	lua = { "selene" },
}

local lint_augroup = vim.api.nvim_create_augroup("lint", { clear = true })
vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave" }, {
	group = lint_augroup,
	callback = function()
		if vim.bo.modifiable then
			-- selene only reads selene.toml from its working directory, so run it from the nearest one.
			lint.try_lint(nil, { cwd = vim.fs.root(0, "selene.toml") })
		end
	end,
})

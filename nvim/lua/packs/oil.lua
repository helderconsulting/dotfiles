vim.pack.add({
	"https://github.com/stevearc/oil.nvim",
})
vim.api.nvim_create_autocmd("FileType", {
	pattern = "oil",
	callback = function()
		vim.opt_local.number = false -- Hide line numbers
		vim.opt_local.relativenumber = false
		vim.opt_local.signcolumn = "no" -- Hide git/error signs
		vim.opt_local.foldcolumn = "0" -- Hide fold markers
	end,
})

local oil = require("oil")
oil.setup({
	default_file_explorer = true,
	view_options = {
		show_hidden = true,
		is_hidden_file = function(name, bufnr)
			local m = name:match("^%.")
			return m ~= nil
		end,
	},
	keymaps = {
		["<CR>"] = function()
			oil.select({ preview = false, close = true })
		end,
	},
})
vim.keymap.set("n", "-", function()
	vim.cmd("vsplit")
	require("oil").open()
end, { desc = "Open parent directory" })

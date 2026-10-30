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
	columns = {
		{
			"icon",
			-- one colour for every icon: the theme's string green
			highlight = function()
				return "String"
			end,
		},
	},
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
	local buf = vim.api.nvim_get_current_buf()
	local empty = vim.api.nvim_buf_get_name(buf) == ""
		and vim.bo[buf].buftype == ""
		and not vim.bo[buf].modified
		and vim.api.nvim_buf_line_count(buf) == 1
		and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
	-- reuse an empty buffer's window instead of leaving it behind in a split
	if not empty then
		vim.cmd("vsplit")
	end
	require("oil").open()
end, { desc = "Open parent directory" })

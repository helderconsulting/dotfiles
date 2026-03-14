local result_buffer = nil
local result_window = nil
local query_window = nil
local connection = "mongodb://localhost:27017"

local open_window = function()
	query_window = vim.api.nvim_get_current_win()
	if not (result_buffer and vim.api.nvim_buf_is_valid(result_buffer)) then
		result_buffer = vim.api.nvim_create_buf(false, true)
	end

	if not (result_window and vim.api.nvim_win_is_valid(result_window)) then
		vim.cmd("botright split")
		result_window = vim.api.nvim_get_current_win()
	end

	vim.api.nvim_win_set_buf(result_window, result_buffer)

	vim.bo[result_buffer].buftype = "nofile"
	vim.bo[result_buffer].bufhidden = "wipe"
	vim.bo[result_buffer].swapfile = false
	vim.bo[result_buffer].filetype = "json"
end

local show_result = function(lines)
	local query = table.concat(lines, "\n")

	local result = vim.fn.system("mongosh --quiet '" .. connection .. "' --eval '" .. query .. "'")

	if result_buffer then
		vim.api.nvim_buf_set_lines(result_buffer, 0, -1, false, vim.split(result, "\n"))
	end
end

vim.api.nvim_create_user_command("QueryDatabase", function(opts)
	local lines = vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
	open_window()
	show_result(lines)

	if query_window then
		vim.api.nvim_set_current_win(query_window)
	end
end, { range = true })

vim.api.nvim_del_user_command("QueryCollection", function(opts) end)

vim.keymap.set("v", "<leader>qd", ":QueryDatabase<cr>", { desc = "queries the database with selection" })
vim.keymap.set("n", "<leader>ql", ":QueryCollection<cr>", { desc = "lists the data of selected collection" })

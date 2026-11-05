local M = {}

function M.wipe(buf, replacement)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		local other = replacement
		if not (other and vim.api.nvim_buf_is_valid(other)) then
			other = vim.api.nvim_create_buf(false, true)
			vim.bo[other].bufhidden = "wipe"
		end
		vim.api.nvim_win_set_buf(win, other)
	end
	pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

return M

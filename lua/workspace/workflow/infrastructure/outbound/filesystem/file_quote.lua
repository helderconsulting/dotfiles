local M = {}

function M.lines(path, line1, line2)
	if not (path and line1 and vim.fn.filereadable(path) == 1) then
		return {}
	end
	return vim.list_slice(vim.fn.readfile(path, "", line2 or line1), line1, line2 or line1)
end

return M

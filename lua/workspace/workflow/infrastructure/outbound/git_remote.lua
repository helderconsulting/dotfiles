local M = {}

function M.new()
	return setmetatable({}, { __index = M })
end

function M:url(root)
	local res = vim.system({ "git", "-C", root, "remote", "get-url", "origin" }, { text = true }):wait()
	return res.code == 0 and res.stdout or ""
end

return M

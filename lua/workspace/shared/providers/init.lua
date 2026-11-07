local M = {}

local here = package.searchpath("workspace.shared.providers", package.path):match("^(.*)/init%.lua$")
local current

local function discover()
	local names = {}
	local ls = io.popen('ls -1 "' .. here .. '"')
	for name in ls:lines() do
		if name:match("^%a+$") then
			table.insert(names, name)
		end
	end
	ls:close()
	table.sort(names)
	return names[1]
end

function M.current()
	if not current then
		current = require("workspace.shared.providers." .. discover())
	end
	return current
end

return M

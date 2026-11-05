local nvim = require("workspace.nvim")
local Agent = require("workspace.models").Agent

local M = {}

function M.run(args)
	local title = table.concat(args, " "):gsub("[\t\n]", " ")
	local session = vim.env.CLAUDE_CODE_SESSION_ID
	if title == "" or not session then
		vim.uv.fs_write(2, "usage: agent-title <title>    name this agent session in the WezTerm bar and sidebar\n")
		return 2
	end
	nvim.new_store():update(Agent, session, function(a)
		a.title = title
	end)
	return 0
end

return M

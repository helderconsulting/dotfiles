local session_files = require("workspace.shared.providers").current().session_files
local MilesSessionList = require("workspace.legio.domain.miles_session_list")

local M = {}

function M.list()
	return MilesSessionList.new(session_files.entries(), session_files.alive)
end

function M.when_gone(id, deadline_ms, done)
	session_files.when_gone(id, deadline_ms, done)
end

return M

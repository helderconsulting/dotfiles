local DiffProgress = require("workspace.workflow.domain.diff_progress")

local M = {}

function M.to_domain(record)
	return DiffProgress:new(record)
end

function M.to_record(progress)
	local record = {}
	for _, field in ipairs(DiffProgress.fields) do
		record[field] = progress[field]
	end
	return record
end

return M

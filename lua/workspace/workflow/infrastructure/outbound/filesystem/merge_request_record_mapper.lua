local MergeRequest = require("workspace.workflow.domain.merge_request")

local M = {}

function M.to_domain(record)
	return MergeRequest:new(record)
end

function M.to_record(merge_request)
	local record = {}
	for _, field in ipairs(MergeRequest.fields) do
		record[field] = merge_request[field]
	end
	return record
end

return M

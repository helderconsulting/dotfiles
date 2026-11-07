local mapper = require("workspace.workflow.infrastructure.outbound.filesystem.merge_request_record_mapper")
local MergeRequest = require("workspace.workflow.domain.merge_request")

local KIND = "merge_requests"

local Repository = {}
Repository.__index = Repository

local M = {}

function M.new(store)
	return setmetatable({ store = store }, Repository)
end

function Repository:get(root)
	local record = root and self.store:get_record(KIND, MergeRequest.key(root))
	return record and mapper.to_domain(record) or nil
end

function Repository:all()
	local list = {}
	for _, id in ipairs(self.store:record_ids(KIND)) do
		local record = self.store:get_record(KIND, id)
		if record then
			table.insert(list, mapper.to_domain(record))
		end
	end
	return list
end

function Repository:update(root, fn)
	local merge_request
	self.store:update_record(KIND, MergeRequest.key(root), function(record)
		merge_request = record and mapper.to_domain(record) or MergeRequest.for_root(root)
		if fn(merge_request) == false then
			return false, merge_request:take_transitions()
		end
		return mapper.to_record(merge_request), merge_request:take_transitions()
	end)
	return merge_request
end

function Repository:remove(root)
	self.store:update_record(KIND, MergeRequest.key(root), function()
		return "delete"
	end)
end

return M

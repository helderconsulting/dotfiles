local mapper = require("workspace.workflow.infrastructure.outbound.filesystem.diff_progress_record_mapper")
local DiffProgress = require("workspace.workflow.domain.diff_progress")

local KIND = "diff_progress"

local Repository = {}
Repository.__index = Repository

local M = {}

function M.new(store)
	return setmetatable({ store = store }, Repository)
end

function Repository:get(root)
	local record = self.store:get_record(KIND, DiffProgress.key(root))
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

function Repository:absorb(root, mine)
	local merged
	self.store:update_record(KIND, DiffProgress.key(root), function(record)
		merged = record and mapper.to_domain(record) or DiffProgress.for_root(root)
		merged:absorb(mine)
		return mapper.to_record(merged)
	end)
	return merged
end

function Repository:remove(root)
	self.store:update_record(KIND, DiffProgress.key(root), function()
		return "delete"
	end)
end

return M

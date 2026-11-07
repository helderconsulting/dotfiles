local mapper = require("workspace.workbench.infrastructure.outbound.filesystem.workspace_record_mapper")

local KIND = "workspaces"

local Repository = {}
Repository.__index = Repository

local M = {}

function M.new(store)
	return setmetatable({ store = store }, Repository)
end

function Repository:get(id)
	local record = id and self.store:get_record(KIND, tostring(id))
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

function Repository:save(workspace)
	self.store:update_record(KIND, tostring(workspace.id), function()
		return mapper.to_record(workspace)
	end)
end

function Repository:remove(id)
	self.store:update_record(KIND, tostring(id), function()
		return "delete"
	end)
end

return M

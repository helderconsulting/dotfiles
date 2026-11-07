local mapper = require("workspace.legio.infrastructure.outbound.filesystem.usage_record_mapper")
local records = require("workspace.legio.infrastructure.outbound.filesystem.stored_records")

local KIND = "usage"

local Repository = {}
Repository.__index = Repository

local M = {}

function M.new(store)
	return setmetatable({ store = store }, Repository)
end

function Repository:get(provider)
	return records.get(self.store, KIND, mapper, provider)
end

function Repository:all()
	return records.all(self.store, KIND, mapper)
end

function Repository:update(provider, fn)
	return records.update(self.store, KIND, mapper, provider, fn)
end

return M

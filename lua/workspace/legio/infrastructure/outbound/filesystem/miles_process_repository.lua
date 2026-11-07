local mapper = require("workspace.legio.infrastructure.outbound.filesystem.miles_process_record_mapper")
local records = require("workspace.legio.infrastructure.outbound.filesystem.stored_records")

local KIND = "runtimes"

local Repository = {}
Repository.__index = Repository

local M = {}

function M.new(store)
	return setmetatable({ store = store }, Repository)
end

function Repository:get(id)
	return records.get(self.store, KIND, mapper, id)
end

function Repository:all()
	return records.all(self.store, KIND, mapper)
end

function Repository:update(id, fn)
	return records.update(self.store, KIND, mapper, id, fn)
end

function Repository:remove(id)
	records.remove(self.store, KIND, id)
end

return M

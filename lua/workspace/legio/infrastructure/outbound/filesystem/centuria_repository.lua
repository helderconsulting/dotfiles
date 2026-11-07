local Centuria = require("workspace.legio.domain.centuria")
local mapper = require("workspace.legio.infrastructure.outbound.filesystem.centuria_record_mapper")
local records = require("workspace.legio.infrastructure.outbound.filesystem.stored_records")

local KIND = "centuriae"

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

function Repository:update_existing(id, fn)
	return self:update(id, function(model, created)
		if created then
			return false
		end
		return fn(model)
	end)
end

function Repository:save(model)
	return self:update(model.id, function(stored)
		for _, f in ipairs(Centuria.fields) do
			stored[f] = model[f]
		end
	end)
end

function Repository:remove(id)
	records.remove(self.store, KIND, id)
end

return M

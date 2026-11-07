local mapper = require("workspace.legio.infrastructure.outbound.filesystem.contubernium_record_mapper")
local records = require("workspace.legio.infrastructure.outbound.filesystem.stored_records")
local Contubernium = require("workspace.legio.domain.contubernium")

local KIND = "contubernia"

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

function Repository:of(miles_id)
	return Contubernium.of(self:all(), miles_id)
end

function Repository:update(id, fn)
	return records.update(self.store, KIND, mapper, id, fn)
end

function Repository:save(contubernium)
	return self:update(contubernium.id, function(t)
		for _, f in ipairs(Contubernium.fields) do
			t[f] = contubernium[f]
		end
	end)
end

function Repository:remove(id)
	records.remove(self.store, KIND, id)
end

return M

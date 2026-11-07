local mapper = require("workspace.legio.infrastructure.outbound.filesystem.agentd_status_record_mapper")
local records = require("workspace.legio.infrastructure.outbound.filesystem.stored_records")
local AgentdStatus = require("workspace.legio.domain.agentd_status")

local KIND = "daemons"

local Repository = {}
Repository.__index = Repository

local M = {}

function M.new(store)
	return setmetatable({ store = store }, Repository)
end

function Repository:get()
	return records.get(self.store, KIND, mapper, AgentdStatus.id)
end

function Repository:update(fn)
	return records.update(self.store, KIND, mapper, AgentdStatus.id, fn)
end

function Repository:remove()
	records.remove(self.store, KIND, AgentdStatus.id)
end

return M

local mapper = require("workspace.legio.infrastructure.outbound.filesystem.miles_record_mapper")
local records = require("workspace.legio.infrastructure.outbound.filesystem.stored_records")
local processes = require("workspace.legio.infrastructure.outbound.filesystem.miles_process_repository")
local usages = require("workspace.legio.infrastructure.outbound.filesystem.usage_repository")
local questions = require("workspace.conversations.infrastructure.outbound.filesystem.question_repository")
local MilesProcess = require("workspace.legio.domain.miles_process")

local KIND = "milites"

local Repository = {}
Repository.__index = Repository

local M = {}

function M.new(store)
	return setmetatable({ store = store, processes = processes.new(store), usages = usages.new(store), questions = questions.new(store) }, Repository)
end

local function index(list)
	local out = {}
	for _, item in ipairs(list) do
		out[item.id] = item
	end
	return out
end

local function hydrate(miles, runtimes, usage_of, pending)
	local runtime = runtimes[miles.id]
	local provider = runtime and runtime.provider or MilesProcess.default_provider
	return miles:hydrate({ runtime = runtime, usage = usage_of(provider), asks = pending[miles.id] })
end

function Repository:find(id)
	return records.get(self.store, KIND, mapper, id)
end

function Repository:plain_all()
	return records.all(self.store, KIND, mapper)
end

function Repository:all()
	local runtimes = index(self.processes:all())
	local usage = index(self.usages:all())
	local pending = self.questions:pending_by_session()
	local out = {}
	for _, miles in ipairs(self:plain_all()) do
		table.insert(out, hydrate(miles, runtimes, function(provider)
			return usage[provider]
		end, pending))
	end
	return out
end

function Repository:get(id)
	local miles = self:find(id)
	if not miles then
		return nil
	end
	return hydrate(miles, { [id] = self.processes:get(id) }, function(provider)
		return self.usages:get(provider)
	end, self.questions:pending_by_session())
end

function Repository:update(id, fn)
	return records.update(self.store, KIND, mapper, id, fn)
end

function Repository:update_existing(id, fn)
	return self:update(id, function(miles, created)
		if created then
			return false
		end
		return fn(miles)
	end)
end

function Repository:remove(id)
	records.remove(self.store, KIND, id)
end

return M

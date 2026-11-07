local expeditio_mapper = require("workspace.workflow.infrastructure.outbound.filesystem.expeditio_record_mapper")
local mandatum_mapper = require("workspace.workflow.infrastructure.outbound.filesystem.mandatum_record_mapper")
local Expeditio = require("workspace.workflow.domain.expeditio")
local Mandatum = require("workspace.workflow.domain.mandatum")

local EXPEDITIONES, MANDATA = "expeditiones", "mandata"

local Repository = {}
Repository.__index = Repository

local M = {}

function M.new(store, random)
	return setmetatable({ store = store, random = random or math.random }, Repository)
end

local function load(store, kind, mapper, id)
	local record = id and store:get_record(kind, id)
	return record and mapper.to_domain(record) or nil
end

local function load_all(store, kind, mapper)
	local list = {}
	for _, id in ipairs(store:record_ids(kind)) do
		local record = store:get_record(kind, id)
		if record then
			table.insert(list, mapper.to_domain(record))
		end
	end
	return list
end

function Repository:new_expeditio_id()
	local id = Expeditio.new_id(self.random)
	while self.store:get_record(EXPEDITIONES, id) do
		id = Expeditio.new_id(self.random)
	end
	return id
end

function Repository:new_mandatum_id()
	local id = Mandatum.new_id(self.random)
	while self.store:get_record(MANDATA, id) do
		id = Mandatum.new_id(self.random)
	end
	return id
end

function Repository:all_mandata()
	return load_all(self.store, MANDATA, mandatum_mapper)
end

function Repository:all()
	local mandata = self:all_mandata()
	local out = {}
	for _, e in ipairs(load_all(self.store, EXPEDITIONES, expeditio_mapper)) do
		table.insert(out, e:hydrate(mandata))
	end
	return out
end

function Repository:get(id)
	local e = load(self.store, EXPEDITIONES, expeditio_mapper, id)
	return e and e:hydrate(self:all_mandata()) or nil
end

function Repository:mandatum(id)
	return load(self.store, MANDATA, mandatum_mapper, id)
end

function Repository:of_mandatum(mandatum_id)
	local m = self:mandatum(mandatum_id)
	return m and self:get(m.expeditio) or nil
end

function Repository:find_by_title(root, title)
	local found = Expeditio.find(load_all(self.store, EXPEDITIONES, expeditio_mapper), root, title)
	return found and self:get(found.id) or nil
end

function Repository:save_expeditio(expeditio)
	self.store:update_record(EXPEDITIONES, expeditio.id, function()
		return expeditio_mapper.to_record(expeditio)
	end)
end

function Repository:rename_expeditio(id, title)
	local renamed = false
	self.store:update_record(EXPEDITIONES, id, function(record)
		if not record then
			return false
		end
		local e = expeditio_mapper.to_domain(record)
		e.title = title
		renamed = true
		return expeditio_mapper.to_record(e)
	end)
	return renamed
end

function Repository:save_mandatum(mandatum)
	self.store:update_record(MANDATA, mandatum.id, function()
		return mandatum_mapper.to_record(mandatum)
	end)
end

function Repository:delete_expeditio(id)
	self.store:update_record(EXPEDITIONES, id, function()
		return "delete"
	end)
end

function Repository:update_mandatum(mandatum_id, fn)
	local ok, why
	self.store:update_record(MANDATA, mandatum_id, function(record)
		if not record then
			why = "no mandatum " .. tostring(mandatum_id)
			return false
		end
		local m = mandatum_mapper.to_domain(record)
		local expeditio = self:get(m.expeditio) or Expeditio.make(m.expeditio, Expeditio.loose_ends, m.root, "you", m.created)
		expeditio.list = expeditio.list or {}
		local found = false
		for i, other in ipairs(expeditio.list) do
			if other.id == m.id then
				expeditio.list[i], found = m, true
			end
		end
		if not found then
			table.insert(expeditio.list, m)
		end
		ok, why = fn(expeditio)
		local transitions = m:take_transitions()
		if not ok then
			return false, transitions
		end
		return mandatum_mapper.to_record(m), transitions
	end)
	return ok, why
end

return M

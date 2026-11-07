local Miles = require("workspace.legio.domain.miles")

local MilesSessionList = {}
MilesSessionList.__index = MilesSessionList

function MilesSessionList.new(entries, alive)
	local self = setmetatable({ by_id = {}, list = {} }, MilesSessionList)
	for _, entry in ipairs(entries) do
		if entry.sessionId and not entry.parkedJobId then
			entry.alive = entry.pid ~= nil and alive(entry.pid)
			self.by_id[entry.sessionId] = entry
			table.insert(self.list, entry)
		end
	end
	return self
end

function MilesSessionList:entry(id)
	return self.by_id[id]
end

function MilesSessionList:needs_reconcile(miles)
	if miles:is_hosted() then
		return miles:renamed_by(self.by_id[miles.id])
	end
	local entry = self.by_id[miles.id]
	local alive = entry ~= nil and entry.alive
	return miles:is_running() ~= alive or not miles:in_sync(entry) or miles:renamed_by(entry)
end

function MilesSessionList:reconcile(miles, now, asking)
	local entry = self.by_id[miles.id]
	if miles:is_hosted() then
		miles.name = entry and entry.name or miles.name
		return true
	end
	return miles:reconcile(entry, entry ~= nil and entry.alive, now, asking)
end

function MilesSessionList:wait(miles, now)
	if miles:is_hosted() then
		return nil
	end
	return miles:status_wait(self.by_id[miles.id], now)
end

function MilesSessionList:untracked(known)
	local list = {}
	for _, entry in ipairs(self.list) do
		if entry.alive and not known[entry.sessionId] then
			table.insert(list, entry)
		end
	end
	return list
end

function MilesSessionList.adopt(miles, entry, now)
	local fresh = Miles.from_registry(entry)
	miles.cwd, miles.root, miles.name, miles.pid = fresh.cwd, fresh.root, fresh.name, fresh.pid
	miles:apply(entry.status == "busy" and "prompt" or "start", now)
end

function MilesSessionList:recipient(to)
	local pid = to:match("^uds:.-/(%d+)%.sock$")
	local name = to:gsub(" %[.*%]$", "")
	for _, entry in ipairs(self.list) do
		if (pid and tostring(entry.pid) == pid) or (not pid and entry.name == name) then
			return entry
		end
	end
end

return MilesSessionList

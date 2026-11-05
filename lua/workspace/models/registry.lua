local Agent = require("workspace.models.agent")

local Registry = {}
Registry.__index = Registry

function Registry.new(entries, alive)
	local self = setmetatable({ by_id = {}, list = {} }, Registry)
	for _, entry in ipairs(entries) do
		if entry.sessionId and not entry.parkedJobId then
			entry.alive = entry.pid ~= nil and alive(entry.pid)
			self.by_id[entry.sessionId] = entry
			table.insert(self.list, entry)
		end
	end
	return self
end

function Registry:entry(id)
	return self.by_id[id]
end

function Registry:needs_reconcile(agent)
	if agent:is_hosted() then
		return agent:renamed_by(self.by_id[agent.id])
	end
	local entry = self.by_id[agent.id]
	local alive = entry ~= nil and entry.alive
	return agent:is_running() ~= alive or not agent:in_sync(entry) or agent:renamed_by(entry)
end

function Registry:reconcile(agent, now, asking)
	local entry = self.by_id[agent.id]
	if agent:is_hosted() then
		agent.name = entry and entry.name or agent.name
		return true
	end
	return agent:reconcile(entry, entry ~= nil and entry.alive, now, asking)
end

function Registry:wait(agent, now)
	if agent:is_hosted() then
		return nil
	end
	return agent:status_wait(self.by_id[agent.id], now)
end

function Registry:untracked(known)
	local list = {}
	for _, entry in ipairs(self.list) do
		if entry.alive and not known[entry.sessionId] then
			table.insert(list, entry)
		end
	end
	return list
end

function Registry.adopt(agent, entry, now)
	local fresh = Agent.from_registry(entry)
	agent.cwd, agent.root, agent.name, agent.pid = fresh.cwd, fresh.root, fresh.name, fresh.pid
	agent:apply(entry.status == "busy" and "prompt" or "start", now)
end

function Registry:recipient(to)
	local pid = to:match("^uds:.-/(%d+)%.sock$")
	local name = to:gsub(" %[.*%]$", "")
	for _, entry in ipairs(self.list) do
		if (pid and tostring(entry.pid) == pid) or (not pid and entry.name == name) then
			return entry
		end
	end
end

return Registry

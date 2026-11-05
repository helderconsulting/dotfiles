local models = require("workspace.models")
local Agent, Ask, Runtime, Usage = models.Agent, models.Ask, models.Runtime, models.Usage

local M = {}

local function index(list, key)
	local out = {}
	for _, item in ipairs(list) do
		out[item[key]] = item
	end
	return out
end

local function pending_by_session(asks)
	local out = {}
	for _, a in ipairs(asks) do
		if a:is_pending() then
			out[a.session] = out[a.session] or {}
			table.insert(out[a.session], a)
		end
	end
	return out
end

local function hydrate(agent, runtimes, usages, asks)
	local runtime = runtimes[agent.id]
	local provider = runtime and runtime.provider or Runtime.default_provider
	return agent:attach({ runtime = runtime, usage = usages[provider], asks = asks[agent.id] })
end

function M.all(store)
	local runtimes = index(store:all(Runtime), "id")
	local usages = index(store:all(Usage), "id")
	local asks = pending_by_session(store:all(Ask))
	local out = {}
	for _, agent in ipairs(store:all(Agent)) do
		table.insert(out, hydrate(agent, runtimes, usages, asks))
	end
	return out
end

function M.get(store, id)
	local agent = id and store:get(Agent, id)
	if not agent then
		return nil
	end
	local runtime = store:get(Runtime, id)
	local provider = runtime and runtime.provider or Runtime.default_provider
	return hydrate(agent, { [id] = runtime }, { [provider] = store:get(Usage, provider) }, pending_by_session(store:all(Ask)))
end

function M.record(store, report, now)
	report.provider = report.provider or Runtime.default_provider
	if report.type ~= "usage" and report.id then
		store:update(Runtime, report.id, function(r, created)
			if created then
				r.provider = report.provider
			end
			return r:observe(report, now)
		end)
	end
	store:update(Usage, report.provider, function(u)
		return u:observe(report, now)
	end)
end

function M.lose_all_but(store, live, now)
	for _, r in ipairs(store:all(Runtime)) do
		if r:channel() == "sdk" and not live[r.id] then
			store:update(Runtime, r.id, function(x)
				return x:observe({ event = "lose" }, now)
			end)
		end
	end
end

return M

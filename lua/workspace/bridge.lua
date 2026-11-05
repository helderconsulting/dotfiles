local nvim = require("workspace.nvim")
local hooks = require("workspace.hooks")
local models = require("workspace.models")
local agents = require("workspace.agents")
local Agent, Ask = models.Agent, models.Ask

local Bridge = {}
Bridge.__index = Bridge

function Bridge.new(store, reply)
	return setmetatable({ store = store, reply = reply, waiting = {} }, Bridge)
end

function Bridge:hook(req)
	return hooks.handle(self.store, req.payload, { background = true, host = "agentd" })
end

function Bridge:started(req)
	return hooks.handle(self.store, { session_id = req.id, hook_event_name = "SessionStart", cwd = req.cwd }, { background = true, host = "agentd" })
end

function Bridge:runtime(req)
	local report = req.report
	agents.record(self.store, report, nvim.clock())
	self.store:log({ type = "runtime", provider = report.provider, id = report.id, event = report.event or report.type, model = report.model, reason = report.reason })
end

function Bridge:ask(req, id)
	local ask_id = ("%d-%s"):format(os.time(), tostring(req.request))
	self.store:update(Ask, ask_id, function(a)
		local fresh = Ask.from_sdk(req, ask_id, nvim.clock())
		for _, f in ipairs(Ask.fields) do
			a[f] = fresh[f]
		end
	end)
	self.store:update(Agent, req.session, function(a)
		a:apply("ask", nvim.clock())
	end)
	self.waiting[ask_id] = { reply = id, request = req.request }
	return nil, true
end

function Bridge:settle(ask)
	local wait = ask and self.waiting[ask.id]
	if not wait or ask:is_pending() then
		return
	end
	self.waiting[ask.id] = nil
	if ask.state == "answered" then
		self.store:update(Agent, ask.session, function(a)
			a:apply("answer", nvim.clock())
		end)
		self.store:log({ type = "ask", session = ask.session, root = ask.cwd, kind = ask.kind, tool = ask.tool, input = ask.input, decision = ask.decision, answers = ask.answers, text = ask:summary(), answer = ask:answer_text() })
	end
	self.store:remove(Ask, ask.id)
	self.reply(wait.reply, ask:result())
end

function Bridge:cancel(req)
	for ask_id, wait in pairs(self.waiting) do
		if wait.request == req.request then
			self.store:update(Ask, ask_id, function(a)
				return a:is_pending() and a:dismiss(nvim.clock())
			end)
			self:settle(self.store:get(Ask, ask_id))
		end
	end
end

local function set(ids)
	local out = {}
	for _, id in ipairs(ids or {}) do
		out[id] = true
	end
	return out
end

function Bridge:sync(req)
	local live = set(req.sessions)
	local now = nvim.clock()
	agents.lose_all_but(self.store, live, now)
	for _, a in ipairs(self.store:all(Agent)) do
		if a:is_hosted() and a:is_running() and not live[a.id] then
			self.store:update(Agent, a.id, function(x)
				return x:apply("end", now)
			end)
			hooks.drop_asks(self.store, a.id)
		end
	end
	if req.saved then
		agents.forget_ended(self.store, live, set(req.saved))
	end
end

function Bridge:handle(msg)
	local op = Bridge.ops[msg.op]
	if not op then
		return self.reply(msg.id, nil, "unknown op " .. tostring(msg.op))
	end
	local ok, result, deferred = pcall(op, self, msg, msg.id)
	if not ok then
		return self.reply(msg.id, nil, tostring(result))
	end
	if msg.id and not deferred then
		self.reply(msg.id, result)
	end
end

Bridge.ops = {
	hook = Bridge.hook,
	started = Bridge.started,
	runtime = Bridge.runtime,
	ask = Bridge.ask,
	cancel = Bridge.cancel,
	sync = Bridge.sync,
}

return Bridge

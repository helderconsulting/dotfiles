local Miles = require("workspace.legio.domain.miles")
local PostGuard = require("workspace.legio.domain.post_guard")
local Cohors = require("workspace.legio.domain.cohors")
local PostResolver = require("workspace.legio.domain.post_resolver")
local MilesProcess = require("workspace.legio.domain.miles_process")
local MilesSessionList = require("workspace.legio.domain.miles_session_list")

local MilesSessionEvents = {}
MilesSessionEvents.__index = MilesSessionEvents

local M = {}

function M.new(ports)
	return setmetatable({
		milites = ports.milites,
		processes = ports.processes,
		usages = ports.usages,
		questions = ports.questions,
		contubernia = ports.contubernia,
		cohortes = ports.cohortes,
		centuriae = ports.centuriae,
		legiones = ports.legiones,
		contubernia_records = ports.contubernia_records,
		handover = ports.handover,
		merge_requests = ports.merge_requests,
		reviews = ports.reviews,
		git = ports.git,
		sessions = ports.sessions,
		pid_alive = ports.pid_alive,
		encode = ports.encode,
		cwd = ports.cwd,
		log = ports.log or function() end,
		clock = ports.clock or os.time,
	}, MilesSessionEvents)
end

local function set_of(ids)
	local out = {}
	for _, id in ipairs(ids or {}) do
		out[id] = true
	end
	return out
end

function MilesSessionEvents:record_message(payload)
	local input = payload.tool_input or {}
	local entry = input.to and self.sessions.list():recipient(input.to)
	if not entry or not entry.sessionId then
		return
	end
	self.milites:update(entry.sessionId, function(a)
		a:receive_message(self.clock())
		a.cwd = a.cwd or entry.cwd
	end)
	local text = input.message or input.content or ""
	self.log({
		type = "message",
		from_session = payload.session_id,
		from_root = payload.cwd,
		to = input.to,
		to_session = entry.sessionId,
		to_root = entry.cwd,
		text = type(text) == "string" and text or self.encode(text),
	})
end

function MilesSessionEvents:update_miles(payload, command)
	local event = payload.transition
	if event then
		local place = Miles.relocates_on(event) and payload.cwd and self.git.locate(payload.cwd) or nil
		self.milites:update(payload.session_id, function(a, created)
			if place or created then
				a:locate(place or { cwd = payload.cwd })
			end
			a:bind_pane(command.pane or "", command.background)
			a.host = command.host
			a:note_tool(payload.moment, payload.tool_name, payload.tool_input, self.clock())
			if event == "prompt" then
				a:begin_turn(payload.prompt, self.clock())
			end
			a:apply(event, self.clock())
		end)
	end
	self.questions:dismiss_superseded(payload.session_id, event)
end

function MilesSessionEvents:poke_merge_request(payload)
	local miles = self.milites:find(payload.session_id)
	if self.merge_requests.allows(miles and miles.role) and self.merge_requests.pokes(payload) then
		self.merge_requests.poke(self.git.locate(payload.cwd or self.cwd()).root)
	end
end

function MilesSessionEvents:session_ended(id)
	local miles = self.milites:find(id)
	if miles and miles:keeps_record() then
		self.milites:update(id, function(a)
			return a:apply("end", self.clock())
		end)
		return
	end
	self.milites:remove(id)
	self.contubernia:remove_miles(id)
end

function MilesSessionEvents:legio_post(miles)
	local deployed = PostResolver.deployed({
		legiones = self.legiones,
		centuriae = self.centuriae,
		cohortes = self.cohortes,
		contubernia_records = self.contubernia_records,
	})
	local legio, post = PostResolver.of(miles.id, deployed, miles)
	return legio, post
end

function MilesSessionEvents:post_block(payload)
	if payload.moment ~= "before_tool" then
		return nil
	end
	local miles = self.milites:find(payload.session_id)
	if not miles then
		return nil
	end
	if type(self.contubernia.plan_gate_open) ~= "function" then
		self.log({ type = "post_guard", event = "port missing", session = payload.session_id, tool = payload.tool_name })
		return nil
	end
	local ok, reason = pcall(function()
		local legio, role = self:legio_post(miles)
		if not legio then
			return nil
		end
		local root = miles.root or payload.cwd
		local found, commander = pcall(function()
			local cohors = root and self.cohortes:get(Cohors.key(root))
			return cohors ~= nil and cohors:committed_by_commander() or false
		end)
		local rights = { commander_commits = true }
		if found then
			rights = { commander_commits = commander == true }
		else
			self.log({ type = "post_guard", event = "cohors lookup failed", session = payload.session_id, tool = payload.tool_name, error = tostring(commander) })
		end
		return PostGuard.check(role, self.contubernia:plan_gate_open(miles.id), payload.tool_name, payload.tool_input, root, payload.cwd, rights)
	end)
	if not ok then
		self.log({ type = "post_guard", event = "error", session = payload.session_id, tool = payload.tool_name, error = tostring(reason) })
		return nil
	end
	return reason and { hookSpecificOutput = { hookEventName = "PreToolUse", permissionDecision = "deny", permissionDecisionReason = reason } } or nil
end

function MilesSessionEvents:hook_output(payload, command)
	local cwd = payload.cwd or self.cwd()
	local blocked = self:post_block(payload) or self.reviews.check_tool_use(payload, cwd)
	if blocked then
		return blocked
	elseif command.ask and self.questions:handles(payload, command.background) then
		return command.ask(payload)
	elseif payload.moment == "stop" then
		return self.handover:check_stop(payload) or self.reviews.check_stop(payload, cwd)
	elseif payload.moment == "end" then
		self:session_ended(payload.session_id)
	end
	return nil
end

function MilesSessionEvents:apply(command)
	local payload = command.payload
	if payload.moment == "before_tool" and payload.tool_name == "SendMessage" then
		self:record_message(payload)
		return nil
	end
	self:update_miles(payload, command)
	self:poke_merge_request(payload)
	return self:hook_output(payload, command)
end

function MilesSessionEvents:record_report(command)
	local now = self.clock()
	command.provider = command.provider or MilesProcess.default_provider
	if command.type ~= "usage" and command.id then
		self.processes:update(command.id, function(r, created)
			if created then
				r.provider = command.provider
			end
			return r:observe(command, now)
		end)
	end
	if command.id and Miles.observes(command) and self.milites:find(command.id) then
		self.milites:update(command.id, function(a)
			return a:observe(command, now)
		end)
	end
	self.usages:update(command.provider, function(u)
		return u:observe(command, now)
	end)
end

function MilesSessionEvents:receive_report(command)
	self:record_report(command)
	self.log({ type = "runtime", provider = command.provider, id = command.id, event = command.event or command.type, model = command.model, reason = command.reason })
end

function MilesSessionEvents:mark_processes_lost(live, now)
	for _, r in ipairs(self.processes:all()) do
		if r:channel() == "sdk" and not live[r.id] then
			self.processes:update(r.id, function(x)
				return x:observe({ event = "lose" }, now)
			end)
		end
	end
end

function MilesSessionEvents:end_milites_agentd_stopped(live, now)
	for _, a in ipairs(self.milites:plain_all()) do
		if a:is_hosted() and a:is_running() and not live[a.id] then
			self.milites:update(a.id, function(x)
				return x:apply("end", now)
			end)
			self.questions:dismiss_open(a.id, now)
		end
	end
end

function MilesSessionEvents:delete_milites_agentd_dropped(live, saved)
	for _, a in ipairs(self.milites:plain_all()) do
		if a:is_hosted() and not a:is_running() and not live[a.id] and not saved[a.id] then
			self:session_ended(a.id)
		end
	end
	for _, r in ipairs(self.processes:all()) do
		local miles = self.milites:find(r.id)
		if not live[r.id] and not saved[r.id] and not (miles and miles:is_running()) then
			self.processes:remove(r.id)
		end
	end
end

function MilesSessionEvents:sessions_running(command)
	local live = set_of(command.sessions)
	local now = self.clock()
	self:mark_processes_lost(live, now)
	self:end_milites_agentd_stopped(live, now)
	if command.saved then
		self:delete_milites_agentd_dropped(live, set_of(command.saved))
	end
end

function MilesSessionEvents:asking_ids(now)
	local out = {}
	for _, miles in ipairs(self.milites:all()) do
		for _, ask in ipairs(miles:pending_asks()) do
			if not ask:is_stale(now, self.pid_alive(ask.pid)) then
				out[miles.id] = true
			end
		end
	end
	return out
end

function MilesSessionEvents:reconcile(registry, miles, now, asking)
	if not registry:needs_reconcile(miles) then
		return miles
	end
	return self.milites:update(miles.id, function(a)
		return registry:reconcile(a, now, asking[a.id])
	end)
end

function MilesSessionEvents:sync_session_files()
	local registry = self.sessions.list()
	local now = self.clock()
	local asking = self:asking_ids(now)
	local known, wait = {}, nil
	for _, miles in ipairs(self.milites:plain_all()) do
		known[miles.id] = true
		local left = registry:wait(self:reconcile(registry, miles, now, asking), now)
		wait = left and math.min(wait or left, left) or wait
	end
	for _, entry in ipairs(registry:untracked(known)) do
		self.milites:update(entry.sessionId, function(a)
			MilesSessionList.adopt(a, entry, now)
		end)
	end
	return wait
end

M.poke_merge_request = MilesSessionEvents.poke_merge_request

return M

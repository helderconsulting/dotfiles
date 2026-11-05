local Model = require("workspace.model")
local format = require("workspace.format")

local Agent = Model.extend({
	kind = "agents",
	fields = { "id", "state", "cwd", "root", "branch", "worktree", "title", "name", "pid", "pane", "read_at", "activity", "sending", "outbox", "updated", "doing", "host", "prompt" },
	machine = {
		initial = "starting",
		states = {
			starting = { start = "idle", prompt = "working", tool = "working", work = "working", ask = "waiting", stop = "done" },
			idle = { start = "idle", prompt = "working", tool = "working", work = "working", ask = "waiting", stop = "done" },
			working = { prompt = "working", tool = "working", ask = "waiting", stop = "done", settle = "idle" },
			waiting = { ask = "waiting", answer = "working", prompt = "working", tool = "working", work = "working", stop = "done", settle = "idle" },
			done = { start = "idle", prompt = "working", tool = "working", work = "working", ask = "waiting" },
			stopped = { start = "idle", prompt = "working", tool = "working" },
		},
		any = { ["end"] = "stopped" },
	},
})

Agent.settle_after = 3

local relocating = { start = true, prompt = true, stop = true }

function Agent.relocates_on(event)
	return relocating[event] == true
end

function Agent.running_in(list, folder)
	local out = {}
	for _, a in ipairs(list) do
		if a:is_running() and a:within(folder) then
			table.insert(out, a)
		end
	end
	table.sort(out, function(x, y)
		return x:display_name() < y:display_name()
	end)
	return out
end

local hooks = {
	SessionStart = "start",
	UserPromptSubmit = "prompt",
	PostToolUse = "tool",
	PermissionRequest = "ask",
	Stop = "stop",
	SessionEnd = "end",
}

function Agent.hook_event(payload)
	local name = payload.hook_event_name
	if name == "PreToolUse" then
		return payload.tool_name == "AskUserQuestion" and "ask" or "tool"
	elseif name == "Notification" then
		local kind = payload.notification_type
		return (kind == nil or kind == "permission_prompt" or kind == "elicitation_dialog") and "ask" or nil
	end
	return hooks[name]
end

local tones = {
	starting = "busy",
	idle = "ok",
	working = "busy",
	waiting = "bad",
	done = "ok",
	stopped = "off",
}

local noteworthy = { stop = true }
local settles_tools = { prompt = true, stop = true, ["end"] = true }

Agent.quiet_after = 300

local function short_tool(tool)
	return tostring(tool or "tool"):match("^mcp__.+__([^_].*)$") or tostring(tool or "tool")
end

function Agent.describe_tool(tool, input)
	input = input or {}
	local what = input.description or input.command or (input.file_path and format.basename(input.file_path)) or input.pattern or input.url or input.query or input.prompt
	what = what and tostring(what):gsub("%s+", " ") or ""
	if #what > 48 then
		what = what:sub(1, 47) .. "…"
	end
	return short_tool(tool) .. (what ~= "" and (": " .. what) or "")
end

local tool_hooks = { PreToolUse = true, PostToolUse = false }

function Agent:note_tool(hook, tool, input, at)
	local running = tool_hooks[hook]
	if running == nil then
		return
	end
	self.doing = { label = Agent.describe_tool(tool, input), at = at, running = running or nil }
end

function Agent:progress(now)
	if self.state ~= "working" then
		return nil
	end
	local d = self.doing
	if d and d.running then
		return d.label .. " · " .. format.duration(now - d.at)
	end
	local quiet = now - (d and d.at or self.updated or now)
	if quiet >= Agent.quiet_after then
		return "quiet for " .. format.duration(quiet), "bad"
	end
	return (d and ("last " .. d.label) or "thinking") .. " · " .. format.duration(quiet)
end

function Agent:apply(event, at)
	if self.read_at == nil then
		self.read_at = self.updated or at
	end
	self.updated = at
	if event == "prompt" or event == "end" then
		self.sending = nil
	end
	if settles_tools[event] then
		self.doing = nil
	end
	if noteworthy[event] then
		self.activity = at
	end
	return self:transition(event, at)
end

function Agent:locate(place)
	self.cwd = place.cwd or self.cwd
	self.root = place.root or self.root
	self.branch = place.branch or self.branch
	self.worktree = place.worktree
end

function Agent:bind_pane(pane, background)
	self.pane = (not background and pane ~= "") and tonumber(pane) or nil
end

function Agent:attach(parts)
	self.runtime, self.usage, self.asks = parts.runtime, parts.usage, parts.asks or {}
	return self
end

function Agent:on_sdk()
	return self.runtime ~= nil and self.runtime:channel() == "sdk"
end

function Agent:channel()
	if self:on_sdk() then
		return "sdk"
	end
	return self.pane and "pane" or "attach"
end

function Agent:on_cli()
	return self:is_running() and not (self:on_sdk() or self.pane)
end

function Agent:provider()
	return self.runtime and self.runtime.provider or nil
end

function Agent:model_name()
	return self.runtime and self.runtime.model or nil
end

function Agent:model_label()
	return self.runtime and self.runtime:model_label() or nil
end

function Agent:mode()
	return self.runtime and self.runtime.mode or nil
end

function Agent:mode_label()
	return self.runtime and self.runtime:mode_label() or nil
end

function Agent:context_fraction()
	return self.runtime and self.runtime:context_fraction() or nil
end

function Agent:fallback_reason()
	return self.runtime and self.runtime:warning() or nil
end

function Agent:plan_label()
	return self.usage and self.usage:plan_label() or nil
end

function Agent:uses_extra()
	return self.usage ~= nil and self.usage.extra == true
end

function Agent:pending_asks()
	return self.asks or {}
end

function Agent:begin_turn(text, at)
	if type(text) == "string" and text ~= "" then
		self.prompt = { text = text, at = at }
	end
end

function Agent:awaiting_turn(transcript, now)
	local started = self:is_busy() and self.prompt
	if started and not (transcript and transcript:received(started.text, started.at)) then
		return { text = started.text, at = started.at, started = true }
	end
	local sending = self:pending_send(now)
	if sending and not (transcript and transcript:received(sending.text, sending.at)) then
		return sending
	end
end

function Agent:short()
	return self.id:sub(1, 8)
end

function Agent:display_name()
	if self.title and self.title ~= "" then
		return self.title
	end
	if self.name and self.name ~= "" then
		return self.name
	end
	return (self.root or self.cwd or self.id):match("([^/]+)/?$") or self.id
end

function Agent:is_hosted()
	return self.host ~= nil
end

function Agent:is_running()
	return self.state ~= "stopped"
end

function Agent:is_busy()
	return self.state == "working" or self.state == "waiting" or self.state == "starting"
end

function Agent:needs_you()
	return self.state == "waiting"
end

function Agent:can_receive()
	if self.state == "waiting" then
		return false, self:display_name() .. " is waiting on a prompt, answer it first"
	end
	return true
end

function Agent:start_sending(text, at)
	self.sending = { text = text, at = at }
end

local ready_for_next = { idle = true, done = true }

function Agent:hold(text, at)
	self.outbox = self.outbox or {}
	table.insert(self.outbox, { id = ("%d-%d"):format(math.floor(at * 1000), #self.outbox + 1), text = text, at = at })
end

function Agent:held()
	return self.outbox or {}
end

function Agent:can_release()
	return ready_for_next[self.state] == true and #self:held() > 0
end

function Agent:take(id)
	for i, m in ipairs(self:held()) do
		if id == nil or m.id == id then
			table.remove(self.outbox, i)
			if #self.outbox == 0 then
				self.outbox = nil
			end
			return m
		end
	end
end

function Agent:release()
	return self:can_release() and self:take() or nil
end

function Agent:pending_send(now, limit)
	local s = self.sending
	if s and now - (s.at or 0) <= (limit or 120) then
		return s
	end
end

function Agent:receive_message(at)
	if self.read_at == nil then
		self.read_at = self.updated or at
	end
	self.activity = at
end

function Agent:is_read(at)
	return self.read_at == nil or (at or 0) <= self.read_at
end

function Agent:unread()
	return self.activity ~= nil and not self:is_read(self.activity)
end

function Agent:mark_read(at)
	if not at or self:is_read(at) and self.read_at ~= nil then
		return false
	end
	self.read_at = at
	return true
end

function Agent:status()
	return self.state, tones[self.state] or "ok"
end

local urgency = { waiting = 5, working = 4, starting = 3, done = 2, idle = 1, stopped = 0 }

function Agent.most_pressing(list)
	local top, rank
	for _, a in ipairs(list) do
		local r = urgency[(a:status())] or 0
		if not top or r > rank then
			top, rank = a, r
		end
	end
	return top
end

function Agent.from_registry(entry)
	return Agent:new({ id = entry.sessionId, cwd = entry.cwd, root = entry.cwd, name = entry.name, pid = entry.pid })
end

function Agent:within(folder)
	local path = self.root or self.cwd
	return path ~= nil and (path == folder or path:sub(1, #folder + 1) == folder .. "/")
end

local registry = {
	busy = { event = "work", states = { working = true, starting = true } },
	waiting = { event = "ask", states = { waiting = true } },
	idle = { event = "settle", states = { idle = true, done = true, starting = true }, delay = Agent.settle_after },
}

function Agent:in_sync(entry)
	local r = entry and registry[entry.status]
	return not r or r.states[self.state] == true
end

function Agent:reconcile(entry, alive, now, asking)
	if not entry or not alive then
		if self:is_running() then
			self:apply("end", now)
			return true
		end
		return false
	end
	local renamed = self:renamed_by(entry)
	self.name = entry.name or self.name
	self.pid = entry.pid or self.pid
	if not self:is_running() then
		self:apply("start", now)
		return true
	end
	return self:follow_status(entry, now, asking) or renamed
end

function Agent:renamed_by(entry)
	return entry ~= nil and entry.name ~= nil and entry.name ~= self.name
end

function Agent:follow_status(entry, now, asking)
	local r = registry[entry.status]
	if not r or self:in_sync(entry) or (asking and self.state == "waiting") then
		return false
	end
	local changed = entry.statusUpdatedAt and entry.statusUpdatedAt / 1000
	if changed and changed <= (self.updated or 0) then
		return false
	end
	if now - (changed or self.updated or 0) < (r.delay or 0) or not self:can(r.event) then
		return false
	end
	return self:apply(r.event, now)
end

function Agent:status_wait(entry, now)
	local r = entry and registry[entry.status]
	if not (r and r.delay) or self:in_sync(entry) or not self:can(r.event) then
		return nil
	end
	local changed = entry.statusUpdatedAt and entry.statusUpdatedAt / 1000
	if changed and changed <= (self.updated or 0) then
		return nil
	end
	local left = r.delay - (now - (changed or self.updated or 0))
	return left > 0 and left or nil
end

return Agent

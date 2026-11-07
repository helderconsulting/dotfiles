local Model = require("workspace.shared.lib.model")
local format = require("workspace.shared.lib.format")

local Miles = Model.extend({
	kind = "milites",
	fields = { "id", "state", "cwd", "root", "branch", "worktree", "title", "name", "pid", "pane", "read_at", "activity", "sending", "outbox", "updated", "doing", "host", "prompt", "limit", "legio", "role", "roman_name", "mandata", "expeditiones", "traditio", "caller", "due", "stopped_by" },
	machine = {
		initial = "starting",
		states = {
			starting = { start = "idle", prompt = "working", tool = "working", work = "working", ask = "waiting", stop = "done", limit = "limited" },
			idle = { start = "idle", prompt = "working", tool = "working", work = "working", ask = "waiting", stop = "done", limit = "limited" },
			working = { prompt = "working", tool = "working", ask = "waiting", stop = "done", settle = "idle", limit = "limited" },
			waiting = { ask = "waiting", answer = "working", prompt = "working", tool = "working", work = "working", stop = "done", settle = "idle", limit = "limited" },
			done = { start = "idle", prompt = "working", tool = "working", work = "working", ask = "waiting", limit = "limited" },
			limited = { limit = "limited", start = "limited", stop = "limited", settle = "limited", resume = "working", prompt = "working", tool = "working", work = "working", ask = "waiting" },
			stopped = { start = "idle", prompt = "working", tool = "working" },
			handing_over = { tool = "handing_over", prompt = "handing_over", stop = "handing_over", settle = "handing_over", ask = "handing_over", answer = "handing_over", work = "handing_over", start = "handing_over", limit = "handing_over" },
			fallen = { ["end"] = "fallen", start = "fallen", stop = "fallen", settle = "fallen", limit = "fallen" },
		},
		any = { ["end"] = "stopped", hand_over = "handing_over", fall = "fallen" },
	},
})

Miles.settle_after = 3

function Miles.new_id(random)
	local hex = function(n)
		local out = {}
		for i = 1, n do
			out[i] = ("%x"):format(random(0, 15))
		end
		return table.concat(out)
	end
	return ("%s-%s-4%s-%x%s-%s"):format(hex(8), hex(4), hex(3), random(8, 11), hex(3), hex(12))
end

local relocating = { start = true, prompt = true, stop = true }

function Miles.relocates_on(event)
	return relocating[event] == true
end

function Miles.called(list, name)
	for _, a in ipairs(list) do
		if a:is_running() and (a.id == name or a.name == name or a.roman_name == name) then
			return a
		end
	end
end

function Miles.running_in(list, folder)
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

local tones = {
	starting = "busy",
	idle = "ok",
	working = "busy",
	waiting = "bad",
	done = "ok",
	stopped = "off",
	limited = "limit",
	handing_over = "busy",
	fallen = "off",
}

local noteworthy = { stop = true }
local settles_tools = { prompt = true, stop = true, ["end"] = true }

Miles.quiet_after = 300

local function short_tool(tool)
	return tostring(tool or "tool"):match("^mcp__.+__([^_].*)$") or tostring(tool or "tool")
end

function Miles.describe_tool(tool, input)
	input = input or {}
	local what = input.description or input.command or (input.file_path and format.basename(input.file_path)) or input.pattern or input.url or input.query or input.prompt
	what = what and tostring(what):gsub("%s+", " ") or ""
	if #what > 48 then
		what = what:sub(1, 47) .. "…"
	end
	return short_tool(tool) .. (what ~= "" and (": " .. what) or "")
end

local tool_moments = { before_tool = true, after_tool = false }

function Miles:note_tool(moment, tool, input, at)
	local running = tool_moments[moment]
	if running == nil then
		return
	end
	self.doing = { label = Miles.describe_tool(tool, input), at = at, running = running or nil }
end

function Miles:pulse(now)
	local d = self.doing
	local last = math.max(d and d.at or 0, self.updated or 0)
	return {
		state = self.state,
		doing = d and d.label or nil,
		running = d and d.running or false,
		quiet = last > 0 and math.max(0, now - last) or nil,
		waiting = #self:held(),
	}
end

local progress = {}

function Miles:progress(now)
	local describe = progress[self.state]
	if not describe then
		return nil
	end
	return describe(self, now)
end

function progress.working(self, now)
	local d = self.doing
	if d and d.running then
		return d.label .. " · " .. format.duration(now - d.at)
	end
	local quiet = now - (d and d.at or self.updated or now)
	if quiet >= Miles.quiet_after then
		return "quiet for " .. format.duration(quiet), "bad"
	end
	return (d and ("last " .. d.label) or "thinking") .. " · " .. format.duration(quiet)
end

function progress.limited(self, now)
	local l = self.limit or {}
	if not l.resets_at then
		return nil
	end
	local window = l.window and (l.window .. " ") or ""
	if l.resets_at > now then
		return window .. "resets " .. format.clock(l.resets_at, now) .. " · in " .. format.duration(l.resets_at - now)
	end
	return window .. "reset " .. format.clock(l.resets_at, now) .. " · continuing"
end

local reports = {
	limit = function(self, report, at)
		local fresh = self.state ~= "limited"
		self.limit = { resets_at = report.resets_at, window = report.window }
		local moved = self:apply("limit", at)
		if moved and fresh then
			self.activity = at
		end
		return moved
	end,
}

function Miles.observes(report)
	return reports[report.event] ~= nil
end

function Miles:observe(report, at)
	return reports[report.event](self, report, at)
end

function Miles:can_continue()
	if not self:can("resume") then
		return false, self:display_name() .. " isn't stopped on a usage limit"
	end
	return true
end

function Miles:continue(at)
	return self:can("resume") and self:apply("resume", at)
end

function Miles:apply(event, at)
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
	local moved = self:transition(event, at)
	if self.state ~= "limited" then
		self.limit = nil
	end
	return moved
end

function Miles:locate(place)
	self.cwd = place.cwd or self.cwd
	self.root = place.root or self.root
	self.branch = place.branch or self.branch
	self.worktree = place.worktree
end

function Miles:bind_pane(pane, background)
	self.pane = (not background and pane ~= "") and tonumber(pane) or nil
end

function Miles:hydrate(parts)
	self.runtime, self.usage, self.asks = parts.runtime, parts.usage, parts.asks or {}
	return self
end

function Miles:on_sdk()
	return self.runtime ~= nil and self.runtime:channel() == "sdk"
end

function Miles:channel()
	if self:on_sdk() then
		return "sdk"
	end
	return self.pane and "pane" or "attach"
end

function Miles:wants_resume()
	return not self:is_running() or (self:is_hosted() and not self:on_sdk())
end

function Miles:on_cli()
	return self:is_running() and not (self:on_sdk() or self.pane)
end

function Miles:provider()
	return self.runtime and self.runtime.provider or nil
end

function Miles:model_name()
	return self.runtime and self.runtime.model or nil
end

function Miles:model_label()
	return self.runtime and self.runtime:model_label() or nil
end

function Miles:mode()
	return self.runtime and self.runtime.mode or nil
end

function Miles:mode_label()
	return self.runtime and self.runtime:mode_label() or nil
end

function Miles:context_fraction()
	return self.runtime and self.runtime:context_fraction() or nil
end

function Miles:fallback_reason()
	return self.runtime and self.runtime:warning() or nil
end

function Miles:plan_label()
	return self.usage and self.usage:plan_label() or nil
end

function Miles:uses_extra()
	return self.usage ~= nil and self.usage.extra == true
end

function Miles:pending_asks()
	return self.asks or {}
end

function Miles:begin_turn(text, at)
	if type(text) == "string" and text ~= "" then
		self.prompt = { text = text, at = at }
	end
end

function Miles:awaiting_turn(transcript, now)
	local started = self:is_busy() and self.prompt
	if started and not (transcript and transcript:received(started.text, started.at)) then
		return { text = started.text, at = started.at, started = true }
	end
	local sending = self:pending_send(now)
	if sending and not (transcript and transcript:received(sending.text, sending.at)) then
		return sending
	end
end

function Miles:short()
	return self.id:sub(1, 8)
end

function Miles:display_name()
	if self.title and self.title ~= "" then
		return self.title
	end
	if self.roman_name and self.roman_name ~= "" then
		return self.roman_name
	end
	if self.name and self.name ~= "" then
		return self.name
	end
	return (self.root or self.cwd or self.id):match("([^/]+)/?$") or self.id
end

function Miles:is_hosted()
	return self.host ~= nil
end

local gone = { stopped = true, fallen = true }

function Miles:is_running()
	return not gone[self.state]
end

function Miles:is_auxilium()
	return self.caller ~= nil
end

Miles.auxilium_limit = 900

function Miles:is_overdue(now)
	return self:is_auxilium() and self:is_running() and self.due ~= nil and now >= self.due
end

local busy = { working = true, waiting = true, starting = true, handing_over = true }

function Miles:is_busy()
	return busy[self.state] == true
end

function Miles:needs_you()
	return self.state == "waiting"
end

function Miles:can_receive()
	if self.state == "waiting" then
		return false, self:display_name() .. " is waiting on a prompt, answer it first"
	end
	return true
end

function Miles:start_sending(text, at)
	self.sending = { text = text, at = at }
end

local ready_for_next = { idle = true, done = true }

function Miles:stop_on_purpose(reason, at)
	self.stopped_by = { reason = reason, at = at }
end

function Miles:was_stopped_on_purpose()
	return self.stopped_by ~= nil
end

function Miles:clear_stop()
	self.stopped_by = nil
end

function Miles:hold(text, at)
	self.outbox = self.outbox or {}
	table.insert(self.outbox, { id = ("%d-%d"):format(math.floor(at * 1000), #self.outbox + 1), text = text, at = at })
end

function Miles:held()
	return self.outbox or {}
end

function Miles:can_release()
	return ready_for_next[self.state] == true and #self:held() > 0
end

function Miles:take(id)
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

function Miles:release()
	return self:can_release() and self:take() or nil
end

function Miles:pending_send(now, limit)
	local s = self.sending
	if s and now - (s.at or 0) <= (limit or 120) then
		return s
	end
end

function Miles:receive_message(at)
	if self.read_at == nil then
		self.read_at = self.updated or at
	end
	self.activity = at
end

function Miles:is_read(at)
	return self.read_at == nil or (at or 0) <= self.read_at
end

function Miles:unread()
	return self.activity ~= nil and not self:is_read(self.activity)
end

function Miles:mark_read(at)
	if not at or self:is_read(at) and self.read_at ~= nil then
		return false
	end
	self.read_at = at
	return true
end

function Miles:status()
	return self.state, tones[self.state] or "ok"
end

local urgency = { waiting = 6, limited = 5, handing_over = 4, working = 4, starting = 3, done = 2, idle = 1, stopped = 0, fallen = 0 }

function Miles.most_pressing(list)
	local top, rank
	for _, a in ipairs(list) do
		local r = urgency[(a:status())] or 0
		if not top or r > rank then
			top, rank = a, r
		end
	end
	return top
end

Miles.ranks = {
	{ name = "triarius", mandata = 10, expeditiones = 3 },
	{ name = "princeps", mandata = 3 },
	{ name = "hastatus", mandata = 0 },
}

Miles.handover_at = 0.9

local function count(list)
	return #(list or {})
end

local function earned(rank, mandata, expeditiones)
	return mandata >= rank.mandata or (rank.expeditiones ~= nil and expeditiones >= rank.expeditiones)
end

function Miles:rank()
	for _, rank in ipairs(Miles.ranks) do
		if earned(rank, count(self.mandata), count(self.expeditiones)) then
			return rank.name
		end
	end
end

local function toward(rank, mandata, expeditiones)
	local by_mandata = { done = mandata, needed = rank.mandata, unit = "mandata" }
	if not rank.expeditiones then
		return by_mandata
	end
	local by_expeditiones = { done = expeditiones, needed = rank.expeditiones, unit = "expeditiones" }
	return by_expeditiones.done / by_expeditiones.needed > by_mandata.done / by_mandata.needed and by_expeditiones or by_mandata
end

function Miles.standing_of(mandata, expeditiones)
	for i, rank in ipairs(Miles.ranks) do
		if earned(rank, mandata, expeditiones) then
			local standing = { rank = rank.name, level = #Miles.ranks - i + 1 }
			local next_rank = Miles.ranks[i - 1]
			if next_rank then
				local progress = toward(next_rank, mandata, expeditiones)
				standing.next, standing.done, standing.needed, standing.unit = next_rank.name, progress.done, progress.needed, progress.unit
			end
			return standing
		end
	end
end

function Miles:standing()
	return Miles.standing_of(count(self.mandata), count(self.expeditiones))
end

function Miles.ladder()
	local out = {}
	for i = #Miles.ranks, 1, -1 do
		local rank = Miles.ranks[i]
		table.insert(out, { rank = rank.name, level = #Miles.ranks - i + 1, mandata = rank.mandata, expeditiones = rank.expeditiones })
	end
	return out
end

function Miles:seniority()
	for i, rank in ipairs(Miles.ranks) do
		if rank.name == self:rank() then
			return #Miles.ranks - i
		end
	end
	return 0
end

local function credit(list, id)
	list = list or {}
	for _, known in ipairs(list) do
		if known == id then
			return list, false
		end
	end
	table.insert(list, id)
	return list, true
end

function Miles:finish_mandatum(id)
	local before = self:rank()
	local added
	self.mandata, added = credit(self.mandata, id)
	return added, self:rank() ~= before and self:rank() or nil
end

function Miles:finish_expeditio(id)
	local before = self:rank()
	local added
	self.expeditiones, added = credit(self.expeditiones, id)
	return added, self:rank() ~= before and self:rank() or nil
end

function Miles:enlist(legio, role, roman_name, place)
	self.legio, self.role, self.roman_name = legio, role, roman_name
	self.cwd = self.cwd or place
	self.root = self.root or place
end

function Miles:promote(role)
	self.role = role
end

function Miles:is_veteran()
	return self:seniority() > 0
end

function Miles.by_seniority(a, b)
	local x, y = a:seniority(), b:seniority()
	if x ~= y then
		return x > y
	end
	return (a.roman_name or "") < (b.roman_name or "")
end

function Miles:is_enlisted()
	return self.legio ~= nil
end

function Miles:keeps_record()
	return self:is_enlisted() or self.state == "fallen"
end

function Miles:due_for_handover()
	local fraction = self:context_fraction()
	return fraction ~= nil and fraction >= Miles.handover_at and self:can("hand_over") and self.state ~= "handing_over" and self.state ~= "fallen"
end

function Miles:ask_for_traditio(at)
	return self:apply("hand_over", at)
end

function Miles:fall(traditio, at)
	if self.state == "fallen" then
		return false
	end
	self.traditio = { text = traditio, at = at }
	return self:apply("fall", at)
end

function Miles.from_registry(entry)
	return Miles:new({ id = entry.sessionId, cwd = entry.cwd, root = entry.cwd, name = entry.name, pid = entry.pid })
end

function Miles:within(folder)
	local path = self.root or self.cwd
	return path ~= nil and (path == folder or path:sub(1, #folder + 1) == folder .. "/")
end

local registry = {
	busy = { event = "work", states = { working = true, starting = true } },
	waiting = { event = "ask", states = { waiting = true } },
	idle = { event = "settle", states = { idle = true, done = true, starting = true, limited = true }, delay = Miles.settle_after },
}

function Miles:in_sync(entry)
	local r = entry and registry[entry.status]
	return not r or r.states[self.state] == true
end

function Miles:reconcile(entry, alive, now, asking)
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

function Miles:renamed_by(entry)
	return entry ~= nil and entry.name ~= nil and entry.name ~= self.name
end

function Miles:follow_status(entry, now, asking)
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

function Miles:status_wait(entry, now)
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

return Miles

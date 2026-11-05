local Model = require("workspace.model")
local Transcript = require("workspace.models.transcript")

local Turn = Model.extend({
	kind = "turns",
	fields = { "id", "state", "index", "prompt", "at", "source", "slot", "outbox", "last", "queued", "started" },
	machine = {
		initial = "sent",
		states = {
			sent = { queue = "pending", start = "working", finish = "done" },
			pending = { start = "working", finish = "done" },
			working = { ask = "waiting", finish = "done" },
			waiting = { finish = "done" },
			done = {},
		},
	},
})

local tones = { sent = "busy", pending = "busy", working = "busy", waiting = "bad", done = "ok" }

local function key(text)
	return Transcript.prompt_text(text)
end

local function sources(transcript, agent, now)
	local list = {}
	for i, t in ipairs(transcript and transcript.turns or {}) do
		table.insert(list, { source = "turn", slot = i, prompt = t.prompt, at = t.at, last = t.last, queued = t.queued })
	end
	if agent and agent:is_busy() and transcript then
		for k, q in ipairs(transcript:queued()) do
			table.insert(list, { source = "queue", slot = k, prompt = q.prompt, at = q.at })
		end
	end
	for _, m in ipairs(agent and agent:held() or {}) do
		table.insert(list, { source = "held", outbox = m.id, prompt = m.text, at = m.at })
	end
	local awaiting = agent and agent:awaiting_turn(transcript, now)
	if awaiting then
		table.insert(list, { source = "sending", prompt = awaiting.text, at = awaiting.at, started = awaiting.started })
	end
	return list
end

local function unique(list)
	local seen, out = {}, {}
	for _, s in ipairs(list) do
		local k = key(s.prompt)
		if s.source == "turn" or not (k and seen[k]) then
			if k then
				seen[k] = true
			end
			s.index = #out + 1
			table.insert(out, Turn:new(s))
		end
	end
	return out
end

local function active_of(turns, busy)
	local sending, lead
	for _, t in ipairs(turns) do
		if t.source == "sending" then
			sending = t
		elseif t.source == "turn" and not t.queued then
			lead = t
		end
	end
	if sending and (sending.started or not busy) then
		return sending
	end
	return busy and lead or nil
end

function Turn.collect(transcript, agent, now)
	local turns = unique(sources(transcript, agent, now))
	local busy = agent and agent:is_busy()
	local active = active_of(turns, busy)
	local rejected, after_active = {}, false
	local function step(t, event)
		if not t:transition(event) then
			table.insert(rejected, { index = t.index, from = t.state, event = event })
		end
	end
	for _, t in ipairs(turns) do
		if t == active then
			step(t, "start")
			if agent:needs_you() then
				step(t, "ask")
			end
			after_active = true
		elseif t.source == "held" or t.source == "queue" then
			step(t, busy and "queue" or "finish")
		elseif t.source == "sending" or (t.queued and busy and (after_active or not active)) then
			step(t, "queue")
		else
			step(t, "finish")
		end
	end
	return turns, rejected
end

function Turn.active_in(turns)
	local list = {}
	for _, t in ipairs(turns) do
		if t:is_active() then
			table.insert(list, t)
		end
	end
	return list
end

function Turn:tone()
	return tones[self.state]
end

function Turn:label()
	return self.state == "done" and ("turn " .. self.index) or self.state
end

function Turn:is_active()
	return self.state == "working" or self.state == "waiting"
end

function Turn:is_pending()
	return self.state == "pending"
end

return Turn

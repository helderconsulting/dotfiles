local format = require("workspace.shared.lib.format")
local Transcript = require("workspace.conversations.domain.transcript")
local Turn = require("workspace.conversations.domain.turn")
local Review = require("workspace.workflow.domain.review")

local Thread = {}
Thread.__index = Thread

local review_labels = {
	sent = { "review", "bad" },
	resolved = { "resolved", "ok" },
	ready = Review.words.ready,
	approved = Review.words.approved,
}

local event_words = { ready = Review.words.ready[1], approved = Review.words.approved[1] }
local from_agent = { resolved = true, ready = true }

function Thread.new(opts)
	local self = setmetatable({}, Thread)
	self.agent = opts.agent
	self.id = opts.id
	self.root = opts.root
	self.now = opts.now or os.time()
	self.name_of = opts.name_of or function(_, fallback)
		return fallback or "agent"
	end
	self.items = {}
	self:add_log(opts.log or {})
	self:add_asks(opts.asks or {})
	local turns = self:add_turns(opts.transcript)
	self:add_exchanges(turns)
	self:fold_review(turns)
	self:add_draft(opts.draft)
	if not (self.agent and self.agent:is_running()) then
		for _, item in ipairs(self.items) do
			item.kind = "off"
		end
	end
	table.sort(self.items, function(a, b)
		if (a.at or 0) ~= (b.at or 0) then
			return (a.at or 0) > (b.at or 0)
		end
		return a.id > b.id
	end)
	self.unread = 0
	for _, item in ipairs(self.items) do
		item.unread = item.fresh ~= nil and self.agent ~= nil and not self.agent:is_read(item.fresh) or nil
		self.unread = self.unread + (item.unread and 1 or 0)
	end
	return self
end

function Thread:age(at)
	return format.age(at, self.now)
end

function Thread:add(item)
	table.insert(self.items, item)
	return item
end

function Thread:add_log(entries)
	for _, m in ipairs(entries) do
		if m.type == "ask" and m.session == self.id then
			self:add({
				id = "ask" .. tostring(m.at),
				at = m.at,
				kind = "ok",
				card = {
					m.kind == "question" and "asked" or "permission",
					m.text or "",
					self:age(m.at) .. " · " .. (m.answer or ""),
				},
				answered = m,
			})
		elseif
			m.type == "review"
			and review_labels[m.event]
			and m.root == self.root
			and (not m.session or m.session == "" or m.session == self.id)
		then
			local label = review_labels[m.event]
			local card
			if m.path then
				local range = m.line1 == m.line2 and tostring(m.line1)
					or (tostring(m.line1) .. "-" .. tostring(m.line2))
				card = {
					label[1] .. " " .. m.path .. ":" .. range,
					m.event == "resolved" and m.reply ~= "" and m.reply or m.text,
					self:age(m.at),
				}
			else
				card = {
					label[1],
					m.note or (m.event == "approved" and "ready for a merge request" or ""),
					self:age(m.at),
				}
			end
			self:add({
				id = m.event .. tostring(m.at) .. (m.id or ""),
				at = m.at,
				fresh = from_agent[m.event] and m.at or nil,
				kind = label[2],
				card = card,
				comment = m.id and { root = m.root, id = m.id } or nil,
				event = m.event,
			})
		elseif m.type == "message" and (m.from_session == self.id or m.to_session == self.id) then
			self:add_message(m)
		end
	end
end

function Thread:add_message(m)
	local from_me = m.from_session == self.id
	self.messages = self.messages or {}
	table.insert(self.messages, {
		at = m.at,
		mine = from_me,
		text = m.text or "",
		peer = from_me and m.to_session or m.from_session,
		name = from_me and self.name_of(m.to_session, (m.to or ""):gsub(" %[.*%]$", ""))
			or self.name_of(m.from_session, format.basename(m.from_root)),
	})
end

local message_lead = 5

local function turn_of(turns, m)
	local during
	for _, t in ipairs(turns) do
		if not m.mine and t.start >= m.at - message_lead then
			return t
		end
		if t.start <= m.at then
			during = t
		end
	end
	if m.mine then
		return during
	end
end

function Thread:add_exchanges(turns)
	local messages = self.messages or {}
	self.messages = nil
	table.sort(messages, function(a, b)
		return a.at < b.at
	end)
	local by_key, list = {}, {}
	for _, m in ipairs(messages) do
		local turn = turn_of(turns, m)
		local key = tostring(m.peer) .. ":" .. tostring(turn and turn.turn or "next")
		local exchange = by_key[key]
		if not exchange then
			exchange = { type = "exchange", session = self.id, peer = m.peer, turn = turn and turn.turn, messages = {} }
			by_key[key] = exchange
			table.insert(list, { key = key, exchange = exchange })
		end
		exchange.name = m.name
		table.insert(exchange.messages, { at = m.at, mine = m.mine, text = m.text })
	end
	for _, entry in ipairs(list) do
		local exchange = entry.exchange
		local last = exchange.messages[#exchange.messages]
		local heard
		for _, m in ipairs(exchange.messages) do
			heard = not m.mine and m.at or heard
		end
		exchange.at = last.at
		local count = #exchange.messages == 1 and "1 message" or (#exchange.messages .. " messages")
		self:add({
			id = "m" .. entry.key,
			at = last.at,
			fresh = heard,
			kind = "ok",
			card = {
				"with " .. exchange.name,
				(last.mine and "→ " or "← ") .. last.text,
				self:age(last.at) .. " · " .. count .. (exchange.turn and (" · turn " .. exchange.turn) or ""),
			},
			peer = exchange.peer,
			answered = exchange,
		})
	end
end

function Thread:add_asks(asks)
	for _, ask in ipairs(asks) do
		if ask.session == self.id and ask:is_pending() then
			self:add({
				id = "ask" .. ask.id,
				at = self.now + 1,
				kind = "bad",
				card = { ask:is_question() and "question" or "permission", ask:summary(), "waiting for you" },
				ask = ask.id,
				pending = true,
			})
		end
	end
end

function Thread:add_turns(transcript)
	local list, rejected = Turn.collect(transcript, self.agent, self.now)
	self.rejected = rejected
	local items = {}
	local count = transcript and transcript:count() or 0
	for _, turn in ipairs(list) do
		local from_transcript = turn.source == "turn"
		local ids = {
			turn = "turn" .. self.id .. tostring(turn.slot),
			queue = "queue" .. self.id .. tostring(turn.slot),
			held = "outbox" .. tostring(turn.outbox),
			sending = "turn" .. self.id .. (count + 1),
		}
		local item = self:add({
			id = ids[turn.source],
			at = turn.source == "sending" and self.now or (turn.at or 0),
			start = from_transcript and (turn.at or 0) or nil,
			fresh = from_transcript and turn.state == "done" and turn.last or nil,
			kind = turn:tone(),
			card = {
				turn:label(),
				Transcript.card_line(turn.prompt),
				self:turn_status(turn, turn.at, turn.source == "held" and "held" or "queued"),
			},
			turn = from_transcript and turn.slot or nil,
			working = turn:is_active() or nil,
			pending = turn:is_pending() or nil,
			outbox = turn.outbox,
			text = turn.prompt,
		})
		if from_transcript then
			table.insert(items, item)
		end
	end
	return items
end

local pending_hints = {
	queued = " · esc interrupts to edit it",
	held = " · esc interrupts to send it now",
}

function Thread:turn_status(turn, at, waits)
	if turn:is_active() then
		return self.agent:progress(self.now)
	elseif turn:is_pending() then
		return (waits or "queued") .. " " .. self:age(at or self.now) .. pending_hints[waits or "queued"]
	end
	return self:age(at or self.now)
end

function Thread:fold_review(turns)
	if #turns == 0 then
		return
	end
	local kept = {}
	for _, item in ipairs(self.items) do
		if not item.event then
			table.insert(kept, item)
		else
			local owner
			for _, t in ipairs(turns) do
				if item.event == "sent" then
					if t.start >= item.at - 5 then
						owner = t
						break
					end
				elseif t.start <= item.at then
					owner = t
				end
			end
			if owner then
				owner.events = owner.events or {}
				owner.events[item.event] = (owner.events[item.event] or 0) + 1
			end
		end
	end
	for _, t in ipairs(turns) do
		if t.events and not t.working then
			local words = {}
			for _, event in ipairs({ "sent", "resolved", "ready", "approved" }) do
				local n = t.events[event]
				if n then
					table.insert(
						words,
						event_words[event]
							or (
								n
								.. (event == "sent" and (n == 1 and " comment sent" or " comments sent") or " resolved")
							)
					)
				end
			end
			t.card[3] = t.card[3] .. " · " .. table.concat(words, " · ")
		end
	end
	self.items = kept
end

function Thread:add_draft(draft)
	if not draft then
		return
	end
	self:add({
		id = "draft" .. self.id,
		at = draft.created or draft.mtime or self.now,
		kind = "busy",
		card = { "draft", draft.first_line, self:age(draft.mtime or self.now) .. " · not sent" },
		draft = true,
	})
end

function Thread:index_of(id)
	for i, item in ipairs(self.items) do
		if item.id == id then
			return i
		end
	end
end

function Thread:first(key)
	for _, item in ipairs(self.items) do
		if item[key] then
			return item
		end
	end
end

function Thread:latest_turn()
	return self:first("turn") or self.items[1]
end

return Thread

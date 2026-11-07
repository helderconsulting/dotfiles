local Model = require("workspace.shared.lib.model")

local ConversationScreen = Model.extend({
	kind = "conversation_screens",
	fields = { "id", "state", "agent", "turn", "draft", "ask", "history", "entry", "search", "pick", "focused", "editing", "scrolled_up", "shown_agent", "shown_turn", "waiting", "attended_until", "released", "owner_pid" },
	machine = {
		initial = "answer",
		states = {
			answer = { show = "answer", compose = "draft", ask = "ask", show_entry = "entry" },
			draft = { show = "answer", compose = "draft", finish = "answer", ask = "ask", show_entry = "entry" },
			ask = { ask = "ask", settle = "answer", compose = "draft", show = "answer" },
			entry = { show = "answer", show_entry = "entry", compose = "draft", ask = "ask" },
		},
	},
})

function ConversationScreen:show_turn(agent, turn)
	self.agent, self.turn, self.history, self.ask = agent, turn, nil, nil
	return self:transition("show")
end

function ConversationScreen:select(agent, turn)
	self:release()
	return self:show_turn(agent, turn)
end

function ConversationScreen:preview_history(agent, entry)
	self.agent, self.turn, self.history, self.ask = agent, nil, entry, nil
	return self:transition("show")
end

function ConversationScreen:selects(agent, turn, history)
	return self.agent == agent and self.turn == turn and (self.history and self.history.at) == (history and history.at)
end

function ConversationScreen:compose(target)
	self.draft, self.ask = target, nil
	if target.agent then
		self.agent = target.agent
	end
	return self:transition("compose")
end

function ConversationScreen:finish_compose()
	self.draft = nil
	return self:transition("finish")
end

function ConversationScreen:focus()
	if self.state == "entry" and self.entry then
		return self.entry.id
	end
	return self.agent
end

function ConversationScreen:shows_entry(kind, id)
	return self.state == "entry" and self.entry ~= nil and self.entry.kind == kind and self.entry.id == id
end

function ConversationScreen:show_entry(kind, id)
	if self:shows_entry(kind, id) or not self:transition("show_entry") then
		return false
	end
	self.entry = { kind = kind, id = id }
	return true
end

function ConversationScreen:show_ask(id, agent)
	self.ask = id
	self.agent = agent or self.agent
	self.turn, self.history = nil, nil
	return self:transition("ask")
end

function ConversationScreen:settle_ask(resume_draft)
	self.ask = nil
	if resume_draft and self.draft then
		return self:transition("compose")
	end
	return self:transition("settle")
end

function ConversationScreen:request_search(at)
	self.search = at
end

function ConversationScreen:take_search()
	local requested = self.search ~= nil
	self.search = nil
	return requested
end

function ConversationScreen:request_pick(pick, at)
	pick.at = at
	self.pick = pick
end

function ConversationScreen:take_pick()
	local pick = self.pick
	self.pick = nil
	return pick
end

function ConversationScreen:follows_latest()
	return self.turn == nil
end

function ConversationScreen.is_behind(shown_turn, latest)
	return shown_turn ~= nil and latest ~= nil and shown_turn < latest
end

function ConversationScreen:keeps_place()
	return self.state == "draft" or self.state == "ask" or self.state == "entry" or self.history ~= nil
end

ConversationScreen.HOLD_SECONDS = 60
ConversationScreen.THROTTLE_SECONDS = 5
ConversationScreen.clock = os.time

local FLAGS = { "focused", "editing", "scrolled_up", "waiting" }
local VALUES = { "shown_agent", "shown_turn", "owner_pid" }

local function alive(pid)
	return pid ~= nil and vim.uv.kill(pid, 0) == 0
end

function ConversationScreen:observe(facts)
	local was_editing = self.editing == true
	local changed = false
	for _, k in ipairs(FLAGS) do
		local v = facts[k] == true
		if self[k] ~= v then
			self[k] = v
			changed = true
		end
	end
	for _, k in ipairs(VALUES) do
		if self[k] ~= facts[k] then
			self[k] = facts[k]
			changed = true
		end
	end
	if was_editing and not self.editing then
		self.released = true
		changed = true
	end
	return changed
end

function ConversationScreen:moved(at, at_bottom)
	local until_at = at + ConversationScreen.HOLD_SECONDS
	local capped = self.attended_until ~= nil and self.attended_until - at > ConversationScreen.HOLD_SECONDS
	local extend = self.attended_until == nil or capped or until_at - self.attended_until >= ConversationScreen.THROTTLE_SECONDS
	local release = self.waiting == true and at_bottom == true and self.released ~= true
	if extend then
		self.attended_until = until_at
	end
	if release then
		self.released = true
	end
	return extend or release
end

function ConversationScreen:release()
	self.released = true
end

function ConversationScreen:vacate(exiting)
	if self.owner_pid ~= vim.fn.getpid() then
		return false
	end
	self.focused, self.editing, self.waiting = false, false, false
	self.attended_until = nil
	self.state, self.draft, self.ask, self.history, self.entry = "answer", nil, nil, nil, nil
	if exiting then
		self.owner_pid = nil
	end
	return true
end

function ConversationScreen:pane_alive()
	return alive(self.owner_pid)
end

function ConversationScreen:settle()
	if self.released ~= true then
		return false
	end
	self.released = false
	return true
end

function ConversationScreen:is_attended(now)
	if self.released == true or not self:pane_alive() then
		return false
	end
	if self.focused == true or self.editing == true then
		return true
	end
	local until_at = self.attended_until
	return until_at ~= nil and now < until_at and until_at - now <= ConversationScreen.HOLD_SECONDS
end

local function holds(view, agent_id, latest, now)
	if not view:pane_alive() then
		return false
	end
	if view:keeps_place() then
		return true
	end
	if view.released == true then
		return false
	end
	local other = view.agent ~= agent_id
	local shown = view.shown_agent == view.agent and view.shown_turn or nil
	if not other and not ConversationScreen.is_behind(shown, latest) then
		return false
	end
	return view:is_attended(now) or view.scrolled_up == true
end

function ConversationScreen:holds_view(agent_id, latest)
	return holds(self, agent_id, latest, ConversationScreen.clock())
end

function ConversationScreen:follow_item(agent, item, incoming)
	if incoming and self:holds_view(agent.id, item and item.turn) then
		return false
	end
	if item and item.draft then
		if self.state == "draft" or self.state == "ask" then
			return false
		end
		return self:compose({ agent = agent.id, cwd = agent.cwd, name = agent.name, quiet = true })
	elseif item and item.ask then
		return self.ask ~= item.ask and self:show_ask(item.ask, agent.id)
	elseif item and item.answered then
		return not self:selects(agent.id, nil, item.answered) and self:preview_history(agent.id, item.answered)
	end
	local turn = item and item.turn
	if incoming then
		turn = nil
	end
	if self:selects(agent.id, turn, nil) and self.state == "answer" then
		return false
	end
	if incoming then
		return self:show_turn(agent.id, turn)
	end
	return self:select(agent.id, turn)
end

return ConversationScreen

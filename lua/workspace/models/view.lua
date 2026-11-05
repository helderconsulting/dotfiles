local Model = require("workspace.model")

local View = Model.extend({
	kind = "views",
	fields = { "id", "state", "agent", "turn", "draft", "ask", "history", "reveal", "section", "sections", "docker", "search", "pick", "entry" },
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

function View:select(agent, turn)
	self.agent, self.turn, self.history, self.ask = agent, turn, nil, nil
	return self:transition("show")
end

function View:preview_history(agent, entry)
	self.agent, self.turn, self.history, self.ask = agent, nil, entry, nil
	return self:transition("show")
end

function View:selects(agent, turn, history)
	return self.agent == agent and self.turn == turn and (self.history and self.history.at) == (history and history.at)
end

function View:compose(target)
	self.draft, self.ask = target, nil
	if target.agent then
		self.agent = target.agent
	end
	return self:transition("compose")
end

function View:finish_compose()
	self.draft = nil
	return self:transition("finish")
end

function View:focus()
	if self.state == "entry" and self.entry then
		return self.entry.id
	end
	return self.agent
end

function View:shows_entry(kind, id)
	return self.state == "entry" and self.entry ~= nil and self.entry.kind == kind and self.entry.id == id
end

function View:show_entry(kind, id)
	if self:shows_entry(kind, id) or not self:transition("show_entry") then
		return false
	end
	self.entry = { kind = kind, id = id }
	return true
end

function View:show_ask(id, agent)
	self.ask = id
	self.agent = agent or self.agent
	self.turn, self.history = nil, nil
	return self:transition("ask")
end

function View:settle_ask(resume_draft)
	self.ask = nil
	if resume_draft and self.draft then
		return self:transition("compose")
	end
	return self:transition("settle")
end

function View:request_search(at)
	self.search = at
end

function View:take_search()
	local requested = self.search ~= nil
	self.search = nil
	return requested
end

function View:request_pick(pick, at)
	pick.at = at
	self.pick = pick
end

function View:take_pick()
	local pick = self.pick
	self.pick = nil
	return pick
end

function View:follows_latest()
	return self.turn == nil
end

function View:follow_item(agent, item)
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
	if self:selects(agent.id, turn, nil) and self.state == "answer" then
		return false
	end
	return self:select(agent.id, turn)
end

function View:reveal_comment(root, id, at)
	self.reveal = { root = root, id = id, at = at }
end

function View:report_sections(sections, current)
	self.sections, self.section = sections, current
end

function View:report_docker(summary)
	self.docker = summary
end

return View

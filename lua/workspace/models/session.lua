local Agent = require("workspace.models.agent")
local Draft = require("workspace.models.draft")
local format = require("workspace.format")

local Session = {}
Session.__index = Session

function Session.from_agent(agent, now)
	local word, kind = agent:status()
	local progress, tone = agent:progress(now or os.time())
	if progress then
		word, kind = word .. " · " .. progress, tone or kind
	end
	return setmetatable({
		id = agent.id,
		agent = agent,
		name = agent:display_name(),
		cwd = agent.root,
		running = true,
		word = word,
		kind = kind,
		unread = agent:unread(),
		order = 0,
	}, Session)
end

function Session.from_file(file, info, order, now)
	return setmetatable({
		id = file.id,
		path = file.path,
		name = info.title or file.id:sub(1, 8),
		cwd = info.cwd,
		mtime = file.mtime,
		running = false,
		word = format.age(file.mtime, now),
		kind = "off",
		order = order,
	}, Session)
end

function Session.for_draft(target)
	return setmetatable({
		id = Draft.key(target),
		name = "new session",
		cwd = target.cwd,
		running = false,
		drafting = true,
		word = "drafting · starts on send" .. (target.model and (" · " .. target.model) or ""),
		kind = "busy",
		order = -1,
	}, Session)
end

function Session.active(agents, folder, now, draft)
	local list = {}
	if Draft.starts_session(draft) and format.inside(folder, draft.cwd) then
		table.insert(list, Session.for_draft(draft))
	end
	for _, a in ipairs(Agent.running_in(agents, folder)) do
		table.insert(list, Session.from_agent(a, now))
	end
	return list
end

function Session.list(agents, files, infos, folder, now)
	local list, live = Session.active(agents, folder, now), {}
	for _, e in ipairs(list) do
		live[e.id] = true
	end
	for i, f in ipairs(files) do
		local info = infos[f.path]
		if info and info.cwd and not live[f.id] and format.inside(folder, info.cwd) then
			table.insert(list, Session.from_file(f, info, i, now))
		end
	end
	return list
end

function Session:place()
	return self.agent and self.agent.worktree or format.basename(self.cwd)
end

function Session:card(review, merge_request, now)
	local word = self.word
	if review and review.sent > 0 then
		word = word .. " · " .. review.sent .. " open"
	end
	if review and review.resolved > 0 then
		word = word .. " · " .. review.resolved .. " resolved"
	end
	local place = self:place()
	if self:on_cli() then
		place = place .. " · cli"
	end
	if self.running and self.agent and self.agent:uses_extra() then
		place = place .. " · extra usage"
	end
	local card = { self.name, place, word }
	for _, line in ipairs(merge_request and merge_request:card_lines(now or os.time()) or {}) do
		table.insert(card, line)
	end
	card[#card + 1] = self:meter()
	return card
end

function Session:can_move()
	if not (self.running and self.agent) then
		return false, self.name .. " isn't running"
	elseif self.agent.pane then
		return false, self.name .. " runs in a terminal pane, it stays on the cli"
	elseif self.agent:on_sdk() then
		return false, self.name .. " is already on the sdk"
	elseif self.agent:is_busy() then
		return false, self.name .. " is " .. self.agent.state .. ", move it once it's idle"
	end
	return true
end

function Session:on_cli()
	return self.running and self.agent ~= nil and self.agent:on_cli()
end

function Session:meter()
	if not (self.running and self.agent) then
		return nil
	end
	local fraction = self.agent:context_fraction()
	local parts = {}
	table.insert(parts, self.agent:plan_label())
	table.insert(parts, self.agent:model_label())
	table.insert(parts, self.agent:mode_label())
	if not fraction and #parts == 0 then
		return nil
	end
	return {
		fraction = fraction,
		percent = fraction and ("%d%%"):format(math.floor(fraction * 100 + 0.5)) or nil,
		label = table.concat(parts, " · "),
	}
end

function Session:search_columns()
	return self.running and self.word or "ended", self.name, self:place() .. (self.running and "" or (" · " .. self.word))
end

function Session:target()
	if self.drafting then
		return { cwd = self.cwd, name = format.basename(self.cwd) }
	end
	return { agent = self.id, cwd = self.cwd, name = self.name }
end

function Session:needs_resume()
	return not self.running and not self.drafting and self.cwd ~= nil
end

function Session:toggle()
	return self.running and "end" or "resume"
end

function Session:can_end()
	if self.drafting then
		return false, "the new session starts when you send its draft"
	elseif not self.running then
		return false, self.name .. " isn't running"
	end
	return true
end

function Session:can_interrupt(agent)
	agent = agent or self.agent
	if not (agent and agent:is_running() and agent:is_busy()) then
		return false, self.name .. " isn't working"
	end
	return true
end

function Session:can_continue(agent)
	agent = agent or self.agent
	if not (agent and agent:is_running()) then
		return false, self.name .. " isn't running"
	end
	return agent:can_continue()
end

function Session:removal(found)
	local path = self.path or found
	if not path or path == "" then
		return nil, "no session file for " .. self.name
	end
	return { path = path, sidecar = (path:gsub("%.jsonl$", "")), stop_first = self.running }
end

function Session:rename_entry(name)
	if not self.path then
		return nil, "no session file to rename"
	end
	if not name or name == "" or name == self.name then
		return nil
	end
	return { type = "custom-title", customTitle = name, sessionId = self.id }
end

return Session

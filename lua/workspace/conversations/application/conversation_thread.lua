local Thread = require("workspace.conversations.domain.thread")

local ConversationThread = {}
ConversationThread.__index = ConversationThread

local M = {}

function M.new(ports)
	return setmetatable({
		agents = ports.agents,
		transcripts = ports.transcripts,
		pid_alive = ports.pid_alive,
		clock = ports.clock or os.time,
	}, ConversationThread)
end

function ConversationThread:names()
	local names = {}
	for _, a in ipairs(self.agents.all()) do
		names[a.id] = a:display_name()
	end
	return function(id, fallback)
		return names[id] or fallback
	end
end

function ConversationThread:open_asks(agent, now)
	local out = {}
	for _, a in ipairs(agent and agent:pending_asks() or {}) do
		if not a:is_stale(now, self.pid_alive(a.pid)) then
			table.insert(out, a)
		end
	end
	return out
end

function ConversationThread:for_session(id, agent_id, root, log, draft)
	local agent = agent_id and self.agents.get(agent_id)
	local now = self.clock()
	return Thread.new({
		agent = agent or nil,
		id = id,
		root = root,
		now = now,
		log = log,
		asks = self:open_asks(agent, now),
		transcript = self.transcripts.get(agent_id),
		draft = draft,
		name_of = self:names(),
	})
end

function ConversationThread:last_prompt(agent_id)
	local transcript = self.transcripts.get(agent_id)
	local last = transcript and transcript:turn(transcript:count())
	return last and last.prompt or nil
end

return M

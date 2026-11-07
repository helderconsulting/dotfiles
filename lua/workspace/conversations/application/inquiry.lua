local mapper = require("workspace.conversations.application.mappers.inquiry_dto_mapper")
local Question = require("workspace.conversations.domain.question")
local Workspace = require("workspace.workbench.domain.workspace")

local Inquiry = {}
Inquiry.__index = Inquiry

local M = {}

function M.new(ports)
	return setmetatable({
		questions = ports.questions,
		workspaces = ports.workspaces,
		pid_alive = ports.pid_alive,
		clock = ports.clock or os.time,
	}, Inquiry)
end

function M.has_viewer(store, paths)
	for _, w in ipairs(store:all(Workspace)) do
		for _, path in pairs(paths) do
			if w:pane("conversation") and w:contains(path) then
				return true
			end
		end
	end
	return false
end

function Inquiry:open(id)
	local q = self.questions:get(id)
	return q and q:is_pending() and mapper.to_inquiry_dto(q) or nil
end

function Inquiry:describe(entry)
	return mapper.to_inquiry_dto(Question:new(entry))
end

function Inquiry:next_for(session_ids)
	local agents = {}
	for i, id in ipairs(session_ids) do
		agents[i] = { id = id }
	end
	local next = Question.next_pending(self.questions:all(), agents, self.clock(), self.pid_alive)
	return next and mapper.to_inquiry_dto(next) or nil
end

function Inquiry:claim(id)
	local claimed = self.questions:update(id, function(q)
		return q:is_unseen() and q:show(self.clock())
	end)
	return claimed and claimed:is_pending() and mapper.to_inquiry_dto(claimed) or nil
end

function Inquiry:can_surface(workspace_id, pane)
	return Workspace.keeps(workspace_id and self.workspaces.get(workspace_id), "conversation", pane)
end

function Inquiry:change(id, fn)
	self.questions:update(id, function(q)
		if not q:is_pending() then
			return false
		end
		return fn(q, self.clock())
	end)
end

function Inquiry:answer(command)
	self:change(command.id, function(q, now)
		q:answer(command.answers, now)
	end)
end

function Inquiry:decide(command)
	self:change(command.id, function(q, now)
		q:decide(command.decision, now)
	end)
end

function Inquiry:dismiss(command)
	self:change(command.id, function(q, now)
		q:dismiss(now)
	end)
end

return M

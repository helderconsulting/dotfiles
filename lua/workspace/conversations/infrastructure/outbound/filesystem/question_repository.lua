local Question = require("workspace.conversations.domain.question")

local Repository = {}
Repository.__index = Repository

local M = {}

function M.new(store)
	return setmetatable({ store = store }, Repository)
end

function Repository:get(id)
	return id and self.store:get(Question, id) or nil
end

function Repository:all()
	return self.store:all(Question)
end

function Repository:pending_by_session()
	local out = {}
	for _, q in ipairs(self:all()) do
		if q:is_pending() then
			out[q.session] = out[q.session] or {}
			table.insert(out[q.session], q)
		end
	end
	return out
end

function Repository:save(question)
	return self.store:put(Question, question)
end

function Repository:update(id, fn)
	return self.store:update(Question, id, fn)
end

function Repository:remove(id)
	self.store:remove(Question, id)
end

return M

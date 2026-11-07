local mapper = require("workspace.legio.application.mappers.miles_dto_mapper")
local Question = require("workspace.conversations.domain.question")

local MilesQuestions = {}
MilesQuestions.__index = MilesQuestions

local M = {}

function M.new(ports)
	return setmetatable({
		questions = ports.questions,
		milites = ports.milites,
		viewers = ports.viewers,
		log = ports.log or function() end,
		clock = ports.clock or os.time,
	}, MilesQuestions)
end

function MilesQuestions:handles(payload, background)
	return Question.handles(payload, background)
end

function MilesQuestions:timing()
	return mapper.to_question_timing_dto(Question.show_within, Question.timeout)
end

function MilesQuestions:has_viewer(session, cwd)
	local miles = self.milites:find(session)
	return self.viewers.shows_any({ cwd, miles and miles.root, miles and miles.cwd })
end

function MilesQuestions:dismiss_open(session, now)
	for _, q in ipairs(self.questions:all()) do
		if q.session == session and q:is_pending() then
			self.questions:update(q.id, function(ask)
				return ask:is_pending() and ask:dismiss(now)
			end)
		end
	end
end

function MilesQuestions:dismiss_superseded(session, event)
	if Question.superseded_by(event) then
		self:dismiss_open(session, self.clock())
	end
end

function MilesQuestions:ask(command)
	local now = self.clock()
	local id = ("%d-%s"):format(math.floor(now), tostring(command.request))
	self.questions:save(Question.from_sdk(command, id, now))
	self.milites:update(command.session, function(a)
		a:apply("ask", self.clock())
	end)
	return id
end

function MilesQuestions:open(command)
	local now = self.clock()
	local id = ("%d-%d"):format(math.floor(now), command.pid)
	self.questions:save(Question.from_session_event(command.payload, id, command.pid, now))
	return id
end

function MilesQuestions:state(id)
	local q = self.questions:get(id)
	return q and mapper.to_question_state_dto(q) or nil
end

function MilesQuestions:withdraw(command)
	self.questions:update(command.question_id, function(q)
		local open = command.only_unseen and q:is_unseen() or (not command.only_unseen and q:is_pending())
		return open and q:dismiss(self.clock())
	end)
end

function MilesQuestions:expire(question_id)
	local q = self.questions:get(question_id)
	if q and q:is_pending() then
		self.questions:update(q.id, function(a)
			a:expire(self.clock())
		end)
	end
end

function MilesQuestions:record_answer(q)
	self.milites:update(q.session, function(a)
		a:apply("answer", self.clock())
	end)
	self.log({ type = "ask", session = q.session, root = q.cwd, kind = q.kind, tool = q.tool, input = q.input, decision = q.decision, answers = q.answers, text = q:summary(), answer = q:answer_text() })
end

function MilesQuestions:finish(q)
	if q.state == "answered" then
		self:record_answer(q)
	end
	self.questions:remove(q.id)
end

function MilesQuestions:close(question_id)
	local q = self.questions:get(question_id)
	self.questions:remove(question_id)
	if not q then
		return nil
	end
	if q.state == "answered" then
		self:record_answer(q)
	end
	return mapper.to_question_state_dto(q)
end

function MilesQuestions:reply(question_id)
	local q = self.questions:get(question_id)
	if not q or q:is_pending() then
		return nil
	end
	self:finish(q)
	return mapper.to_question_reply_dto(q)
end

return M

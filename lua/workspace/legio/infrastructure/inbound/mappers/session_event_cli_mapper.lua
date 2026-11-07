local OpenQuestionCommand = require("workspace.legio.application.commands.open_question_command")
local SessionEventCommand = require("workspace.legio.application.commands.session_event_command")
local WithdrawQuestionCommand = require("workspace.legio.application.commands.withdraw_question_command")

local M = {}

function M.to_session_event_command(payload, pane, background, ask)
	return SessionEventCommand.new({ payload = payload, pane = pane, background = background, ask = ask })
end

function M.to_open_question_command(payload, pid)
	return OpenQuestionCommand.new({ payload = payload, pid = pid })
end

function M.to_dismiss_unseen_command(id)
	return WithdrawQuestionCommand.new({ question_id = id, only_unseen = true })
end

function M.to_answer(question)
	return question and question.answered and question.output or nil
end

return M

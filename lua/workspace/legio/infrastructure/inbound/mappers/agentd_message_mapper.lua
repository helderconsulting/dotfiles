local AskQuestionCommand = require("workspace.legio.application.commands.ask_question_command")
local ProcessReportCommand = require("workspace.legio.application.commands.process_report_command")
local SessionEventCommand = require("workspace.legio.application.commands.session_event_command")
local SessionsRunningCommand = require("workspace.legio.application.commands.sessions_running_command")
local WithdrawQuestionCommand = require("workspace.legio.application.commands.withdraw_question_command")

local M = {}

M.host = "agentd"

local function provider()
	return require("workspace.shared.providers").current()
end

local function to_command(event)
	return SessionEventCommand.new({ payload = event, background = true, host = M.host })
end

function M.to_session_event_command(payload)
	return to_command(provider().session_event(payload))
end

function M.to_session_started_command(msg)
	return to_command(provider().started_event(msg.id, msg.cwd))
end

function M.to_process_report_command(report)
	local fields = {}
	for _, f in ipairs(ProcessReportCommand.fields) do
		fields[f] = report[f]
	end
	return ProcessReportCommand.new(fields)
end

function M.to_ask_question_command(msg)
	return AskQuestionCommand.new({ session = msg.session, request = msg.request, tool = msg.tool, input = msg.input, suggestions = msg.suggestions, cwd = msg.cwd })
end

function M.to_withdraw_question_command(id)
	return WithdrawQuestionCommand.new({ question_id = id })
end

function M.to_sessions_running_command(msg)
	return SessionsRunningCommand.new({ sessions = msg.sessions, saved = msg.saved })
end

return M

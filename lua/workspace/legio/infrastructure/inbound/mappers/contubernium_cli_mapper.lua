local SendContuberniumMessageCommand = require("workspace.legio.application.commands.send_contubernium_message_command")

local M = {}

local function where(member)
	if not member.started then
		return "not started"
	end
	return (member.branch or "?") .. (member.worktree and (" in " .. member.worktree) or "")
end

function M.to_member_line(member, from)
	local you = member.miles_id == from and " (you)" or ""
	return ("%s%s\t%s\t%s\n"):format(member.name, you, member.started and member.state or "gone", where(member))
end

function M.to_send_command(from, args)
	return SendContuberniumMessageCommand.new({ from = from, to = args[2], text = args[3] })
end

function M.to_sent_line(sent)
	return ("sent to %s\n"):format(table.concat(sent.recipients, ", "))
end

return M

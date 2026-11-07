local MarkReadyCommand = require("workspace.workflow.application.commands.mark_ready_command")
local ResolveCommentCommand = require("workspace.workflow.application.commands.resolve_comment_command")

local M = {}

function M.to_resolve_command(root, args, session)
	return ResolveCommentCommand.new({ root = root, id = args[2], reply = args[3] or "", session = session })
end

function M.to_mark_ready_command(root, args, session)
	return MarkReadyCommand.new({ root = root, note = args[2] or "", session = session })
end

function M.to_list_line(comment)
	return ("%s\t%s\t%s\n"):format(comment.id, comment.location, comment.summary)
end

return M

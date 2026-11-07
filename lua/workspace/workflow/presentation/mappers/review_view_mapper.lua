local CommentViewModel = require("workspace.workflow.presentation.view_models.comment_view_model")
local RecipientViewModel = require("workspace.workflow.presentation.view_models.recipient_view_model")

local M = {}

local looks = {
	draft = { sign = "ReviewNoteSign", line = "ReviewNoteLine" },
	sent = { sign = "ReviewSentSign", line = "ReviewNoteLine", status = "sent · waiting for the agent" },
	resolved = { sign = "ReviewResolvedSign", status = "resolved" },
}

local function map(list, fn)
	local out = {}
	for i, item in ipairs(list or {}) do
		out[i] = fn(item)
	end
	return out
end

function M.to_comment_view_model(dto)
	local look = looks[dto.state] or looks.draft
	return CommentViewModel.new({
		id = dto.id,
		root = dto.root,
		key = dto.key,
		path = dto.path,
		rev = dto.rev,
		line1 = dto.line1,
		line2 = dto.line2,
		text = dto.text,
		images = dto.images,
		reply = dto.state == "resolved" and dto.reply or nil,
		state = dto.state,
		is_draft = dto.is_draft,
		location = dto.location,
		summary = dto.summary,
		sign_highlight = look.sign,
		line_highlight = look.line,
		status = look.status,
		list_label = ("%-8s  %s  %s"):format(dto.state == "draft" and "review" or dto.state, dto.location, dto.summary),
	})
end

function M.to_comment_view_models(dtos)
	return map(dtos, M.to_comment_view_model)
end

function M.to_counts_by_path(dtos)
	local out = {}
	for _, dto in ipairs(dtos) do
		out[dto.path] = dto
	end
	return out
end

function M.to_recipient_view_model(dto)
	return RecipientViewModel.new({ id = dto.id, name = dto.name, tag = dto.status, value = dto.name, description = dto.worktree or dto.branch or "" })
end

function M.to_recipient_view_models(dtos)
	return map(dtos, M.to_recipient_view_model)
end

function M.to_save_comment_command(root, place, line1, line2, text, images, existing)
	return {
		root = root,
		id = existing and existing.id,
		key = place.key,
		path = place.path,
		rev = place.rev,
		line1 = line1,
		line2 = line2,
		text = text,
		images = images,
	}
end

function M.to_delete_comment_command(comment)
	return { root = comment.root, id = comment.id }
end

function M.to_send_comments_command(root, comments, agent_id, quote, lines)
	return {
		root = root,
		ids = map(comments, function(c)
			return c.id
		end),
		agent_id = agent_id,
		quote = quote,
		lines = lines,
	}
end

function M.to_approve_command(root, recipient)
	return { root = root, agent_id = recipient.id }
end

return M

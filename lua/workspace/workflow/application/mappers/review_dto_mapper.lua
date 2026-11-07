local CommentDto = require("workspace.workflow.application.dto.comment_dto")
local FileCommentCountsDto = require("workspace.workflow.application.dto.file_comment_counts_dto")
local PromptPartDto = require("workspace.workflow.application.dto.prompt_part_dto")
local RemoteChangesDto = require("workspace.workflow.application.dto.remote_changes_dto")
local ReviewRecipientDto = require("workspace.workflow.application.dto.review_recipient_dto")
local ReviewSummaryDto = require("workspace.workflow.application.dto.review_summary_dto")

local M = {}

local function copy(list)
	local out = {}
	for i, v in ipairs(list or {}) do
		out[i] = v
	end
	return out
end

local function map(list, fn, ...)
	local out = {}
	for i, item in ipairs(list or {}) do
		out[i] = fn(item, ...)
	end
	return out
end

function M.to_comment_dto(comment, root)
	local remote = comment.remote
	return CommentDto.new({
		id = comment.id,
		root = root,
		state = comment.state,
		key = comment.key,
		path = comment.path,
		rev = comment.rev,
		line1 = comment.line1,
		line2 = comment.line2,
		text = comment.text,
		images = copy(comment.images),
		reply = comment.reply,
		remote = remote and { thread = remote.thread, iid = remote.iid, notes = remote.notes, author = remote.author } or nil,
		location = comment:location(),
		summary = comment:one_line(),
		is_draft = comment:is_draft(),
		is_open = comment:is_open(),
	})
end

function M.to_comment_dtos(comments, root)
	return map(comments, M.to_comment_dto, root)
end

function M.to_summary_dto(review, root)
	local n = review and review:counts() or {}
	return ReviewSummaryDto.new({
		root = root,
		state = review and review.state or "open",
		ready = review ~= nil and review.state == "ready",
		approved = review ~= nil and review.state == "approved",
		note = review and review.ready and review.ready.note or nil,
		draft = n.draft or 0,
		sent = n.sent or 0,
		resolved = n.resolved or 0,
	})
end

function M.to_file_counts_dtos(review)
	local out = {}
	for path, n in pairs(review and review:by_path() or {}) do
		table.insert(out, FileCommentCountsDto.new({ path = path, draft = n.draft, sent = n.sent, resolved = n.resolved }))
	end
	return out
end

function M.to_recipient_dto(agent)
	return ReviewRecipientDto.new({
		id = agent.id,
		name = agent:display_name(),
		status = (agent:status()),
		worktree = agent.worktree,
		branch = agent.branch,
		busy = agent:is_busy(),
	})
end

function M.to_recipient_dtos(agents)
	return map(agents, M.to_recipient_dto)
end

function M.to_remote_changes_dto(changes, root)
	return RemoteChangesDto.new({
		added = M.to_comment_dtos(changes.added, root),
		reopened = M.to_comment_dtos(changes.reopened, root),
		closed = M.to_comment_dtos(changes.closed, root),
	})
end

function M.to_prompt_part_dtos(parts)
	return map(parts, function(p)
		return PromptPartDto.new({ heading = p.heading, label = p.label, quote = copy(p.quote), text = p.text })
	end)
end

return M

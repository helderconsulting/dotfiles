local Review = require("workspace.workflow.domain.review")

local M = {}

local function comment_to_domain(record)
	return Review.Comment:new({
		id = record.id,
		state = record.state,
		key = record.key,
		path = record.path,
		rev = record.rev,
		line1 = record.line1,
		line2 = record.line2,
		text = record.text,
		images = record.images,
		reply = record.reply,
		created = record.created,
		sent_at = record.sent_at,
		resolved_at = record.resolved_at,
		sent_to = record.sent_to,
		remote = record.remote,
	})
end

local function comment_to_record(c)
	return {
		id = c.id,
		state = c.state,
		key = c.key,
		path = c.path,
		rev = c.rev,
		line1 = c.line1,
		line2 = c.line2,
		text = c.text,
		images = c.images,
		reply = c.reply,
		created = c.created,
		sent_at = c.sent_at,
		resolved_at = c.resolved_at,
		sent_to = c.sent_to,
		remote = c.remote,
	}
end

function M.to_domain(record)
	local comments = {}
	for i, c in ipairs(record.comments or {}) do
		comments[i] = comment_to_domain(c)
	end
	return Review:new({
		id = record.id,
		state = record.state,
		root = record.root,
		comments = comments,
		ready = record.ready,
		approved = record.approved,
		dismissed = record.dismissed,
	})
end

function M.to_record(review)
	local comments = {}
	for i, c in ipairs(review.comments) do
		comments[i] = comment_to_record(c)
	end
	return {
		id = review.id,
		state = review.state,
		root = review.root,
		comments = comments,
		ready = review.ready,
		approved = review.approved,
		dismissed = review.dismissed,
	}
end

return M

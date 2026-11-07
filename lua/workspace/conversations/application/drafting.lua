local mapper = require("workspace.conversations.application.mappers.inquiry_dto_mapper")
local Draft = require("workspace.conversations.domain.draft")

local Drafting = {}
Drafting.__index = Drafting

local M = {}

function M.new(ports)
	return setmetatable({ drafts = ports.drafts }, Drafting)
end

function Drafting:key(target)
	return Draft.key(target)
end

function Drafting:starts_session(target)
	return Draft.starts_session(target)
end

function Drafting:file(target)
	return self.drafts:file(target)
end

function Drafting:load(target)
	local draft = self.drafts:load(target)
	return draft and mapper.to_draft_dto(draft) or nil
end

function Drafting:write(command)
	self.drafts:write(command.target, command.text)
end

function Drafting:discard(target)
	self.drafts:discard(target)
end

function Drafting:capture_image()
	return self.drafts:capture_clipboard_image()
end

function Drafting:attach_image(command)
	local draft = self.drafts:load(command.target) or Draft.new(command.target)
	local tag = draft:attach(command.path)
	self.drafts:write_images(command.target, draft.images)
	return tag
end

function Drafting:outgoing(command)
	local draft = self.drafts:load(command.target)
	if (not draft or draft:is_empty()) and not command.review then
		return nil
	end
	return mapper.to_draft_dto((draft or Draft.new(command.target)):with_review(command.review))
end

return M

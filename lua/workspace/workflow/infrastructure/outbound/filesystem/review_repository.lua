local mapper = require("workspace.workflow.infrastructure.outbound.filesystem.review_record_mapper")
local Review = require("workspace.workflow.domain.review")

local KIND = "reviews"

local Repository = {}
Repository.__index = Repository

local M = {}

function M.new(store)
	return setmetatable({ store = store }, Repository)
end

function Repository:get(root)
	local record = root and self.store:get_record(KIND, Review.key(root))
	return record and mapper.to_domain(record) or nil
end

function Repository:get_or_new(root)
	return self:get(root) or Review.for_root(root)
end

function Repository:all()
	local list = {}
	for _, id in ipairs(self.store:record_ids(KIND)) do
		local record = self.store:get_record(KIND, id)
		if record then
			table.insert(list, mapper.to_domain(record))
		end
	end
	return list
end

function Repository:update(root, fn)
	local review
	self.store:update_record(KIND, Review.key(root), function(record)
		review = record and mapper.to_domain(record) or Review.for_root(root)
		review.root = root
		local keep = fn(review, record == nil)
		local transitions = review:take_transitions()
		if keep == false then
			return false, transitions
		end
		return mapper.to_record(review), transitions
	end)
	return review
end

return M

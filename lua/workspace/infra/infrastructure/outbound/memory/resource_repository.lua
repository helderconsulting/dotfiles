local Resource = require("workspace.infra.domain.resource")

local Repository = {}
Repository.__index = Repository

local M = {}

function M.new()
	return setmetatable({ resources = {} }, Repository)
end

function Repository:get(key)
	return self.resources[key]
end

function Repository:get_or_new(key)
	local resource = self.resources[key]
	if not resource then
		resource = Resource:new({ id = key })
		self.resources[key] = resource
	end
	return resource
end

return M

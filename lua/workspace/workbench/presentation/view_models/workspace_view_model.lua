local WorkspaceViewModel = {}
WorkspaceViewModel.__index = WorkspaceViewModel

local M = {}

function M.new(fields)
	return setmetatable({
		id = fields.id,
		tab = fields.tab,
		window = fields.window,
		root = fields.root,
		mode = fields.mode,
		panes = fields.panes or {},
		opened = fields.opened,
	}, WorkspaceViewModel)
end

function WorkspaceViewModel:pane(role)
	return self.panes[role]
end

function WorkspaceViewModel:set_pane(role, id)
	self.panes[role] = id
end

function WorkspaceViewModel:forget_pane(role)
	self.panes[role] = nil
end

function WorkspaceViewModel:role_of(id)
	for role, pane in pairs(self.panes) do
		if pane == id then
			return role
		end
	end
end

return M

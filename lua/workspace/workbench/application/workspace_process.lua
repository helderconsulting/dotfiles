local unpack = table.unpack or unpack
local mapper = require("workspace.workbench.application.mappers.workspace_dto_mapper")
local Workspace = require("workspace.workbench.domain.workspace")

local WorkspaceProcess = {}
WorkspaceProcess.__index = WorkspaceProcess

local M = {}

function M.new(ports)
	return setmetatable({
		workspaces = ports.workspaces,
		provider = ports.provider,
		clock = ports.clock or os.time,
	}, WorkspaceProcess)
end

function WorkspaceProcess:list()
	return mapper.to_workspace_dtos(self.workspaces:all())
end

function WorkspaceProcess:find(id)
	local workspace = id and self.workspaces:get(id)
	return workspace and mapper.to_workspace_dto(workspace) or nil
end

function WorkspaceProcess:find_by_tab(tab)
	for _, workspace in ipairs(self.workspaces:all()) do
		if workspace.tab == tab then
			return mapper.to_workspace_dto(workspace)
		end
	end
end

function WorkspaceProcess:find_by_root(root)
	for _, workspace in ipairs(self.workspaces:all()) do
		if workspace.root == root then
			return mapper.to_workspace_dto(workspace)
		end
	end
end

function WorkspaceProcess:save(command)
	self.workspaces:save(Workspace:new({
		id = command.id,
		tab = command.tab,
		window = command.window,
		root = command.root,
		mode = command.mode,
		panes = command.panes,
		opened = command.opened,
	}))
end

function WorkspaceProcess:remove(id)
	self.workspaces:remove(id)
end

function WorkspaceProcess:keeps(id, role, pane)
	return Workspace.keeps(id and self.workspaces:get(id) or nil, role, pane)
end

function WorkspaceProcess:wants(mode, role)
	return Workspace:new({ id = "wants", mode = mode }):wants(role)
end

function WorkspaceProcess:missing_roles(mode, panes, alive, keep_closed)
	return Workspace:new({ id = "missing", mode = mode, panes = panes }):missing(alive, keep_closed)
end

function WorkspaceProcess:widths(mode, total)
	return mapper.to_pane_widths_dto(Workspace:new({ id = "widths", mode = mode }):widths(total))
end

function WorkspaceProcess:limits()
	return mapper.to_layout_limits_dto(Workspace.sizes)
end

function WorkspaceProcess:view_roles()
	return { unpack(Workspace.view_roles) }
end

function WorkspaceProcess:fit(want, room, keep, least)
	return Workspace.fit(want, room, keep, least)
end

function WorkspaceProcess:docker_rows(editor_rows, tab_rows)
	return Workspace.docker_rows(editor_rows, tab_rows)
end

function WorkspaceProcess:panel_width(cols)
	return Workspace.panel_width(cols)
end

function WorkspaceProcess:diff_layout(cols)
	return Workspace.diff_layout(cols)
end

function WorkspaceProcess:background_command(root, resume, quote)
	return self.provider.current().background_command(root, resume, quote)
end

function WorkspaceProcess:sessions_script()
	return self.provider.current().sessions_script
end

function WorkspaceProcess:resume_session(mode)
	local launch = Workspace.launch(mode)
	return launch and launch.resume or nil
end

return M

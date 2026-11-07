local WorkspaceViewModel = require("workspace.workbench.presentation.view_models.workspace_view_model")
local SaveWorkspaceCommand = require("workspace.workbench.application.commands.save_workspace_command")

local M = {}

function M.to_workspace_view_model(dto)
	local panes = {}
	for role, id in pairs(dto.panes or {}) do
		panes[role] = id
	end
	return WorkspaceViewModel.new({ id = dto.id, tab = dto.tab, window = dto.window, root = dto.root, mode = dto.mode, panes = panes, opened = dto.opened })
end

function M.to_workspace_view_models(dtos)
	local out = {}
	for i, dto in ipairs(dtos) do
		out[i] = M.to_workspace_view_model(dto)
	end
	return out
end

function M.to_save_command(view_model)
	return SaveWorkspaceCommand.new({
		id = view_model.id,
		tab = view_model.tab,
		window = view_model.window,
		root = view_model.root,
		mode = view_model.mode,
		panes = view_model.panes,
		opened = view_model.opened,
	})
end

return M

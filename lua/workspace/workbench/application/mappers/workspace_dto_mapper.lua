local WorkspaceDto = require("workspace.workbench.application.dto.workspace_dto")
local PaneWidthsDto = require("workspace.workbench.application.dto.pane_widths_dto")
local LayoutLimitsDto = require("workspace.workbench.application.dto.layout_limits_dto")

local M = {}

local function copy(map)
	local out = {}
	for k, v in pairs(map or {}) do
		out[k] = v
	end
	return out
end

function M.to_workspace_dto(workspace)
	return WorkspaceDto.new({
		id = workspace.id,
		tab = workspace.tab,
		window = workspace.window,
		root = workspace.root,
		mode = workspace.mode,
		panes = copy(workspace.panes),
		opened = workspace.opened,
	})
end

function M.to_workspace_dtos(workspaces)
	local out = {}
	for i, workspace in ipairs(workspaces) do
		out[i] = M.to_workspace_dto(workspace)
	end
	return out
end

function M.to_pane_widths_dto(widths)
	return PaneWidthsDto.new({ sidebar = widths.sidebar, conversation = widths.conversation, editor = widths.editor })
end

function M.to_layout_limits_dto(sizes)
	return LayoutLimitsDto.new({
		editor_min = sizes.editor.min,
		sidebar_min = sizes.sidebar.min,
		conversation_min = sizes.conversation.min,
	})
end

return M

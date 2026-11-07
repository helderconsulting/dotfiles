local Workspace = require("workspace.workbench.domain.workspace")

local M = {}

function M.to_domain(record)
	return Workspace:new({
		id = record.id,
		tab = record.tab,
		window = record.window,
		root = record.root,
		mode = record.mode,
		panes = record.panes,
		opened = record.opened,
	})
end

function M.to_record(workspace)
	return {
		id = workspace.id,
		tab = workspace.tab,
		window = workspace.window,
		root = workspace.root,
		mode = workspace.mode,
		panes = workspace.panes,
		opened = workspace.opened,
	}
end

return M

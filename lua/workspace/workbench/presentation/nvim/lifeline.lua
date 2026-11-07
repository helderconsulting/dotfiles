local app = require("workspace.workbench.presentation.nvim.app")

local M = {}

M.grace = 30000
M.every = 30000
M.misses_allowed = 1

local misses = 0

function M.check()
	local workspaces = app.services().workspace_process
	if workspaces:keeps(app.workspace, app.role, app.pane) then
		misses = 0
		return
	end
	misses = misses + 1
	if misses <= M.misses_allowed then
		return
	end
	app.state().log.warn("view.orphaned", { role = app.role, pane = app.pane, workspace = app.workspace, known = (workspaces:find(app.workspace) or {}).panes })
	vim.cmd("qa!")
end

if app.workspace and app.pane and vim.tbl_contains(app.services().workspace_process:view_roles(), app.role) then
	vim.uv.new_timer():start(M.grace, M.every, vim.schedule_wrap(M.check))
end

return M

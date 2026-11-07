local runtime = require("workspace.workbench.infrastructure.inbound.nvim_runtime")
local format = require("workspace.shared.lib.format")

local M = {}

M.role = vim.env.WORKSPACE_ROLE or "editor"
M.workspace = vim.env.WORKSPACE_ID
M.pane = tonumber(vim.env.WEZTERM_PANE or "")
M.paths = runtime.paths
M.projects = vim.g.projects_dir or (vim.env.HOME .. "/Code")

function M.state()
	return runtime.state()
end

function M.store()
	return runtime.store()
end

function M.services()
	return runtime.services(M.now)
end

function M.read_log(limit)
	return runtime.read_log(limit)
end

function M.on(topic, fn)
	return runtime.on(topic, fn)
end

function M.now()
	return os.time()
end

function M.short(path)
	return format.short(path, M.projects, vim.env.HOME)
end

function M.age(at)
	return format.age(at, os.time())
end

local function user_var(name, value)
	if M.pane then
		vim.api.nvim_ui_send(("\27]1337;SetUserVar=%s=%s\7"):format(name, vim.base64.encode(value)))
	end
end

function M.request(cmd, args)
	if not M.pane then
		return vim.notify("not running in wezterm", vim.log.levels.WARN)
	end
	user_var("workspace", vim.json.encode({ cmd = cmd, args = args or {}, nonce = vim.uv.hrtime() }))
end

function M.hand_off(direction)
	user_var("nav", direction .. ":" .. vim.uv.hrtime())
end

function M.screen(cls)
	return runtime.screen(cls, M.workspace)
end

function M.update_screen(cls, fn)
	return runtime.update_screen(cls, M.workspace, fn)
end

function M.workspace_dto()
	return M.services().workspace_process:find(M.workspace)
end

function M.folder()
	local w = M.workspace_dto()
	return w and w.root or vim.env.PWD or vim.fn.getcwd()
end

function M.main_window()
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_config(win).relative == "" then
			vim.api.nvim_set_current_win(win)
			return win
		end
	end
end

function M.focus(role)
	local w = M.workspace_dto()
	local pane = w and w.panes[role]
	if pane then
		M.request("pane", { pane = pane })
	end
end

return M

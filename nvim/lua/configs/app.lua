local nvim = require("workspace.nvim")
local models = require("workspace.models")
local format = require("workspace.format")

local M = {}

M.role = vim.env.WORKSPACE_ROLE or "editor"
M.workspace = vim.env.WORKSPACE_ID
M.pane = tonumber(vim.env.WEZTERM_PANE or "")
M.models = models
M.paths = nvim.paths
M.projects = vim.g.projects_dir or (vim.env.HOME .. "/Code")

function M.live()
	return nvim.live()
end

function M.store()
	return nvim.live().store
end

function M.on(topic, fn)
	return nvim.live().bus.on(topic, fn)
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

function M.view()
	return M.workspace and M.store():get(models.View, M.workspace) or models.View:new({ id = "none" })
end

function M.update_view(fn)
	if not M.workspace then
		return
	end
	return M.store():update(models.View, M.workspace, function(v)
		return fn(v)
	end)
end

function M.agents()
	return require("workspace.agents").all(M.store())
end

function M.agent(id)
	return require("workspace.agents").get(M.store(), id)
end

function M.workspace_model()
	return M.workspace and M.store():get(models.Workspace, M.workspace)
end

function M.folder()
	local w = M.workspace_model()
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
	local w = M.workspace_model()
	local pane = w and w:pane(role)
	if pane then
		M.request("pane", { pane = pane })
	end
end

return M

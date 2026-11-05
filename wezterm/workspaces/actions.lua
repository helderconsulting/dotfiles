local wezterm = require("wezterm")
local data = require("workspaces.store")
local layout = require("workspaces.layout")

local Workspace = data.models.Workspace

local M = {}

local cli = wezterm.executable_dir .. "/wezterm"
local shell = os.getenv("SHELL") or "zsh"

function M.find_by_tab(tab_id)
	for _, w in ipairs(data.workspaces()) do
		if w.tab == tab_id then
			return w
		end
	end
end

function M.find_tab(tab_id)
	for _, mw in ipairs(wezterm.mux.all_windows()) do
		for _, tab in ipairs(mw:tabs()) do
			if tab:tab_id() == tab_id then
				return mw, tab
			end
		end
	end
end

function M.switch(mw, tab)
	tab:activate()
	local gui = mw:gui_window()
	if gui then
		gui:focus()
	end
end

local function start_agent(root, mode)
	local launch = Workspace.launch(mode)
	if not launch then
		return
	end
	data.log.info("agent.resume", { root = root, session = launch.resume })
	local command = "cd " .. wezterm.shell_quote_arg(root) .. " && env -u WEZTERM_PANE claude " .. (launch.resume and ("--resume " .. launch.resume .. " ") or "") .. "--bg"
	wezterm.background_child_process({ shell, "-lc", command })
end

local function new_id()
	return tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
end

function M.open(window, dir, mode)
	dir = dir:gsub("/$", "")
	data.log.info("open", { dir = dir, mode = mode })
	start_agent(dir, mode)
	for _, w in ipairs(data.workspaces()) do
		if w.root == dir then
			local mw, tab = M.find_tab(w.tab)
			if tab then
				return M.switch(mw, tab)
			end
			data.remove_workspace(w.id)
		end
	end
	local current = window:active_tab()
	local lone_shell = #current:panes() == 1 and not M.find_by_tab(current:tab_id()) and current:panes()[1]
	local w = Workspace:new({ id = new_id(), root = dir, mode = mode == "nvim" and "nvim" or "full", opened = os.time() })
	local tab = layout.create(window:mux_window(), w)
	tab:activate()
	data.save_workspace(w)
	data.log.info("opened", { id = w.id, tab = w.tab, panes = w.panes })
	if lone_shell then
		local proc = (lone_shell:get_foreground_process_name() or ""):match("([^/]+)$") or ""
		if proc:match("sh$") then
			wezterm.background_child_process({ cli, "cli", "kill-pane", "--pane-id", tostring(lone_shell:pane_id()) })
		end
	end
end

local function view_panes(w)
	local list = {}
	for _, role in ipairs(Workspace.view_roles) do
		local pane = w:pane(role) and data.pane(w:pane(role))
		if pane then
			table.insert(list, { role = role, pane = pane })
		end
	end
	return list
end

local function command(pane, cmd)
	pane:send_text("\x1c\x0e:" .. cmd .. "\r")
end

local function quit(pane)
	command(pane, "silent! wa | qa!")
end

function M.close(_, tab)
	local w = M.find_by_tab(tab:tab_id())
	data.log.info("close", { tab = tab:tab_id(), workspace = w and w.id })
	if not w then
		return
	end
	data.remove_workspace(w.id)
	data.store:remove(data.models.View, w.id)
	for _, v in ipairs(view_panes(w)) do
		quit(v.pane)
	end
	local editor = w:pane("editor") and data.pane(w:pane("editor"))
	if editor then
		editor:activate()
		command(editor, "confirm qa")
	end
end

function M.reload(_, tab)
	local w = M.find_by_tab(tab:tab_id())
	data.log.info("reload", { tab = tab:tab_id(), workspace = w and w.id })
	if not w then
		return
	end
	local views = view_panes(w)
	for _, v in ipairs(views) do
		quit(v.pane)
	end
	local editor = w:pane("editor") and data.pane(w:pane("editor"))
	if editor then
		command(editor, "restart")
	end
	local tries = 0
	local function rebuild()
		local alive = {}
		for _, v in ipairs(views) do
			if data.pane(v.pane:pane_id()) then
				table.insert(alive, v)
			end
		end
		if #alive > 0 and tries < 30 then
			tries = tries + 1
			return wezterm.time.call_after(0.1, rebuild)
		end
		for _, v in ipairs(alive) do
			data.log.warn("reload.kill", { role = v.role, pane = v.pane:pane_id() })
			wezterm.run_child_process({ cli, "cli", "kill-pane", "--pane-id", tostring(v.pane:pane_id()) })
		end
		for _, v in ipairs(views) do
			w.panes[v.role] = nil
		end
		layout.ensure(tab, w)
		data.save_workspace(w)
		layout.apply(tab, w)
	end
	rebuild()
end

function M.relayout(window)
	local tab = window:active_tab()
	local w = M.find_by_tab(tab:tab_id())
	if w then
		layout.apply(tab, w)
	end
end

return M

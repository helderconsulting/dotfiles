local wezterm = require("wezterm")
local data = require("workspaces.store")
local actions = require("workspaces.actions")
local theme = require("workspaces.theme")
local format = require("workspace.format")

local M = {}

local projects_root = wezterm.home_dir .. "/Code"

local function short(path)
	return format.short(path, projects_root, wezterm.home_dir)
end

local function list_projects()
	local ok, success, out = pcall(wezterm.run_child_process, { "/opt/homebrew/bin/fd", "-t", "d", "-d", "2", ".", projects_root })
	if not (ok and success) then
		ok, success, out = pcall(wezterm.run_child_process, { "/usr/bin/find", projects_root, "-mindepth", "1", "-maxdepth", "2", "-type", "d", "-not", "-path", "*/.*" })
	end
	local list = {}
	for line in ((ok and success and out) or ""):gmatch("[^\n]+") do
		table.insert(list, (line:gsub("/$", "")))
	end
	table.sort(list)
	return list
end

local function list_sessions()
	local ok, success, out = pcall(wezterm.run_child_process, { wezterm.config_dir .. "/bin/claude-sessions", "20" })
	local list = {}
	for line in ((ok and success and out) or ""):gmatch("[^\n]+") do
		local mtime, id, cwd, title = line:match("^(%d+)\t([^\t]+)\t([^\t]+)\t(.*)$")
		if id then
			table.insert(list, { id = id, cwd = cwd, title = title, age = format.age(tonumber(mtime)) })
		end
	end
	return list
end

local function label(parts)
	local items = {}
	for _, part in ipairs(parts) do
		table.insert(items, { Foreground = { Color = part[2] } })
		table.insert(items, { Text = part[1] })
	end
	return wezterm.format(items)
end

local function pick(window, pane, title, choices, on_pick)
	window:perform_action(wezterm.action.InputSelector({
		title = title,
		choices = choices,
		fuzzy = true,
		action = wezterm.action_callback(function(w, _, id)
			if id then
				on_pick(w, id)
			end
		end),
	}), pane)
end

local modes = {
	{ "workspace", "workspace", "sidebar, conversation, nvim and docker" },
	{ "nvim", "nvim", "just an editing session" },
}

local function pick_mode(window, pane, dir)
	local choices = {}
	for _, m in ipairs(modes) do
		table.insert(choices, { id = m[1], label = label({ { m[2], theme.schemes.green.fg }, { "  " .. m[3], theme.schemes.green.dim } }) })
	end
	pick(window, pane, short(dir), choices, function(w, mode)
		actions.open(w, dir, mode)
	end)
end

function M.show(window, pane)
	local choices, targets, running, here = {}, {}, {}, nil
	local agents = data.agents()
	for _, a in ipairs(agents) do
		if a:is_running() then
			running[a.id] = true
		end
	end
	local current = actions.find_by_tab(window:active_tab():tab_id())
	if not current then
		local url = pane:get_current_working_dir()
		here = url and url.file_path:gsub("/$", "") or wezterm.home_dir
		table.insert(choices, { id = "here", label = label({ { "here    ", theme.schemes.purple.fg }, { "start here", theme.schemes.purple.fg }, { "  " .. short(here), theme.schemes.purple.dim } }) })
	end
	for _, w in ipairs(data.workspaces()) do
		local mw, tab = actions.find_tab(w.tab)
		if tab and (not current or w.id ~= current.id) then
			local parts = { { "open    ", theme.schemes.green.dim }, { short(w.root), theme.schemes.green.fg } }
			for _, a in ipairs(data.models.Agent.running_in(agents, w.root)) do
				local word = a:status()
				table.insert(parts, { "  " .. a:display_name() .. " " .. word, theme.state(word).fg })
			end
			targets["tab:" .. w.id] = { mw = mw, tab = tab }
			table.insert(choices, { id = "tab:" .. w.id, label = label(parts) })
		end
	end
	local sessions = {}
	for _, s in ipairs(list_sessions()) do
		if not running[s.id] then
			sessions["session:" .. s.id] = s
			table.insert(choices, {
				id = "session:" .. s.id,
				label = label({ { "resume  ", theme.schemes.purple.dim }, { short(s.cwd), theme.schemes.purple.fg }, { "  " .. s.title, theme.schemes.green.fg }, { "  " .. s.age, theme.schemes.green.dim } }),
			})
		end
	end
	for _, dir in ipairs(list_projects()) do
		table.insert(choices, { id = "dir:" .. dir, label = label({ { "new     ", theme.schemes.idle.dim }, { short(dir), theme.schemes.idle.fg } }) })
	end
	pick(window, pane, "workspaces", choices, function(w, id)
		if id == "here" then
			pick_mode(w, pane, here)
		elseif sessions[id] then
			actions.open(w, sessions[id].cwd, id)
		elseif targets[id] then
			actions.switch(targets[id].mw, targets[id].tab)
		else
			pick_mode(w, pane, id:sub(5))
		end
	end)
end

return M

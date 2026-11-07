local wezterm = require("wezterm")
local data = require("workspace.workbench.presentation.wezterm.state")
local actions = require("workspace.workbench.presentation.wezterm.actions")
local bar = require("workspace.workbench.presentation.wezterm.pane_bar")
local picker = require("workspace.workbench.presentation.wezterm.picker")
local theme = require("workspace.workbench.presentation.wezterm.theme")

local M = {}

local function workspace_by_id(id)
	for _, w in ipairs(data.workspaces()) do
		if w.id == id then
			return w
		end
	end
end

local requests = {}

function requests.open(window, args)
	if args.dir and args.dir ~= "" then
		actions.open(window, args.dir, args.mode or "workspace")
	end
end

function requests.tab(_, args)
	local w = workspace_by_id(args.tab)
	local mw, tab = actions.find_tab(w and w.tab)
	if tab then
		actions.switch(mw, tab)
	end
end

function requests.close(_, args)
	local w = workspace_by_id(args.tab)
	local mw, tab = actions.find_tab(w and w.tab)
	if tab then
		actions.close(mw, tab)
	end
end

function requests.layout(window)
	actions.relayout(window)
end

function requests.reload(window)
	actions.reload(window, window:active_tab())
end

function requests.pane(_, args)
	local pane = data.pane(tonumber(args.pane) or -1)
	local mw, tab = actions.find_tab(pane and pane:tab():tab_id())
	if tab then
		actions.switch(mw, tab)
		pane:activate()
	end
end

local function prune()
	local live = {}
	for _, w in ipairs(data.workspaces()) do
		if actions.live_tab(w) then
			live[w.id] = true
		else
			data.log.info("prune.workspace", { id = w.id, tab = w.tab })
			data.remove_workspace(w.id)
		end
	end
	for id in pairs(data.screen_workspaces()) do
		if not live[id] then
			data.remove_screens(id)
		end
	end
end

function M.apply(config)
	config.keys = config.keys or {}
	table.insert(config.keys, { mods = "CTRL|ALT", key = "w", action = wezterm.action_callback(picker.show) })
	table.insert(config.keys, {
		mods = "CTRL|ALT",
		key = "r",
		action = wezterm.action_callback(function(window)
			actions.reload(window, window:active_tab())
		end),
	})
	table.insert(config.keys, {
		mods = "CTRL|ALT",
		key = "q",
		action = wezterm.action_callback(function(window)
			actions.close(window:mux_window(), window:active_tab())
		end),
	})

	config.use_fancy_tab_bar = true
	config.show_tabs_in_tab_bar = false
	config.show_new_tab_button_in_tab_bar = false
	config.window_frame = {
		font = config.font,
		font_size = bar.font_size,
		active_titlebar_bg = theme.palette.bar,
		inactive_titlebar_bg = theme.palette.bar,
	}
	config.colors = config.colors or {}
	config.colors.tab_bar = { background = theme.palette.bar }
	config.colors.split = theme.palette.divider
	config.status_update_interval = 500

	local resize_generation, last_layout = {}, {}
	wezterm.on("window-resized", function(window)
		local id = window:window_id()
		resize_generation[id] = (resize_generation[id] or 0) + 1
		local generation = resize_generation[id]
		local now = wezterm.time.now and tonumber(wezterm.time.now():format("%s%.3f")) or os.clock()
		if not last_layout[id] or now - last_layout[id] > 0.1 then
			last_layout[id] = now
			actions.relayout(window)
		end
		wezterm.time.call_after(0.15, function()
			if generation == resize_generation[id] then
				actions.relayout(window)
				bar.refresh(window)
			end
		end)
	end)

	local seen = {}
	wezterm.on("update-status", function(window)
		local layout = {}
		for _, p in ipairs(window:active_tab():panes_with_info()) do
			table.insert(layout, p.left .. ":" .. p.width .. ":" .. p.top)
		end
		local key = (data.snapshot().version or "") .. "|" .. window:active_tab():tab_id() .. "|" .. table.concat(layout, ",")
		local id = window:window_id()
		if seen[id] ~= key then
			if seen[id] == nil then
				prune()
			end
			seen[id] = key
			bar.refresh(window)
		end
	end)

	wezterm.on("user-var-changed", function(window, pane, name, value)
		if name == "workspace" then
			local ok, request = pcall(wezterm.serde.json_decode, value)
			local handler = ok and type(request) == "table" and requests[request.cmd]
			data.log.info("request", { pane = pane:pane_id(), request = ok and request or value, handled = handler ~= nil })
			if handler then
				local done, err = pcall(handler, window, request.args or {})
				if not done then
					data.log.error("request.failed", { cmd = request.cmd, error = tostring(err) })
				end
			end
		elseif name == "nav" then
			local direction = value:match("^(%a+)")
			if direction then
				require("navigate").go(pane, direction)
			end
		else
			bar.refresh(window)
		end
	end)

	local pending, handled_nav = {}, {}
	wezterm.on("format-window-title", function(tab, pane)
		local id = tab.window_id
		local title = tab.window_title or ""
		local direction = title:match("^nav (%a+) ")
		if direction and handled_nav[id] ~= title then
			handled_nav[id] = title
			wezterm.time.call_after(0, function()
				local window = wezterm.gui.gui_window_for_mux_window(id)
				if window then
					require("navigate").step(window, direction)
				end
			end)
		end
		if not pending[id] then
			pending[id] = true
			wezterm.time.call_after(0, function()
				pending[id] = nil
				local window = wezterm.gui.gui_window_for_mux_window(id)
				if window then
					bar.refresh(window)
				end
			end)
		end
		return pane.title .. "  [w" .. id .. "]"
	end)
end

return M

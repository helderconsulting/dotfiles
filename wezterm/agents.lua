-- Agent bar: lists every pane running a coding agent with its state and work title.
-- Agents report state through user vars set by bin/agent-status (see Claude Code hooks).
local wezterm = require("wezterm")

local M = {}

-- Green to match the terminal, with purple for focus and orange for "needs you".
local palette = {
	bar = "#000000",
	tab = "#0E130E",
	divider = "#223022",
	focus = "#18131F",
	dim = "#3F6F3F",
	fg = "#55BB55",
	bright = "#77DD77",
	purple = "#A58BD3",
	orange = "#E0955A",
	ink = "#0A0A0A",
}

-- Panes whose "done" state has been looked at, keyed by pane id.
local seen = {}

-- Foreground process per pane id. Looked up again only when the pane title changes (an agent
-- exiting hands the title back to the shell), since the bar redraws on every spinner frame.
local procs = {}

local function foreground_process(pane)
	local id, title = pane:pane_id(), pane:get_title():gsub("^[^%w]+", "")
	local cached = procs[id]
	if not cached or cached.title ~= title then
		cached = { name = pane:get_foreground_process_name() or "", title = title }
		procs[id] = cached
	end
	return cached.name
end

local function agent_info(pane)
	local vars = pane:get_user_vars()
	local agent, state = vars.agent, vars.agent_state
	if not agent or agent == "" or not state or state == "" then
		return nil
	end
	-- Ignore stale vars left behind when the agent exited without a SessionEnd hook.
	if not foreground_process(pane):find(agent, 1, true) then
		return nil
	end
	-- Claude Code prefixes the pane title with a spinner while busy and ✳ when idle.
	-- No hook fires when a turn is cancelled, so let the title correct a stale "working".
	local pane_title = pane:get_title()
	if state == "working" and pane_title:find("^✳") then
		state = "idle"
	end
	local title = vars.agent_title
	if not title or title == "" then
		title = pane_title:gsub("^[^%w]+", "")
	end
	return { agent = agent, state = state, title = title }
end

local badges = {
	working = { label = "working", fg = palette.purple },
	waiting = { label = "waiting", fg = palette.ink, bg = palette.orange },
	done = { label = "done", fg = palette.bright },
	idle = { label = "idle", fg = palette.dim },
}

local function badge(state, pane_id, is_active)
	if state == "done" then
		if is_active then
			seen[pane_id] = true
		end
		if seen[pane_id] then
			state = "idle"
		end
	end
	return badges[state] or badges.idle
end

-- One agent as a flat tab: accent edge, state label, title. The focused one gets a purple edge.
local function push_entry(items, b, title, focused)
	local bg = focused and palette.focus or palette.tab
	local function seg(fg, seg_bg, text)
		table.insert(items, { Foreground = { Color = fg } })
		table.insert(items, { Background = { Color = seg_bg } })
		table.insert(items, { Text = text })
	end
	seg(focused and palette.purple or palette.divider, bg, "▎ ")
	table.insert(items, { Attribute = { Intensity = "Bold" } })
	seg(b.fg, b.bg or bg, " " .. wezterm.pad_right(b.label, 7) .. " ")
	table.insert(items, "ResetAttributes")
	seg(focused and palette.bright or palette.fg, bg, "  " .. wezterm.pad_right(wezterm.truncate_right(title, 32), 32) .. "  ")
end

-- Agent panes across all tabs of the window, in bar order.
local function agent_panes(window)
	local list = {}
	local active_tab = window:active_tab()
	for _, tab in ipairs(window:mux_window():tabs()) do
		for _, p in ipairs(tab:panes_with_info()) do
			local info = agent_info(p.pane)
			if info then
				info.pane = p.pane
				info.focused = p.is_active and tab:tab_id() == active_tab:tab_id()
				table.insert(list, info)
			end
		end
	end
	return list
end

local function bar_items(window)
	local items = {}
	for _, a in ipairs(agent_panes(window)) do
		push_entry(items, badge(a.state, a.pane:pane_id(), a.focused), a.title, a.focused)
	end
	return items
end

local function refresh(window)
	local items = bar_items(window)
	window:set_left_status(wezterm.format(items))

	-- Only show the bar while there are agents, keeping the window chrome-free otherwise.
	local show = #items > 0
	local overrides = window:get_config_overrides() or {}
	if (overrides.enable_tab_bar == true) ~= show then
		overrides.enable_tab_bar = show
		overrides.hide_tab_bar_if_only_one_tab = false
		window:set_config_overrides(overrides)
	end
end

function M.apply(config)
	-- The bar isn't clickable, so jump by keyboard: CTRL|ALT 1-9 picks the Nth agent in the bar.
	config.keys = config.keys or {}
	for i = 1, 9 do
		table.insert(config.keys, {
			mods = "CTRL|ALT",
			key = tostring(i),
			action = wezterm.action_callback(function(win)
				local a = agent_panes(win)[i]
				if a then
					a.pane:activate()
				end
			end),
		})
	end
	-- CTRL|ALT Enter splits right like CTRL|ALT h and starts an agent there. It runs inside the
	-- pane's shell, so the pane survives the agent exiting.
	table.insert(config.keys, {
		mods = "CTRL|ALT",
		key = "Enter",
		action = wezterm.action_callback(function(_, pane)
			pane:split({ direction = "Right" }):send_text("claude\r")
		end),
	})

	-- Tabs and the new-tab button are hidden; the bar only holds agents.
	config.use_fancy_tab_bar = true
	config.show_tabs_in_tab_bar = false
	config.show_new_tab_button_in_tab_bar = false
	config.window_frame = {
		font = wezterm.font("JetBrains Mono"),
		font_size = 15,
		active_titlebar_bg = palette.bar,
		inactive_titlebar_bg = palette.bar,
	}
	config.colors = config.colors or {}
	config.colors.tab_bar = { background = palette.bar }

	wezterm.on("user-var-changed", function(window, pane, name)
		if name == "agent_state" then
			seen[pane:pane_id()] = nil
		end
		refresh(window)
	end)

	-- WezTerm has no pane-focus event, but the window title follows the active pane, so this runs on
	-- every pane switch and title change. It runs synchronously while GuiWindow methods are async,
	-- so the redraw is deferred; pending collapses a burst of title updates into one redraw.
	local pending = {}
	wezterm.on("format-window-title", function(tab, pane)
		local id = tab.window_id
		if not pending[id] then
			pending[id] = true
			wezterm.time.call_after(0, function()
				pending[id] = nil
				local window = wezterm.gui.gui_window_for_mux_window(id)
				if window then
					refresh(window)
				end
			end)
		end
		return pane.title
	end)
end

return M

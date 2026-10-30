-- Agent bar: lists every pane running a coding agent with its state and work title, plus the
-- Neovim panes, numbered so CTRL|ALT 1-9 (AeroSpace, bin/agent-jump) can reach either.
-- Agents report state through files written by bin/agent-status (see Claude Code hooks).
local wezterm = require("wezterm")

local M = {}

-- Bar background and split lines.
local palette = {
	bar = "#000000",
	divider = "#223022",
}

-- An entry takes the color of its state or mode, text and background alike: fg for the label and
-- what matters, dim for the rest, bg behind it (focus when it is the focused pane).
local schemes = {
	green = { fg = "#77DD77", dim = "#3F7F3F", bg = "#0E180E", focus = "#162616" },
	idle = { fg = "#4F8F4F", dim = "#2E4E2E", bg = "#0B100B", focus = "#121B12" },
	purple = { fg = "#A58BD3", dim = "#6A5A88", bg = "#15111D", focus = "#201A2D" },
	orange = { fg = "#E0955A", dim = "#8E5F3A", bg = "#1C130B", focus = "#2A1C10" },
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

-- Neovim panes show what a statusline and tabline would: Neovim sends its mode, buffers,
-- diagnostics, LSP progress and cursor position as JSON in the nvim_status user var
-- (nvim/lua/configs/statusbar.lua).
local function editor_info(pane)
	if not foreground_process(pane):find("n?vim$") then
		return nil
	end
	local ok, status = pcall(wezterm.serde.json_decode, pane:get_user_vars().nvim_status or "")
	status = ok and type(status) == "table" and status or {}
	local parts, details = {}, {}
	for i, buf in ipairs(status.buffers or {}) do
		table.insert(parts, { text = (i > 1 and "  " or "") .. buf.name, dim = not buf.current })
		if buf.modified then
			table.insert(parts, { text = " ●", dim = not buf.current })
		end
	end
	local function detail(text)
		table.insert(details, { text = (#details > 0 and "  " or "") .. text })
	end
	if (status.errors or 0) > 0 then
		detail("e" .. status.errors)
	end
	if (status.warnings or 0) > 0 then
		detail("w" .. status.warnings)
	end
	if status.lsp and status.lsp ~= "" then
		detail(status.lsp)
	end
	if status.pos then
		detail(status.pos)
	end
	return {
		editor = true,
		mode = status.mode or "nvim",
		parts = parts,
		details = details,
		branch = "",
		worktree = "",
	}
end

local state_dir = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/agent-status"
local claude_spinner = { ["◐"] = true, ["◓"] = true, ["◑"] = true, ["◒"] = true }
-- Last state per pane id, to notice changes (a new state means a "done" is unseen again).
local states = {}

-- Agent state comes from the file bin/agent-status writes for the pane:
-- agent, state, root, branch, worktree, title (tab separated).
local function read_state(pane_id)
	local f = io.open(state_dir .. "/" .. pane_id)
	if not f then
		return nil
	end
	local line = f:read("*l") or ""
	f:close()
	local fields = {}
	for field in (line .. "\t"):gmatch("([^\t]*)\t") do
		table.insert(fields, field)
	end
	return fields
end

-- Shell panes show their vi mode and folder, or the command running in them. zsh reports
-- "mode<tab>folder<tab>command" in the shell_status user var (~/.zshrc).
local shells = { zsh = true, bash = true, fish = true }

local function shell_info(pane)
	local status = pane:get_user_vars().shell_status or ""
	local mode, cwd, cmd = status:match("^([^\t]*)\t([^\t]*)\t(.*)$")
	if not mode then
		return nil
	end
	local proc = (foreground_process(pane):match("([^/]+)$") or ""):gsub("^%-", "")
	local running = not shells[proc]
	return {
		mode = running and "running" or mode,
		parts = { { text = running and (cmd ~= "" and cmd or proc) or cwd } },
		branch = "",
		worktree = "",
	}
end

local function agent_info(pane)
	local id = pane:pane_id()
	local fields = read_state(id) or {}
	local agent, state = fields[1], fields[2]
	-- Claude Code prefixes the pane title with a spinner while busy and ✳ when idle. That covers a
	-- session whose hooks haven't written a state file yet, and a cancelled turn (no hook fires).
	local pane_title = pane:get_title()
	local glyph = pane_title:match("^(%S+) ")
	if not agent or agent == "" then
		if glyph == "✳" or claude_spinner[glyph] then
			agent, state = "claude", glyph == "✳" and "idle" or "working"
		else
			return nil
		end
	elseif state == "working" and glyph == "✳" then
		state = "idle"
	end
	-- Ignore a stale file left behind when the agent exited without a SessionEnd hook.
	if not foreground_process(pane):find(agent, 1, true) then
		return nil
	end
	if states[id] ~= state then
		states[id] = state
		seen[id] = nil
	end
	local title = fields[6]
	if not title or title == "" then
		title = pane_title:gsub("^[^%w]+", "")
	end
	return {
		agent = agent,
		state = state,
		title = title,
		parts = { { text = title } },
		root = fields[3] or "",
		branch = fields[4] or "",
		worktree = fields[5] or "",
	}
end

local badges = {
	working = { label = "working", scheme = schemes.purple },
	waiting = { label = "waiting", scheme = schemes.orange },
	done = { label = "done", scheme = schemes.green },
	idle = { label = "idle", scheme = schemes.idle },
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

-- One entry as a flat tab: accent edge, its number (CTRL|ALT number, bound in AeroSpace), label,
-- main text, optional details, then where it works (the linked worktree's name, or the branch).
-- Edge, text and background take the entry's scheme: the color of its state or mode. The focused
-- one gets a bright edge and a stronger background. Main text and details are lists of { text, dim }
-- parts: an agent's title, a shell's folder or command, or Neovim's buffers and its diagnostics,
-- LSP progress and cursor position. With a width the entry fills exactly that many cells: the main
-- text takes what is left, and the place and details are dropped before it gets too short.
local function push_entry(items, b, e, focused, width, number)
	local c = b.scheme
	local bg = focused and c.focus or c.bg
	local function seg(fg, seg_bg, text)
		table.insert(items, { Foreground = { Color = fg } })
		table.insert(items, { Background = { Color = seg_bg } })
		table.insert(items, { Text = text })
	end
	local function parts_width(parts)
		local w = 0
		for _, part in ipairs(parts) do
			w = w + wezterm.column_width(part.text)
		end
		return w
	end
	local edge, label = "▎ ", " " .. b.label .. " "
	local num = number and (number .. " ") or ""
	local place = wezterm.truncate_right(e.worktree ~= "" and e.worktree or e.branch or "", 16)
	local details = e.details or {}
	local function fixed()
		local w = wezterm.column_width(edge) + wezterm.column_width(num) + wezterm.column_width(label) + 1 + 2
		if #details > 0 then
			w = w + 2 + parts_width(details)
		end
		return place ~= "" and w + 5 + wezterm.column_width(place) or w
	end
	local main_width = math.min(parts_width(e.parts), e.editor and 80 or 28)
	if width then
		if place ~= "" and width - fixed() < 12 then
			place = ""
		end
		if #details > 0 and width - fixed() < 12 then
			details = {}
		end
		main_width = math.max(width - fixed(), 0)
	end

	seg(focused and c.fg or c.dim, bg, edge)
	seg(c.dim, bg, num)
	table.insert(items, { Attribute = { Intensity = "Bold" } })
	seg(c.fg, bg, label)
	table.insert(items, "ResetAttributes")
	seg(bg, bg, " ")
	local left = main_width
	for _, part in ipairs(e.parts) do
		if left <= 0 then
			break
		end
		local text = wezterm.truncate_right(part.text, left)
		left = left - wezterm.column_width(text)
		seg(part.dim and c.dim or c.fg, bg, text)
	end
	seg(bg, bg, string.rep(" ", left))
	if #details > 0 then
		seg(bg, bg, "  ")
		for _, part in ipairs(details) do
			seg(c.dim, bg, part.text)
		end
	end
	if place ~= "" then
		seg(bg, bg, "     ")
		seg(c.dim, bg, place)
	end
	seg(bg, bg, "  ")
end

local function filler(items, width)
	table.insert(items, { Background = { Color = palette.bar } })
	table.insert(items, { Text = string.rep(" ", width) })
end

-- Agent and Neovim panes across all tabs of the window, in bar order, with their geometry.
local function bar_entries(window)
	local list = {}
	local active_tab = window:active_tab()
	for _, tab in ipairs(window:mux_window():tabs()) do
		for _, p in ipairs(tab:panes_with_info()) do
			local info = agent_info(p.pane) or editor_info(p.pane) or shell_info(p.pane)
			if info then
				info.pane = p.pane
				info.active_tab = tab:tab_id() == active_tab:tab_id()
				info.focused = p.is_active and info.active_tab
				info.left, info.width = p.left, p.width
				table.insert(list, info)
			end
		end
	end
	return list
end

local mode_schemes = {
	insert = schemes.purple,
	visual = schemes.orange,
	["v-line"] = schemes.orange,
	["v-block"] = schemes.orange,
	select = schemes.orange,
	["s-line"] = schemes.orange,
	replace = schemes.orange,
}

local function mode_badge(mode)
	return { label = mode, scheme = mode_schemes[mode] or schemes.green }
end

-- Entries of the active tab sit above their panes and span the same columns. The bar's font is
-- sized so a bar cell is exactly a pane cell: panes round JetBrains Mono's 21.6 px advance (18pt,
-- 144 dpi) up to 22 px, so the bar uses 18 * 22 / 21.6. Each entry starts on the split line at
-- its left. Side-by-side panes are columns of the layout; panes stacked in one column share its
-- width, and a column without agents stays empty. Agents in other tabs follow at natural width.
local font_size = 18
local bar_font_size = font_size * 22 / 21.6

local function bar_items(window, entries)
	local items, order = {}, {}
	local function entry(e, width)
		local b = e.mode and mode_badge(e.mode) or badge(e.state, e.pane:pane_id(), e.focused)
		table.insert(order, e.pane:pane_id())
		push_entry(items, b, e, e.focused, width, #order <= 9 and #order or nil)
	end

	local columns, by_left = {}, {}
	for _, p in ipairs(window:active_tab():panes_with_info()) do
		local col = by_left[p.left]
		if not col then
			col = { left = p.left, width = 0, entries = {} }
			by_left[p.left] = col
			table.insert(columns, col)
		end
		col.width = math.max(col.width, p.width)
	end
	table.sort(columns, function(x, y)
		return x.left < y.left
	end)
	for _, e in ipairs(entries) do
		if e.active_tab then
			table.insert(by_left[e.left].entries, e)
		end
	end
	for i, col in ipairs(columns) do
		-- A split line takes the cell left of its pane; the entry to its right starts on it.
		local start = i == 1 and 0 or col.left - 1
		local stop = columns[i + 1] and columns[i + 1].left - 1 or col.left + col.width
		local width = stop - start
		if #col.entries == 0 then
			filler(items, width)
		end
		for j, e in ipairs(col.entries) do
			local share = math.floor(width / #col.entries)
			entry(e, j < #col.entries and share or width - share * (#col.entries - 1))
		end
	end

	for _, e in ipairs(entries) do
		if not e.active_tab then
			entry(e)
		end
	end
	return items, order
end

local last_focus
local last_order

-- The pane ids of the bar entries, in bar order, for agent-jump (CTRL|ALT number in AeroSpace).
local function record_order(order)
	local text = table.concat(order, "\n") .. "\n"
	if text ~= last_order then
		local f = io.open(state_dir .. "/bar", "w")
		if f then
			f:write(text)
			f:close()
			last_order = text
		end
	end
end

-- Record the worktree of the last focused agent; Neovim watches this file to point its diff view
-- at that worktree. Focusing a non-agent pane (Neovim itself) keeps the previous agent. An agent
-- only counts once it has stayed focused for a moment: coming back from AeroSpace first focuses the
-- pane last used in WezTerm and then the one on the side you came from, and passing through an
-- agent pane must not move Neovim to its project.
local pending_focus
local function record_focus(agents)
	local focus
	for _, a in ipairs(agents) do
		if a.focused and a.root and a.root ~= "" then
			focus = a.root .. "\t" .. a.pane:pane_id() .. "\t" .. a.branch
		end
	end
	pending_focus = focus
	if not focus or focus == last_focus then
		return
	end
	wezterm.time.call_after(0.3, function()
		if pending_focus ~= focus or focus == last_focus then
			return
		end
		local f = io.open(state_dir .. "/focus", "w")
		if f then
			f:write(focus, "\n")
			f:close()
			last_focus = focus
		end
	end)
end

local function refresh(window)
	local entries = bar_entries(window)
	record_focus(entries)
	local items, order = bar_items(window, entries)
	record_order(order)
	window:set_left_status(wezterm.format(items))

	-- Only show the bar while there is something in it.
	local show = #entries > 0
	local overrides = window:get_config_overrides() or {}
	if (overrides.enable_tab_bar == true) ~= show then
		overrides.enable_tab_bar = show
		overrides.hide_tab_bar_if_only_one_tab = false
		window:set_config_overrides(overrides)
	end
end

function M.apply(config)
	-- CTRL|ALT 1-9 jump to the numbered bar entries from anywhere; they are AeroSpace bindings
	-- running bin/agent-jump, so they also bring WezTerm forward.
	config.keys = config.keys or {}
	-- CTRL|ALT Enter splits right like CTRL|ALT h and starts an agent there, then a shell so the pane
	-- survives the agent exiting. Started as the shell's command rather than typed in, since zsh
	-- prompts start in vi normal mode.
	local shell = os.getenv("SHELL") or "zsh"
	table.insert(config.keys, {
		mods = "CTRL|ALT",
		key = "Enter",
		action = wezterm.action_callback(function(_, pane)
			pane:split({ direction = "Right", args = { shell, "-ic", "claude; exec " .. shell } })
		end),
	})

	-- Tabs and the new-tab button are hidden; the bar only holds agents and Neovim panes.
	config.use_fancy_tab_bar = true
	config.show_tabs_in_tab_bar = false
	config.show_new_tab_button_in_tab_bar = false
	config.window_frame = {
		-- Same font as the terminal; see bar_font_size for the size.
		font = config.font,
		font_size = bar_font_size,
		active_titlebar_bg = palette.bar,
		inactive_titlebar_bg = palette.bar,
	}
	config.colors = config.colors or {}
	config.colors.tab_bar = { background = palette.bar }
	-- Split lines continue the entry edges in the bar above them.
	config.colors.split = palette.divider

	-- Entries follow pane widths. Resizing the window has an event, dragging a split does not, so a
	-- cheap check twice a second compares the active tab's pane layout and only redraws on change.
	wezterm.on("window-resized", refresh)
	config.status_update_interval = 500
	local layouts = {}
	wezterm.on("update-status", function(window)
		local layout = {}
		for _, p in ipairs(window:active_tab():panes_with_info()) do
			table.insert(layout, p.left .. ":" .. p.width)
		end
		layout = table.concat(layout, ",")
		local id = window:window_id()
		if layouts[id] ~= layout then
			layouts[id] = layout
			refresh(window)
		end
	end)

	-- Neovim reports through user vars: its status (nvim/lua/configs/statusbar.lua), and nav when
	-- ALT arrows reach its edge ("Left:<n>", the counter makes repeats a change).
	wezterm.on("user-var-changed", function(window, pane, name, value)
		if name == "nav" then
			local direction = value:match("^(%a+)")
			if direction then
				require("navigate").go(pane, direction)
			end
			return
		end
		refresh(window)
	end)

	-- WezTerm has no pane-focus event, but the window title follows the active pane, so this runs on
	-- every pane switch and title change. It runs synchronously while GuiWindow methods are async,
	-- so the redraw is deferred; pending collapses a burst of title updates into one redraw.
	local pending = {}
	local handled_nav = {}
	wezterm.on("format-window-title", function(tab, pane)
		local id = tab.window_id
		-- bin/nav sets the window title to "nav <direction> <token>" to ask for an ALT arrow move.
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
					refresh(window)
				end
			end)
		end
		return pane.title
	end)
end

return M

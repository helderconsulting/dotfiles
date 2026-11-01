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
	-- Commands and messages: Neovim's command line, an agent receiving a message.
	red = { fg = "#E06C75", dim = "#8E4A4F", bg = "#1E1012", focus = "#2C1519" },
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

-- The sidebar on the left of a workspace (nvim/lua/configs/sidebar.lua) reports its sections in the
-- sidebar user var, which also marks it as no editor of the workspace. Its entry shows them as tabs
-- over the one panel, each with its count (push_tabs).
local function is_sidebar(pane)
	local var = pane:get_user_vars().sidebar
	return var ~= nil and var ~= "" and foreground_process(pane):find("n?vim$") ~= nil
end

local function sidebar_info(pane)
	if not is_sidebar(pane) then
		return nil
	end
	local ok, view = pcall(wezterm.serde.json_decode, pane:get_user_vars().sidebar)
	view = ok and type(view) == "table" and view or {}
	local tabs = {}
	for _, tab in ipairs(view.tabs or {}) do
		table.insert(tabs, {
			name = tab.name or "",
			info = tostring(tonumber(tab.count) or 0),
			scheme = schemes.green,
			current = tab.current == true,
		})
	end
	return {
		sidebar = true,
		badge = { label = "", scheme = schemes.green },
		tabs = tabs,
		split = true,
		parts = {},
		worktree = "",
		branch = "",
	}
end

-- The docker view under Neovim (CTRL|ALT w, nvim/lua/configs/docker.lua) reports its tabs and the
-- project its containers come from in the docker_view user var: one tab, its section with the
-- count, over the view's lists (its entries are cards in the pane). The tabs are push_tabs', each
-- with its word in its kind's color, like an agent's state: green ok, purple getting there, orange
-- needs a look, grey stopped or unused. The vpn devices section leads with this Mac's VPN state:
-- green connected, purple connecting, grey stopped, orange waiting on a login. A down engine is one
-- tab saying so.
-- Grey only here: the idle green reads too much like the running one next to it.
local grey = { fg = "#8C8C8C", dim = "#555555", bg = "#121212", focus = "#1C1C1C" }
local docker_schemes = { ok = schemes.green, busy = schemes.purple, bad = schemes.orange, off = grey }

local function docker_info(pane)
	local var = pane:get_user_vars().docker_view
	if not var or var == "" or not foreground_process(pane):find("n?vim$") then
		return nil
	end
	local ok, view = pcall(wezterm.serde.json_decode, var)
	view = ok and type(view) == "table" and view or {}
	local tabs = {}
	for _, tab in ipairs(view.tabs or {}) do
		table.insert(tabs, {
			name = tab.name or "",
			info = tab.word or "",
			scheme = docker_schemes[tab.kind] or grey,
			current = tab.current == true,
		})
	end
	if view.down then
		tabs = { { name = "docker engine", info = "down", scheme = schemes.orange, current = true } }
	elseif #tabs == 0 then
		tabs = { { name = "no " .. (view.section or "containers"), info = "", scheme = grey, current = true } }
	end
	local lead = type(view.badge) == "table"
		and { text = view.badge.word or "", scheme = docker_schemes[view.badge.kind] or grey }
	return {
		docker = true,
		-- The view's menu width plus its split line, so the entry sits right under the menu. Not
		-- width: bar_entries sets that to the pane's.
		menu_width = tonumber(view.width),
		badge = { label = "", scheme = grey },
		tabs = tabs,
		split = true,
		lead = lead or nil,
		parts = {},
		worktree = view.project or "",
		branch = "",
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
	-- A received message shows until the reply is done (bin/agent-message); a permission prompt
	-- during the reply still shows as waiting.
	if state ~= "waiting" then
		local marker = io.open(state_dir .. "/" .. id .. ".message")
		if marker then
			marker:close()
			state = "message"
		end
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
		session = fields[7] ~= "" and fields[7] or nil,
	}
end

local badges = {
	working = { label = "working", scheme = schemes.purple },
	waiting = { label = "waiting", scheme = schemes.orange },
	done = { label = "done", scheme = schemes.green },
	idle = { label = "idle", scheme = schemes.idle },
	message = { label = "message", scheme = schemes.red },
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
-- parts: an agent's title, a shell's folder or command, Neovim's buffers and its diagnostics, LSP
-- progress and cursor position, or the docker view's tabs. With a width the entry fills exactly
-- that many cells: the main text takes what is left, and the place and details are dropped before
-- it gets too short. Tabbed parts start late enough that the current tab stays in view.
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
	local main_width = math.min(parts_width(e.parts), (e.editor or e.docker) and 80 or 28)
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
	local parts = e.parts
	if e.current_tab then
		local start, used = 1, 0
		for _, part in ipairs(parts) do
			if part.tab <= e.current_tab then
				used = used + wezterm.column_width(part.text)
			end
		end
		while used > main_width and start < e.current_tab do
			for _, part in ipairs(parts) do
				-- The tab and the gap after it; its own gap went with the tab before.
				if (part.tab == start and not part.gap) or (part.tab == start + 1 and part.gap) then
					used = used - wezterm.column_width(part.text)
				end
			end
			start = start + 1
		end
		parts = {}
		for _, part in ipairs(e.parts) do
			if part.tab >= start and not (part.tab == start and part.gap) then
				table.insert(parts, part)
			end
		end
	end
	local left = main_width
	for _, part in ipairs(parts) do
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

local function push_tabs(items, e, focused, width, number)
	local function seg(fg, seg_bg, text)
		table.insert(items, { Foreground = { Color = fg } })
		table.insert(items, { Background = { Color = seg_bg } })
		table.insert(items, { Text = text })
	end
	local cw = wezterm.column_width
	local num = number and (number .. "  ") or ""
	local left = width or math.huge

	if e.lead then
		local c = e.lead.scheme
		local bg = focused and c.focus or c.bg
		local text = wezterm.truncate_right(num .. e.lead.text .. "  ", math.max(left - 2, 0))
		seg(focused and c.fg or c.dim, bg, "▎ ")
		table.insert(items, { Attribute = { Intensity = "Bold" } })
		seg(c.fg, bg, text)
		table.insert(items, "ResetAttributes")
		left, num = left - 2 - cw(text), ""
	end

	local tabs, current = e.tabs, 1
	for i, t in ipairs(tabs) do
		current = t.current and i or current
	end
	local function natural(i)
		local t = tabs[i]
		return 2 + cw(t.name) + (t.info ~= "" and cw(" " .. t.info) or 0) + 2
	end
	local first, last = 1, #tabs
	local widths = {}
	if e.split and width then
		local avail = left - cw(num)
		local share = math.floor(avail / #tabs)
		for i = 1, #tabs do
			widths[i] = i < #tabs and share or avail - share * (#tabs - 1)
		end
		widths[1] = widths[1] + cw(num)
	else
		for i = 1, #tabs do
			widths[i] = natural(i)
		end
		if width then
			local function used(from, to)
				local w = cw(num) + (from > 1 and 4 or 0) + (to < #tabs and 4 or 0)
				for i = from, to do
					w = w + widths[i]
				end
				return w
			end
			while first < current and used(first, current) > left do
				first = first + 1
			end
			last = current
			while last < #tabs and used(first, last + 1) <= left do
				last = last + 1
			end
		end
	end

	local c0 = tabs[1] and tabs[1].scheme or schemes.green
	local function marker(text)
		local t = wezterm.truncate_right(text, math.max(left, 0))
		seg(c0.dim, palette.bar, t)
		left = left - cw(t)
	end
	if first > 1 then
		marker(num .. "‹" .. (first - 1) .. "  ")
		num = ""
	end
	for i = first, last do
		if left <= 0 then
			break
		end
		local t = tabs[i]
		local c = t.scheme
		local bg = t.current and (focused and c.focus or c.bg) or palette.bar
		local w = math.min(widths[i] + (i == first and not e.split and cw(num) or 0), left)
		local edge = t.current and "▎ " or "  "
		local info = t.info ~= "" and (" " .. t.info) or ""
		local name_room = math.max(w - cw(edge) - cw(num) - cw(info) - 2, 0)
		local name = wezterm.truncate_right(t.name, name_room)
		local pad = math.max(w - cw(edge) - cw(num) - cw(name) - cw(info), 0)
		seg(focused and c.fg or c.dim, bg, edge)
		seg(c.dim, bg, num)
		if t.current then
			table.insert(items, { Attribute = { Intensity = "Bold" } })
		end
		seg(t.current and c.fg or c.dim, bg, name)
		table.insert(items, "ResetAttributes")
		seg(bg, bg, string.rep(" ", math.max(pad - 2, 0)))
		seg(t.current and c.fg or c.dim, bg, info)
		seg(bg, bg, string.rep(" ", math.min(pad, 2)))
		left = left - w
		num = ""
	end
	if last < #tabs and left > 0 then
		marker("  " .. (#tabs - last) .. "›  ")
	end
	if width and left > 0 then
		seg(palette.bar, palette.bar, string.rep(" ", left))
	end
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
			local info = sidebar_info(p.pane)
				or agent_info(p.pane)
				or docker_info(p.pane)
				or editor_info(p.pane)
				or shell_info(p.pane)
			-- Every workspace has its own sidebar; only the one on screen gets an entry.
			if info and not (info.sidebar and tab:tab_id() ~= active_tab:tab_id()) then
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
	command = schemes.red,
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
		local b = e.badge or e.mode and mode_badge(e.mode) or badge(e.state, e.pane:pane_id(), e.focused)
		table.insert(order, e.pane:pane_id())
		if e.tabs then
			push_tabs(items, e, e.focused, width, #order <= 9 and #order or nil)
		else
			push_entry(items, b, e, e.focused, width, #order <= 9 and #order or nil)
		end
	end
	-- Cells an entry takes at natural width (numbered, unfocused).
	local function natural_width(e)
		local scratch, w = {}, 0
		if e.tabs then
			push_tabs(scratch, e, false, nil, 1)
		else
			push_entry(scratch, e.badge, e, false, nil, 1)
		end
		for _, item in ipairs(scratch) do
			if type(item) == "table" and item.Text then
				w = w + wezterm.column_width(item.Text)
			end
		end
		return w
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
		-- A docker entry sharing its column (the docker view under Neovim) is as wide as the view's menu
		-- (or its natural width without one), up to half the column; the other entries share the rest
		-- and the last one takes what is left.
		local sizes, rest, flexible = {}, width, 0
		for j, e in ipairs(col.entries) do
			if e.docker and #col.entries > 1 then
				sizes[j] = math.min(e.menu_width or natural_width(e), math.floor(width / 2))
				rest = rest - sizes[j]
			else
				flexible = flexible + 1
			end
		end
		local share = flexible > 0 and math.floor(rest / flexible) or 0
		local used = 0
		for j, e in ipairs(col.entries) do
			local w = j < #col.entries and (sizes[j] or share) or width - used
			used = used + w
			entry(e, w)
		end
	end

	for _, e in ipairs(entries) do
		if not e.active_tab then
			entry(e)
		end
	end
	return items, order
end

local function cwd_of(p)
	local url = p:get_current_working_dir()
	return url and url.file_path:gsub("/$", "") or nil
end

-- What a tab holds: its agents (with their state), Neovim, the docker view, the sidebar, or a lone
-- idle shell.
local function tab_parts(tab)
	local t = { panes = tab:panes(), agents = {} }
	for _, p in ipairs(t.panes) do
		local a = agent_info(p)
		if a then
			table.insert(t.agents, { pane = p, info = a })
		elseif is_sidebar(p) then
			t.sidebar = p
		elseif docker_info(p) then
			t.containers = t.containers or p
		elseif editor_info(p) then
			t.editor = t.editor or p
		end
	end
	t.agent = t.agents[1] and t.agents[1].pane
	local only = #t.panes == 1 and t.panes[1]
	if only and not t.agent and not t.editor and not t.containers then
		local proc = (foreground_process(only):match("([^/]+)$") or ""):gsub("^%-", "")
		t.shell = shells[proc] and only or nil
	end
	t.root = (t.editor and cwd_of(t.editor)) or (t.agents[1] and t.agents[1].info.root ~= "" and t.agents[1].info.root)
		or cwd_of(t.panes[1])
		or ""
	return t
end

-- The workspaces (tabs with an agent or Neovim) in every window, as JSON for Neovim's workspaces
-- and sessions sections (nvim/lua/configs/workspaces.lua): their tab, folder, panes, and agents
-- with their state and session.
local last_workspaces
local function record_workspaces()
	local list = {}
	for _, mw in ipairs(wezterm.mux.all_windows()) do
		for _, tab in ipairs(mw:tabs()) do
			local t = tab_parts(tab)
			if t.agent or t.editor then
				local w = {
					window = mw:window_id(),
					tab = tab:tab_id(),
					root = t.root,
					editor = t.editor ~= nil,
					docker = t.containers ~= nil,
					panes = {},
					agents = {},
				}
				for _, p in ipairs(t.panes) do
					table.insert(w.panes, p:pane_id())
				end
				for _, a in ipairs(t.agents) do
					table.insert(w.agents, {
						pane = a.pane:pane_id(),
						agent = a.info.agent,
						state = a.info.state,
						title = a.info.title,
						session = a.info.session or "",
					})
				end
				table.insert(list, w)
			end
		end
	end
	local text = wezterm.serde.json_encode(list)
	if text ~= last_workspaces then
		local f = io.open(state_dir .. "/workspaces.tmp", "w")
		if f then
			f:write(text)
			f:close()
			os.rename(state_dir .. "/workspaces.tmp", state_dir .. "/workspaces")
			last_workspaces = text
		end
	end
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
local function write_focus(focus)
	local f = io.open(state_dir .. "/focus", "w")
	if f then
		f:write(focus, "\n")
		f:close()
		last_focus = focus
	end
end
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
		write_focus(focus)
	end)
end

local function refresh(window)
	local entries = bar_entries(window)
	record_focus(entries)
	local items, order = bar_items(window, entries)
	record_order(order)
	record_workspaces()
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
	-- A login shell, like WezTerm's own panes: WezTerm runs with the minimal app PATH, the login
	-- shell adds Homebrew's (nvim, claude's hooks need jq and wezterm). With cwd it starts there:
	-- pane:split ignores cwd when given args, the new pane starts in the split pane's folder.
	local shell = os.getenv("SHELL") or "zsh"
	local function run(program, cwd, keep)
		local cd = cwd and "cd " .. wezterm.shell_quote_arg(cwd) .. " && " or ""
		return { shell, "-lic", cd .. program .. (keep == false and "" or "; exec " .. shell .. " -l") }
	end
	table.insert(config.keys, {
		mods = "CTRL|ALT",
		key = "Enter",
		action = wezterm.action_callback(function(_, pane)
			pane:split({ direction = "Right", args = run("claude") })
		end),
	})

	-- Workspaces: a tab holding a project's agent and Neovim, with the docker view under Neovim.
	-- CTRL|ALT w starts one, from a project or an earlier Claude session, or goes back to one still
	-- running; CTRL|ALT q closes it and leaves a plain shell.
	local projects_root = wezterm.home_dir .. "/Code"
	local agents = { claude = "claude", resume = "claude --resume" }
	local function agent_command(mode)
		local session = mode:match("^session:(.+)$")
		return session and "claude --resume " .. session or agents[mode]
	end

	local function escape(s)
		return (s:gsub("%p", "%%%0"))
	end
	local function short(path)
		path = path:gsub("/$", "")
		path = path:gsub("^" .. escape(projects_root) .. "/", "")
		path = path:gsub("^" .. escape(wezterm.home_dir), "~")
		return path
	end
	-- Directories in ~/Code two levels deep, like Neovim's :Projects. fd skips gitignored folders
	-- (node_modules); full paths since WezTerm runs without Homebrew's PATH.
	local function list_projects()
		local ok, success, out = pcall(wezterm.run_child_process, { "/opt/homebrew/bin/fd", "-t", "d", "-d", "2", ".", projects_root })
		if not (ok and success) then
			ok, success, out = pcall(wezterm.run_child_process, {
				"/usr/bin/find", projects_root, "-mindepth", "1", "-maxdepth", "2", "-type", "d", "-not", "-path", "*/.*",
			})
		end
		local list = {}
		for line in ((ok and success and out) or ""):gmatch("[^\n]+") do
			table.insert(list, (line:gsub("/$", "")))
		end
		table.sort(list)
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
		window:perform_action(
			wezterm.action.InputSelector({
				title = title,
				choices = choices,
				fuzzy = true,
				action = wezterm.action_callback(function(w, p, id)
					if id then
						on_pick(w, p, id)
					end
				end),
			}),
			pane
		)
	end

	-- Opens a workspace for cwd: mode is "claude" (a new session), "resume" (Claude's session
	-- picker), "session:<id>" (that session) or "nvim" (Neovim alone, no agent or docker view). A lone shell tab becomes the
	-- workspace (split both ways, then the shell closes so the two end up side by side); with here
	-- set, the current tab is completed instead: an agent gets Neovim on its right, Neovim an agent on
	-- its left, a tab with both the docker view. A session from the current tab's folder counts as
	-- here and joins it, under the agents already there. Anything else gets a new tab. Neovim starts
	-- from cwd, so it belongs to the project and the agents attach to it (nvim/lua/packs/git.lua).
	local cli = wezterm.executable_dir .. "/wezterm"

	-- The sidebar (nvim/lua/configs/sidebar.lua) on the left of a workspace, about sidebar_px wide. It
	-- splits off the leftmost pane that runs the full height (the agent, or Neovim without the docker
	-- view under it), so it runs the full height too; not a top_level split, which leaves WezTerm's
	-- layout a column off. A tab without such a pane, or too narrow to share, goes without.
	local sidebar_px = 480
	local function ensure_sidebar(tab, cwd)
		local panes, rows = tab:panes_with_info(), 0
		for _, p in ipairs(panes) do
			if is_sidebar(p.pane) then
				return
			end
			rows = math.max(rows, p.top + p.height)
		end
		for _, p in ipairs(panes) do
			if p.left == 0 and p.top == 0 and p.height == rows then
				local dims = p.pane:get_dimensions()
				-- A cell's width in points: WezTerm's pixels are device pixels (dpi 144 is 2x).
				local cell = dims.pixel_width / dims.cols / (dims.dpi / 72)
				local cols = math.floor(sidebar_px / cell + 0.5)
				if cols < p.width - 20 then
					p.pane:split({ direction = "Left", size = cols, cwd = cwd, args = run("nvim +Sidebar", cwd, false) })
				end
				return
			end
		end
	end

	local function open(window, pane, cwd, mode, here)
		local t = tab_parts(window:active_tab())
		local agent = agent_command(mode)
		local session = mode:match("^session:") ~= nil
		here = here or (session and t.root == (cwd:gsub("/$", "")))
		local app, focus, containers = nil, nil, t.containers
		if t.shell then
			if agent then
				t.shell:split({ direction = "Left", size = 0.5, cwd = cwd, args = run(agent, cwd) })
			end
			app = t.shell:split({ direction = "Right", size = 0.5, cwd = cwd, args = run("nvim", cwd) })
			focus = app
			-- CloseCurrentPane closes the active pane, whatever pane it's given, and the split made
			-- Neovim active.
			t.shell:activate()
			window:perform_action(wezterm.action.CloseCurrentPane({ confirm = false }), t.shell)
		elseif here and session and t.agent then
			app = t.editor or t.agent:split({ direction = "Right", cwd = cwd, args = run("nvim", cwd) })
			focus = t.agents[#t.agents].pane:split({ direction = "Bottom", cwd = cwd, args = run(agent, cwd) })
		elseif here and t.agent and not t.editor then
			app = t.agent:split({ direction = "Right", cwd = cwd, args = run("nvim", cwd) })
			focus = app
		elseif here and t.editor and not t.agent and agent then
			-- A docker view spanning the tab under Neovim would end up under the agent too, so it closes
			-- and comes back under Neovim below. Not a top_level split: WezTerm sizes that pane a column
			-- wider than it is, and splitting it again fails with "No space for split".
			if containers then
				wezterm.run_child_process({ cli, "cli", "kill-pane", "--pane-id", tostring(containers:pane_id()) })
				containers = nil
			end
			app = t.editor
			focus = t.editor:split({ direction = "Left", size = 0.5, cwd = cwd, args = run(agent, cwd) })
		elseif here and t.agent and t.editor then
			app, focus = t.editor, pane
		else
			local tab, first = window:mux_window():spawn_tab({ cwd = cwd, args = run(agent or "nvim", cwd) })
			tab:activate()
			app = agent and first:split({ direction = "Right", cwd = cwd, args = run("nvim", cwd) }) or first
			focus, containers = app, nil
		end
		-- The right is the application side: the docker view (a Neovim running :Docker) goes under
		-- Neovim. No shell after it: closing the view (<leader>-) closes the pane.
		if mode ~= "nvim" and not containers then
			app:split({ direction = "Bottom", size = 0.35, cwd = cwd, args = run("nvim +Docker", cwd, false) })
		end
		ensure_sidebar(focus:tab(), cwd)
		focus:activate()
	end

	-- Bring a workspace's tab and window forward.
	local function switch(mw, tab)
		tab:activate()
		local gui = mw:gui_window()
		if gui then
			gui:focus()
		end
	end

	local modes = {
		claude = { "claude + nvim", "a new claude session" },
		resume = { "resume claude + nvim", "pick an earlier claude session" },
		nvim = { "nvim", "just an editing session" },
	}
	local function pick_mode(window, pane, cwd, here, list)
		local choices = {}
		for _, mode in ipairs(list) do
			table.insert(choices, { id = mode, label = label({ { modes[mode][1], schemes.green.fg }, { "  " .. modes[mode][2], schemes.green.dim } }) })
		end
		pick(window, pane, short(cwd), choices, function(w, p, mode)
			open(w, p, cwd, mode, here)
		end)
	end

	-- Recent Claude sessions (bin/claude-sessions): { id, cwd, title, age }.
	local function list_sessions()
		local ok, success, out = pcall(wezterm.run_child_process, { wezterm.config_dir .. "/bin/claude-sessions", "20" })
		local list, now = {}, os.time()
		for line in ((ok and success and out) or ""):gmatch("[^\n]+") do
			local mtime, id, cwd, title = line:match("^(%d+)\t([^\t]+)\t([^\t]+)\t(.*)$")
			if id then
				local age = now - tonumber(mtime)
				age = age < 3600 and math.max(1, age // 60) .. "m" or age < 86400 and age // 3600 .. "h" or age // 86400 .. "d"
				table.insert(list, { id = id, cwd = cwd, title = title, age = age })
			end
		end
		return list
	end

	-- CTRL|ALT w lists, in order: the current tab when there is something to start or complete there, the
	-- running workspaces in every window (with their agents' states) to go back to, recent Claude
	-- sessions to pick up again (in the current workspace when it has their folder, else in a new one
	-- with Neovim and the docker view), then the projects in
	-- ~/Code. A project then asks how to open it.
	table.insert(config.keys, {
		mods = "CTRL|ALT",
		key = "w",
		action = wezterm.action_callback(function(window, pane)
			local current = window:active_tab()
			local here_cwd = cwd_of(pane) or wezterm.home_dir
			local t = tab_parts(current)
			local choices, targets, running = {}, {}, {}
			for _, a in ipairs(t.agents) do
				running[a.info.session or ""] = true
			end
			local here
			if t.shell then
				here = { "start here", { "claude", "resume", "nvim" } }
			elseif t.agent and not t.editor then
				here = { "add nvim", { "claude" } }
			elseif t.editor and not t.agent then
				here = { "add claude", { "claude", "resume" } }
			elseif t.agent and t.editor and not t.containers then
				here = { "add the docker view", { "claude" } }
			end
			if here then
				table.insert(choices, {
					id = "here",
					label = label({ { "here    ", schemes.purple.fg }, { here[1], schemes.purple.fg }, { "  " .. short(here_cwd), schemes.purple.dim } }),
				})
			end

			for _, mw in ipairs(wezterm.mux.all_windows()) do
				for _, tab in ipairs(mw:tabs()) do
					local w = tab_parts(tab)
					if tab:tab_id() ~= current:tab_id() and (w.agent or w.editor) then
						local parts = { { "open    ", schemes.green.dim }, { short(w.root), schemes.green.fg } }
						for _, a in ipairs(w.agents) do
							local b = badges[a.info.state] or badges.idle
							table.insert(parts, { "  " .. a.info.agent .. " " .. b.label, b.scheme.fg })
						end
						if w.editor then
							table.insert(parts, { "  nvim", schemes.green.dim })
						end
						for _, a in ipairs(w.agents) do
							running[a.info.session or ""] = true
						end
						local id = "tab:" .. tab:tab_id()
						targets[id] = { window = mw, tab = tab }
						table.insert(choices, { id = id, label = label(parts) })
					end
				end
			end

			local sessions = {}
			for _, s in ipairs(list_sessions()) do
				if running[s.id] then
					goto continue
				end
				local id = "session:" .. s.id
				sessions[id] = s
				table.insert(choices, {
					id = id,
					label = label({
						{ "resume  ", schemes.purple.dim },
						{ short(s.cwd), schemes.purple.fg },
						{ "  " .. s.title, schemes.green.fg },
						{ "  " .. s.age, schemes.green.dim },
					}),
				})
				::continue::
			end

			for _, dir in ipairs(list_projects()) do
				table.insert(choices, { id = "dir:" .. dir, label = label({ { "new     ", schemes.idle.dim }, { short(dir), schemes.idle.fg } }) })
			end

			pick(window, pane, "workspaces", choices, function(w, p, id)
				if id == "here" then
					if #here[2] == 1 then
						open(w, p, here_cwd, here[2][1], true)
					else
						pick_mode(w, p, here_cwd, true, here[2])
					end
				elseif sessions[id] then
					open(w, p, sessions[id].cwd, id, false)
				elseif targets[id] then
					switch(targets[id].window, targets[id].tab)
				else
					pick_mode(w, p, id:sub(5), false, { "claude", "resume", "nvim" })
				end
			end)
		end),
	})

	-- A tab with a lone idle shell, made if the mux window has none.
	local function shell_tab(mw)
		for _, tab in ipairs(mw:tabs()) do
			if tab_parts(tab).shell then
				return tab
			end
		end
		return (mw:spawn_tab({ cwd = wezterm.home_dir }))
	end

	-- Neovim with unsaved changes, from the buffers it reports (nvim/lua/configs/statusbar.lua).
	local function unsaved(p)
		if not editor_info(p) then
			return false
		end
		local ok, status = pcall(wezterm.serde.json_decode, p:get_user_vars().nvim_status or "")
		for _, buf in ipairs(ok and type(status) == "table" and status.buffers or {}) do
			if buf.modified then
				return true
			end
		end
		return false
	end

	-- Closes a workspace: the agents exit (their sessions stay resumable from CTRL|ALT w), Neovim,
	-- the docker view and the scripts it runs close with their panes, and when it is the tab on
	-- screen a plain shell takes its place, so WezTerm stays open. Neovim with unsaved changes is
	-- shown and asked to quit instead (:confirm qa, so it offers to save); closing again finishes.
	local function close_workspace(mw, tab)
		local t = tab_parts(tab)
		if t.shell then
			return
		end
		for _, p in ipairs(t.panes) do
			if unsaved(p) then
				switch(mw, tab)
				p:activate()
				p:send_text("\x1b:confirm qa\r")
				return
			end
		end
		if mw:active_tab():tab_id() == tab:tab_id() then
			shell_tab(mw):activate()
		end
		for _, p in ipairs(t.panes) do
			wezterm.background_child_process({ cli, "cli", "kill-pane", "--pane-id", tostring(p:pane_id()) })
		end
	end

	-- Reloads a workspace: every Neovim in it (the editor, the docker view, the sidebar) runs :restart, which
	-- starts it again with the same arguments, so config changes take effect; the agents keep
	-- running. A Neovim with unsaved changes refuses (:restart quits with :qall), so it is shown.
	local function reload_workspace(mw, tab)
		local t = tab_parts(tab)
		for _, p in ipairs(t.panes) do
			if editor_info(p) then
				if unsaved(p) then
					switch(mw, tab)
					p:activate()
				end
				p:send_text("\x1b:restart\r")
			end
		end
		-- A workspace from before the sidebar gets one.
		if (t.agent or t.editor) and t.root ~= "" then
			ensure_sidebar(tab, t.root)
		end
	end

	-- CTRL|ALT r reloads the workspace on screen.
	table.insert(config.keys, {
		mods = "CTRL|ALT",
		key = "r",
		action = wezterm.action_callback(function(window)
			reload_workspace(window:mux_window(), window:active_tab())
		end),
	})

	-- CTRL|ALT q, next to w, closes the workspace on screen.
	table.insert(config.keys, {
		mods = "CTRL|ALT",
		key = "q",
		action = wezterm.action_callback(function(window)
			close_workspace(window:mux_window(), window:active_tab())
		end),
	})

	-- Neovim's workspaces and agents sections (nvim/lua/configs/workspaces.lua) ask through the
	-- workspace user var, tab separated with a clock at the end so a repeat is a change:
	-- "tab <id>" and "pane <id>" switch there, "open <mode> <folder>" opens a workspace like
	-- CTRL|ALT w (mode claude, resume, nvim or session:<id>), "close <tab id>" closes one. "follow
	-- <worktree> <agent pane> <branch>" comes from Neovim's worktree switch (nvim/lua/packs/git.lua):
	-- it becomes the followed worktree as if that agent was focused (the pane may be empty, a worktree
	-- without an agent), so focusing any other agent moves Neovim back.
	local function find_tab(id)
		for _, mw in ipairs(wezterm.mux.all_windows()) do
			for _, tab in ipairs(mw:tabs()) do
				if tab:tab_id() == id then
					return mw, tab
				end
			end
		end
	end
	local function handle_request(window, pane, value)
		local args = {}
		for field in (value .. "\t"):gmatch("([^\t]*)\t") do
			table.insert(args, field)
		end
		local kind = args[1]
		if kind == "tab" or kind == "close" then
			local mw, tab = find_tab(tonumber(args[2]))
			if tab and kind == "tab" then
				switch(mw, tab)
			elseif tab then
				close_workspace(mw, tab)
			end
		elseif kind == "pane" then
			local target = wezterm.mux.get_pane(tonumber(args[2]))
			local mw, tab = find_tab(target and target:tab():tab_id())
			if tab then
				switch(mw, tab)
				target:activate()
			end
		elseif kind == "open" and args[3] and args[3] ~= "" then
			open(window, pane, args[3], args[2], args[4] == "here")
		elseif kind == "follow" and args[2] and args[2] ~= "" then
			write_focus(args[2] .. "\t" .. (args[3] or "") .. "\t" .. (args[4] or ""))
		end
	end

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
		if name == "workspace" then
			local request = value:match("^(.*)\t%d+$")
			if request then
				handle_request(window, pane, request)
			end
			return
		end
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

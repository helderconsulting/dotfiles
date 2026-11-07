local wezterm = require("wezterm")
local data = require("workspace.workbench.presentation.wezterm.state")
local actions = require("workspace.workbench.presentation.wezterm.actions")
local theme = require("workspace.workbench.presentation.wezterm.theme")

local M = {}

M.font_size = 18 * 22 / 21.6

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

local function is_nvim(pane)
	return require("navigate").is_nvim(pane, foreground_process(pane))
end

local function editor_info(pane)
	if not is_nvim(pane) then
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
	local function detail(text, fg)
		table.insert(details, { text = (#details > 0 and "  " or "") .. text, fg = fg })
	end
	local git = type(status.git) == "table" and status.git
	if git then
		parts = { { text = git.branch ~= "" and git.branch or "loading" } }
		if (git.ahead or 0) > 0 then
			detail(git.ahead .. " ahead of " .. (git.base or "base"))
		end
		if (git.behind or 0) > 0 then
			detail(git.behind .. " behind")
		end
		if (git.files or 0) > 0 then
			detail(git.files .. " files +" .. (git.added or 0) .. " −" .. (git.removed or 0))
		end
		if (git.uncommitted or 0) > 0 then
			detail(git.uncommitted .. " uncommitted")
		end
		local review = type(git.review) == "table" and git.review or {}
		if review.ready then
			detail("ready for review", theme.schemes.green.fg)
		elseif review.approved then
			detail("approved", theme.schemes.green.dim)
		end
		if (review.draft or 0) > 0 then
			detail("reviewing " .. review.draft, theme.schemes.purple.fg)
		end
		if (review.sent or 0) > 0 then
			detail("sent " .. review.sent, theme.schemes.orange.fg)
		end
		if (review.resolved or 0) > 0 then
			detail("resolved " .. review.resolved, theme.schemes.green.dim)
		end
		return { editor = true, mode = status.mode or "nvim", parts = parts, details = details, branch = "", worktree = "" }
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

local shells = { zsh = true, bash = true, fish = true }

local function shell_info(pane)
	local status = pane:get_user_vars().shell_status or ""
	local mode, cwd, cmd = status:match("^([^\t]*)\t([^\t]*)\t(.*)$")
	if not mode then
		return nil
	end
	local proc = (foreground_process(pane):match("([^/]+)$") or ""):gsub("^%-", "")
	local running = not shells[proc]
	return { mode = running and "running" or mode, parts = { { text = running and (cmd ~= "" and cmd or proc) or cwd } }, branch = "", worktree = "" }
end

local function tabs_entry(tabs, extra)
	if #tabs == 0 then
		tabs = { { name = "loading", info = "", scheme = theme.schemes.grey, current = true } }
	end
	local e = { badge = { label = "", scheme = theme.schemes.green }, tabs = tabs, split = true, parts = {}, worktree = "", branch = "" }
	for k, v in pairs(extra or {}) do
		e[k] = v
	end
	return e
end

local roles = {}

function roles.sidebar(w, screens)
	local tabs = {}
	for _, t in ipairs(screens.sidebar and screens.sidebar.sections or {}) do
		table.insert(tabs, { name = t.name or "", info = tostring(t.count or 0), scheme = theme.schemes.green, current = t.current == true })
	end
	local daemon = data.daemon()
	local word, kind = daemon and daemon.word, daemon and daemon.tone
	if word then
		table.insert(tabs, { name = "agentd", info = word, scheme = theme.kind(kind), current = false })
	end
	return tabs_entry(tabs, { sidebar = true })
end

function roles.conversation(_, screens)
	local selected = screens.conversation and screens.conversation.agent
	for _, a in ipairs(data.milites()) do
		if a.id == selected then
			local word = a.state
			return tabs_entry({ { name = a.name, info = word, scheme = theme.state(word), current = true } })
		end
	end
	return tabs_entry({ { name = "no agent selected", info = "", scheme = theme.schemes.grey, current = true } })
end

function roles.docker(w, screens)
	local docker = screens.infra and screens.infra.docker or {}
	local tabs = {}
	for _, t in ipairs(docker.tabs or {}) do
		table.insert(tabs, { name = t.name or "", info = t.word or "", scheme = theme.kind(t.kind), current = t.current == true })
	end
	if docker.down then
		tabs = { { name = "docker engine", info = "down", scheme = theme.schemes.orange, current = true } }
	elseif #tabs == 0 then
		tabs = { { name = "docker", info = "", scheme = theme.schemes.grey, current = true } }
	end
	return tabs_entry(tabs, { docker = true, menu_width = tonumber(docker.width), worktree = docker.project or "" })
end

local function pane_info(pane, w, screens)
	local role = w and w:role_of(pane:pane_id())
	if role and roles[role] then
		return roles[role](w, screens)
	end
	return editor_info(pane) or shell_info(pane)
end

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
	local place = e.compact and "" or wezterm.truncate_right(e.worktree ~= "" and e.worktree or e.branch or "", 16)
	local details = not e.compact and e.details or {}
	local shown_parts = e.compact and {} or e.parts
	local function fixed()
		local w = wezterm.column_width(edge) + wezterm.column_width(num) + wezterm.column_width(label) + 1 + 2
		if #details > 0 then
			w = w + 2 + parts_width(details)
		end
		return place ~= "" and w + 5 + wezterm.column_width(place) or w
	end
	local main_width = math.min(parts_width(shown_parts), (e.editor or e.docker) and 80 or 28)
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
	local parts = shown_parts
	if e.current_tab then
		local start, used = 1, 0
		for _, part in ipairs(parts) do
			if part.tab <= e.current_tab then
				used = used + wezterm.column_width(part.text)
			end
		end
		while used > main_width and start < e.current_tab do
			for _, part in ipairs(parts) do
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
			seg(part.fg or c.dim, bg, part.text)
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
		local need = 0
		for i = 1, #tabs do
			need = need + natural(i)
		end
		if need <= avail then
			local share = math.floor((avail - need) / #tabs)
			for i = 1, #tabs do
				widths[i] = natural(i) + (i < #tabs and share or avail - need - share * (#tabs - 1))
			end
		else
			local share = math.floor(avail / #tabs)
			for i = 1, #tabs do
				widths[i] = i < #tabs and share or avail - share * (#tabs - 1)
			end
		end
		widths[1] = widths[1] + cw(num)
		if e.split_at and #tabs == 2 and e.split_at < left then
			widths[1], widths[2] = e.split_at, left - e.split_at
		end
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

	local c0 = tabs[1] and tabs[1].scheme or theme.schemes.green
	local function marker(text)
		local t = wezterm.truncate_right(text, math.max(left, 0))
		seg(c0.dim, theme.palette.bar, t)
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
		local bg = t.current and (focused and c.focus or c.bg) or theme.palette.bar
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
		seg(theme.palette.bar, theme.palette.bar, string.rep(" ", left))
	end
end

local function filler(items, width)
	table.insert(items, { Background = { Color = theme.palette.bar } })
	table.insert(items, { Text = string.rep(" ", width) })
end

local function bar_entries(window)
	local list = {}
	local tab = window:active_tab()
	local w = actions.find_by_tab(tab:tab_id())
	local screens = w and data.screens(w.id) or {}
	for _, p in ipairs(tab:panes_with_info()) do
		local info = pane_info(p.pane, w, screens)
		if info then
			info.pane = p.pane
			info.focused = p.is_active
			info.left, info.width = p.left, p.width
			table.insert(list, info)
		end
	end
	return list
end

local function natural_width(e)
	local scratch, w = {}, 0
	if e.tabs then
		push_tabs(scratch, e, false, nil, 1)
	else
		push_entry(scratch, theme.mode(e.mode), e, false, nil, 1)
	end
	for _, item in ipairs(scratch) do
		if type(item) == "table" and item.Text then
			w = w + wezterm.column_width(item.Text)
		end
	end
	return w
end

local function bar_items(window, entries)
	local items, order = {}, {}
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
		if by_left[e.left] then
			table.insert(by_left[e.left].entries, e)
		end
	end
	for i, col in ipairs(columns) do
		local start = i == 1 and 0 or col.left - 1
		local stop = columns[i + 1] and columns[i + 1].left - 1 or col.left + col.width
		local width = stop - start
		if #col.entries == 0 then
			filler(items, width)
		end
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
			table.insert(order, e.pane:pane_id())
			local number = #order <= 9 and #order or nil
			if e.tabs then
				push_tabs(items, e, e.focused, w, number)
			else
				push_entry(items, theme.mode(e.mode), e, e.focused, w, number)
			end
		end
	end
	return items, order
end

local last_order, last_window = {}, nil

local function record_order(order, window)
	local id = window:window_id()
	local text = table.concat(order, "\n") .. "\n"
	if text ~= last_order[id] then
		data.write_file("bar-" .. id, text)
		last_order[id] = text
	end
	if window:is_focused() and last_window ~= id then
		data.write_file("bar-window", id .. "\n")
		last_window = id
	end
end

function M.refresh(window)
	local entries = bar_entries(window)
	local items, order = bar_items(window, entries)
	record_order(order, window)
	window:set_left_status(wezterm.format(items))
	local show = #entries > 0
	local overrides = window:get_config_overrides() or {}
	if (overrides.enable_tab_bar == true) ~= show then
		overrides.enable_tab_bar = show
		overrides.hide_tab_bar_if_only_one_tab = false
		window:set_config_overrides(overrides)
	end
end

return M

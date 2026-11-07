local M = {}

local app = require("workspace.workbench.presentation.nvim.app")
local cards = require("workspace.workbench.presentation.nvim.cards")
local ObserveResourceCommand = require("workspace.infra.application.commands.observe_resource_command")
local ToggleResourceCommand = require("workspace.infra.application.commands.toggle_resource_command")
local PerformActionCommand = require("workspace.infra.application.commands.perform_action_command")
local InfraScreen = require("workspace.infra.presentation.infra_screen")

local function service()
	return app.services().resource_process
end

local sections = service():section_names()

local state = {
	section = 1,
	entries = {
		containers = {},
		images = {},
		volumes = {},
		vms = {},
		desktops = {},
		["vpn devices"] = {},
		ports = {},
		scripts = {},
	},
	current = {},
	down = false,
	mode = "logs",
	marked = {},
}

local main_win, main_buf, menu_win, menu_buf, items_win, items_buf

local function menu_width()
	return app.services().workspace_process:panel_width(vim.o.columns)
end
local ns = vim.api.nvim_create_namespace("docker")

local function section_name()
	return sections[state.section]
end

local function docker_down()
	return state.down and service():section(section_name()).docker == true
end

local function current_entry()
	local name = section_name()
	for i, e in ipairs(state.entries[name]) do
		if e.id == state.current[name] then
			return e, i
		end
	end
end

local function marked_entries()
	local marks = state.marked[section_name()] or {}
	return vim.tbl_filter(function(e)
		return marks[e.id]
	end, state.entries[section_name()])
end


local last_report
local function report()
	local entry = current_entry()
	local marked = #marked_entries()
	local section = service():section(section_name())
	local info = {
		section = section_name(),
		project = section.place or section.docker and (service():docker_project() or "all") or section_name(),
		down = docker_down(),
		tabs = {
			{
				name = section_name() .. (entry and ("  " .. entry.name) or ""),
				word = marked > 0 and (marked .. " marked") or entry and entry.word or "empty",
				kind = marked > 0 and "busy" or entry and entry.kind or "off",
				current = true,
			},
		},
		width = 2 * (menu_width() + 1),
	}
	local payload = vim.json.encode(info)
	if payload ~= last_report then
		last_report = payload
		app.update_screen(InfraScreen, function(v)
			v:report_docker(info)
		end)
	end
end


local kind_rank = { bad = 4, busy = 3, ok = 2, off = 1 }

local function section_kind(name)
	local badge = service():section(name).badge_kind
	if badge then
		return badge
	end
	local kind
	for _, e in ipairs(state.entries[name]) do
		if (kind_rank[e.kind] or 0) > (kind_rank[kind] or 0) then
			kind = e.kind
		end
	end
	return kind or "off"
end

local function section_detail(name)
	local section = service():section(name)
	if section.badge_word then
		return section.badge_word
	elseif section.place then
		return section.place
	elseif section.docker then
		return state.down and "engine down" or (service():docker_project() or "all")
	end
	return ""
end

local function render_menu()
	local list = {}
	for _, name in ipairs(sections) do
		table.insert(list, { name = name, kind = section_kind(name) })
	end
	state.moving = true
	cards.render(menu_buf, menu_win, ns, list, function(e)
		return { e.name, section_detail(e.name), tostring(#state.entries[e.name]) }
	end, { selected = state.section, active = vim.api.nvim_get_current_win() == menu_win })
	state.moving = false
end

local function card(e)
	return { e.name, e.detail or "", e.word or "" }
end

local function render_items()
	local active = vim.api.nvim_get_current_win() == items_win
	state.moving = true
	if docker_down() then
		cards.render(items_buf, items_win, ns, { { name = "docker engine", word = "down", kind = "bad" } }, function(e)
			return { e.name, "brew services start colima", e.word }
		end, { active = active })
	else
		local _, index = current_entry()
		cards.render(items_buf, items_win, ns, state.entries[section_name()], card, {
			selected = index,
			empty = "no " .. section_name(),
			active = active,
			multi = true,
			marked = state.marked[section_name()],
		})
	end
	state.moving = false
end


local job, generation = nil, 0
local shown -- section and id the content is for

local function set_content(lines)
	vim.bo[main_buf].modifiable = true
	vim.api.nvim_buf_set_lines(main_buf, 0, -1, false, lines)
	vim.bo[main_buf].modifiable = false
end

local function append(lines)
	if not vim.api.nvim_buf_is_valid(main_buf) then
		return
	end
	local count = vim.api.nvim_buf_line_count(main_buf)
	local empty = count == 1 and vim.api.nvim_buf_get_lines(main_buf, 0, 1, false)[1] == ""
	local follow = vim.api.nvim_win_is_valid(main_win) and vim.api.nvim_win_get_cursor(main_win)[1] >= count
	vim.bo[main_buf].modifiable = true
	vim.api.nvim_buf_set_lines(main_buf, empty and 0 or -1, -1, false, lines)
	vim.bo[main_buf].modifiable = false
	if follow then
		vim.api.nvim_win_set_cursor(main_win, { vim.api.nvim_buf_line_count(main_buf), 0 })
	end
end

local function stream(cmd)
	generation = generation + 1
	local gen, partial = generation, { stdout = "", stderr = "" }
	local function on(kind)
		return function(_, data)
			if not data then
				return
			end
			local text = (partial[kind] .. data):gsub("\27%[[%d;?]*[A-Za-z]", ""):gsub("\r", "")
			local lines = vim.split(text, "\n")
			partial[kind] = table.remove(lines)
			if #lines > 0 then
				vim.schedule(function()
					if gen == generation then
						append(lines)
					end
				end)
			end
		end
	end
	job = vim.system(cmd, { stdout = on("stdout"), stderr = on("stderr") })
end

local function display(buf, bar)
	if not (main_win and vim.api.nvim_win_is_valid(main_win)) then
		return
	end
	if vim.api.nvim_win_get_buf(main_win) ~= buf then
		vim.api.nvim_win_set_buf(main_win, buf)
		if bar then
			vim.api.nvim_win_set_cursor(main_win, { vim.api.nvim_buf_line_count(buf), 0 })
		end
	end
	vim.wo[main_win].winbar = bar and bar:gsub("%%", "%%%%") or ""
end

local function show()
	local name, entry = section_name(), current_entry()
	local key = entry and (name .. ":" .. entry.id .. ":" .. state.mode .. ":" .. (entry.view_key or ""))
		or (name .. (docker_down() and ":down" or ":none"))
	if key == shown then
		return
	end
	shown = key
	if job then
		job:kill(15)
		job = nil
	end
	generation = generation + 1
	local term
	set_content({})
	if docker_down() then
		set_content({ "", " the docker engine isn't running", " start it with: brew services start colima" })
	elseif not entry and name == "desktops" then
		set_content({
			"",
			" no desktops",
			" add one with <leader>a, or export PCs from Windows App into",
			" " .. vim.fn.fnamemodify(service():desktops_dir(), ":~") .. " (<leader>o opens it)",
		})
	elseif not entry then
		set_content({ "", " no " .. name })
	else
		local shown_dto = service():show(name, entry, state.mode)
		set_content(shown_dto.lines)
		term = shown_dto.terminal
		if shown_dto.command and not term then
			stream(shown_dto.command)
		end
	end
	display(term and term.buf or main_buf, term and term.bar)
end

local set_actions

local function redraw()
	render_menu()
	render_items()
	set_actions()
	show()
	report()
end


local function natural(name)
	return (name:lower():gsub("%d+", function(n)
		return ("%012d"):format(tonumber(n))
	end))
end

local function observe()
	for name, list in pairs(state.entries) do
		for _, e in ipairs(list) do
			local status = service():observe(ObserveResourceCommand.new({ section = name, id = e.id, word = e.word, kind = e.kind }))
			e.word, e.kind = status.word, status.kind
		end
	end
end

local refreshing

local function refresh()
	if refreshing then
		refreshing = "again"
		return
	end
	refreshing = true
	local pending = #sections
	local down = false
	for _, name in ipairs(sections) do
		local function finish(list)
			if not list then
				down = true
				state.entries[name] = {}
			else
				table.sort(list, function(a, b)
					if (a.order or 1) ~= (b.order or 1) then
						return (a.order or 1) < (b.order or 1)
					end
					return natural(a.name) < natural(b.name)
				end)
				state.entries[name] = list
			end
			local keep = false
			for _, e in ipairs(state.entries[name]) do
				keep = keep or e.id == state.current[name]
			end
			if not keep then
				state.current[name] = state.entries[name][1] and state.entries[name][1].id
			end
			pending = pending - 1
			if pending == 0 then
				state.down = down
				for _, section in ipairs({ "images", "volumes" }) do
					service():mark_usage(state.entries[section])
				end
				observe()
				redraw()
				local again = refreshing == "again"
				refreshing = nil
				if again then
					refresh()
				end
			end
		end
		service():fetch(name, finish)
	end
end


local hand_off = app.hand_off

local function step_tab(delta, direction)
	local list = state.entries[section_name()]
	local _, index = current_entry()
	local target = list[(index or 0) + delta * vim.v.count1]
	if vim.v.count > 0 then
		target = target or list[delta > 0 and #list or 1]
	end
	if not target then
		return direction and hand_off(direction)
	end
	state.current[section_name()] = target.id
	state.mode = "logs"
	redraw()
end

local function go_tab(first)
	local list = state.entries[section_name()]
	local target = list[vim.v.count > 0 and math.min(vim.v.count, #list) or first and 1 or #list]
	if target then
		state.current[section_name()] = target.id
		state.mode = "logs"
		redraw()
	end
end

local function step_section(delta, direction)
	local target = state.section + delta * vim.v.count1
	if vim.v.count > 0 then
		target = math.max(1, math.min(#sections, target))
	end
	if not sections[target] then
		return direction and hand_off(direction)
	end
	state.section = target
	state.mode = "logs"
	redraw()
end


local view = {}

function view.run(cmd, opts)
	opts = opts or {}
	vim.system(cmd, { text = true, env = opts.env }, function(res)
		vim.schedule(function()
			if opts.done then
				opts.done(res)
			end
			if res.code ~= 0 then
				vim.notify(vim.trim(res.stderr ~= "" and res.stderr or res.stdout), vim.log.levels.ERROR)
			end
			refresh()
		end)
	end)
end

function view.split(cmd)
	vim.system(
		vim.list_extend({ "wezterm", "cli", "split-pane", "--pane-id", vim.env.WEZTERM_PANE, "--right", "--" }, cmd)
	)
end

function view.refresh()
	refresh()
end

function view.confirm(question)
	return view.batch or vim.fn.confirm(question, "&yes\n&no", 2) == 1
end

function view.toggle_mode()
	state.mode = state.mode == "logs" and "inspect" or "logs"
	redraw()
end

function view.select(id)
	state.current[section_name()] = id
	refresh()
end

local function section_actions(name)
	local list = {}
	for _, dto in ipairs(service():actions(name)) do
		table.insert(list, {
			dto.key,
			function(e, port)
				return service():perform(PerformActionCommand.new({ section = name, key = dto.key, entry = e, view = port }))
			end,
			dto.label,
			always = dto.always,
			single = dto.single,
		})
	end
	return list
end

local actions = {}
for _, name in ipairs(sections) do
	actions[name] = section_actions(name)
end

local close = {
	"<leader>-",
	function()
		vim.cmd("qa")
	end,
	"close docker view",
	always = true,
}

local kind_colors = { ok = "#77DD77", busy = "#A58BD3", bad = "#E0955A", off = "#8C8C8C", detail = "#3F6F3F" }
local single = {
	["<leader>n"] = true,
	["<leader>c"] = true,
	["<leader>p"] = true,
	["<leader>e"] = true,
	["<leader>i"] = true,
}

local function batchable(a)
	return a[1]:match("^<leader>%a$") and not a.always and not a.single and not single[a[1]]
end

local function run_on(a, entries)
	if #entries > 1 then
		local names = vim.tbl_map(function(e)
			return e.name
		end, entries)
		if vim.fn.confirm(a[3] .. ": " .. table.concat(names, ", ") .. "?", "&yes\n&no", 2) ~= 1 then
			return
		end
		view.batch = true
	end
	for _, e in ipairs(entries) do
		local ok, err = pcall(a[2], e, view)
		if not ok then
			vim.notify(tostring(err), vim.log.levels.ERROR)
		end
	end
	view.batch = nil
	if #entries > 1 then
		vim.notify(a[3] .. ": " .. #entries .. " " .. section_name())
	end
end

local find = {
	"<leader>f",
	function()
		local name = section_name()
		local list = state.entries[name]
		if #list == 0 then
			return
		end
		require("packs.fzf")
		local fzf = require("fzf-lua")
		local utils = require("fzf-lua.utils")
		local lines, by_line, width = {}, {}, 0
		for _, e in ipairs(list) do
			width = math.max(width, vim.fn.strdisplaywidth(e.name))
		end
		for _, e in ipairs(list) do
			local detail = e.find_detail
			local line = ("%s  %s  %s"):format(
				utils.ansi_from_rgb(kind_colors[e.kind] or kind_colors.off, ("%-12s"):format(e.word or "")),
				e.name .. string.rep(" ", width - vim.fn.strdisplaywidth(e.name)),
				utils.ansi_from_rgb(kind_colors.detail, detail)
			)
			table.insert(lines, line)
			by_line[vim.trim(utils.strip_ansi_coloring(line))] = e
		end
		local function picked(selected)
			local out = {}
			for _, line in ipairs(selected or {}) do
				local e = by_line[vim.trim(utils.strip_ansi_coloring(line))]
				if e then
					table.insert(out, e)
				end
			end
			return out
		end
		local fzf_actions = {
			["enter"] = function(selected)
				local entries = picked(selected)
				if #entries == 0 or section_name() ~= name then
					return
				end
				state.current[name] = entries[1].id
				state.mode = "logs"
				redraw()
			end,
		}
		local header = { "enter show", "tab mark", "ctrl-a all" }
		for _, a in ipairs(actions[name] or {}) do
			local key = a[1]:match("^<leader>(%a)$")
			if key and batchable(a) then
				table.insert(header, "ctrl-" .. key .. " " .. (a[3]:match("^(%S+ or %S+)") or a[3]:match("^%S+")))
				fzf_actions["ctrl-" .. key] = function(selected)
					local entries = picked(selected)
					if #entries > 0 and section_name() == name then
						run_on(a, entries)
					end
				end
			end
		end
		fzf.fzf_exec(lines, {
			prompt = name .. "> ",
			fzf_opts = {
				["--ansi"] = true,
				["--multi"] = true,
				["--marker"] = "▌",
				["--header"] = table.concat(vim.list_slice(header, 1, 3), " · ")
					.. "\n"
					.. table.concat(vim.list_slice(header, 4), " · "),
			},
			fzf_colors = { ["marker"] = "#A58BD3", ["selected-bg"] = "#15111D", ["selected-fg"] = "#A58BD3" },
			keymap = { fzf = { ["ctrl-a"] = "toggle-all" } },
			actions = fzf_actions,
		})
	end,
	"find in this section, act on several",
	always = true,
}

local mapped = { section = nil, lhs = {} }

local adopted = {}

local function buffers()
	return vim.tbl_filter(function(buf)
		return buf and vim.api.nvim_buf_is_valid(buf)
	end, vim.list_extend({ main_buf, menu_buf, items_buf }, adopted))
end

function set_actions()
	if mapped.section == section_name() then
		return
	end
	for _, buf in ipairs(buffers()) do
		for _, lhs in ipairs(mapped.lhs) do
			pcall(vim.keymap.del, "n", lhs, { buffer = buf })
			pcall(vim.keymap.del, "t", lhs, { buffer = buf })
		end
	end
	mapped = { section = section_name(), lhs = {} }
	for _, a in ipairs(vim.list_extend(vim.list_slice(actions[section_name()]), { find, close })) do
		table.insert(mapped.lhs, a[1])
		for _, buf in ipairs(buffers()) do
			local modes = vim.list_contains(adopted, buf) and { "n", "t" } or "n"
			vim.keymap.set(modes, a[1], function()
				local marked = marked_entries()
				if #marked > 0 and batchable(a) then
					state.marked[section_name()] = nil
					run_on(a, marked)
					redraw()
					return
				end
				local entry = current_entry()
				if entry and a[1] == "<leader>s" then
					local status = service():toggle(ToggleResourceCommand.new({ section = section_name(), id = entry.id }))
					if status then
						entry.word, entry.kind = status.word, status.kind
						redraw()
					end
				end
				if entry or a.always then
					a[2](entry, view)
				end
			end, { buffer = buf, desc = a[3], nowait = true })
		end
	end
	local ok, wk_buf = pcall(require, "which-key.buf")
	if ok and wk_buf.clear then
		for _, buf in ipairs(buffers()) do
			pcall(wk_buf.clear, { buf = buf })
		end
	end
end

local function focus(win)
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_set_current_win(win)
	end
end

local function keymaps(buf)
	vim.keymap.set("n", "-", "<nop>", { buffer = buf })
end

local function list_keymaps(buf, step, go, left, right)
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc, nowait = true })
	end
	for _, lhs in ipairs({ "j", "<Down>" }) do
		map(lhs, function()
			step(1)
		end, "next")
	end
	for _, lhs in ipairs({ "k", "<Up>" }) do
		map(lhs, function()
			step(-1)
		end, "previous")
	end
	map("gg", function()
		go(true)
	end, "first")
	map("G", function()
		go(false)
	end, "last")
	for _, lhs in ipairs({ "h", "<Left>" }) do
		map(lhs, left, "left column")
	end
	for _, lhs in ipairs({ "l", "<Right>" }) do
		map(lhs, right, "right column")
	end
end

local function go_section(first)
	local target = vim.v.count > 0 and math.min(vim.v.count, #sections) or first and 1 or #sections
	if target ~= state.section then
		state.section = target
		state.mode = "logs"
		redraw()
	end
end

function view.adopt(buf)
	vim.b[buf].docker_view = true
	keymaps(buf)
	for _, key in ipairs({ "<M-Left>", "<M-Right>", "<M-Up>", "<M-Down>" }) do
		vim.keymap.set("t", key, "<C-\\><C-n>" .. key, { buffer = buf, remap = true })
	end
	table.insert(adopted, buf)
	mapped.section = nil
	set_actions()
end

function view.release(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if main_win and vim.api.nvim_win_is_valid(main_win) and vim.api.nvim_win_get_buf(main_win) == buf then
		vim.api.nvim_win_set_buf(main_win, main_buf)
	end
	adopted = vim.tbl_filter(function(b)
		return b ~= buf
	end, adopted)
	pcall(vim.api.nvim_buf_delete, buf, { force = true })
end


local function scratch(name)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, name)
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "docker"
	vim.b[buf].docker_view = true
	keymaps(buf)
	return buf
end

local function plain(win)
	for option, value in pairs({
		number = false,
		relativenumber = false,
		signcolumn = "no",
		foldcolumn = "0",
		statuscolumn = "",
		cursorline = false,
		list = false,
		spell = false,
	}) do
		vim.wo[win][option] = value
	end
end

function M.open()
	app.main_window()
	local first = vim.api.nvim_get_current_buf()
	main_buf = scratch("docker://content")
	main_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(main_win, main_buf)
	if first ~= main_buf and vim.api.nvim_buf_get_name(first) == "" then
		pcall(vim.api.nvim_buf_delete, first, {})
	end
	plain(main_win)
	vim.wo[main_win].wrap = true

	menu_buf = scratch("docker://sections")
	vim.cmd("rightbelow vertical " .. menu_width() .. "split")
	menu_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(menu_win, menu_buf)

	items_buf = scratch("docker://entries")
	vim.cmd("rightbelow vertical " .. menu_width() .. "split")
	items_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(items_win, items_buf)

	for _, win in ipairs({ items_win, menu_win }) do
		plain(win)
		vim.wo[win].winfixwidth = true
		vim.wo[win].wrap = false
		vim.wo[win].scrolloff = cards.height
		vim.api.nvim_win_set_width(win, menu_width())
	end

	list_keymaps(menu_buf, function(delta)
		step_section(delta)
	end, go_section, function()
		focus(main_win)
	end, function()
		focus(items_win)
	end)
	list_keymaps(items_buf, function(delta)
		step_tab(delta)
	end, go_tab, function()
		focus(menu_win)
	end, function()
		hand_off("Right")
	end)
	local function toggle_mark(delta)
		local entry = current_entry()
		if not entry then
			return
		end
		local marks = state.marked[section_name()] or {}
		marks[entry.id] = not marks[entry.id] or nil
		state.marked[section_name()] = marks
		local list = state.entries[section_name()]
		local _, index = current_entry()
		local target = list[index + delta]
		if target then
			state.current[section_name()] = target.id
			state.mode = "logs"
		end
		redraw()
	end
	vim.keymap.set("n", "<Tab>", function()
		toggle_mark(1)
	end, { buffer = items_buf, desc = "mark and next", nowait = true })
	vim.keymap.set("n", "<S-Tab>", function()
		toggle_mark(-1)
	end, { buffer = items_buf, desc = "mark and previous", nowait = true })
	vim.keymap.set("n", "<Esc>", function()
		state.marked[section_name()] = nil
		redraw()
	end, { buffer = items_buf, desc = "clear marks", nowait = true })

	local group = vim.api.nvim_create_augroup("DockerView", { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = menu_buf,
		callback = function()
			local index = not state.moving and cards.index_at(vim.api.nvim_win_get_cursor(menu_win)[1])
			if index and sections[index] and index ~= state.section then
				state.section = index
				state.mode = "logs"
				redraw()
			elseif not state.moving then
				render_menu()
			end
		end,
	})
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = items_buf,
		callback = function()
			local index = not state.moving and cards.index_at(vim.api.nvim_win_get_cursor(items_win)[1])
			local e = index and state.entries[section_name()][index]
			if e and e.id ~= state.current[section_name()] then
				state.current[section_name()] = e.id
				state.mode = "logs"
				redraw()
			elseif not state.moving then
				render_items()
			end
		end,
	})
	local default_cursor = vim.o.guicursor
	vim.api.nvim_create_autocmd("WinEnter", {
		group = group,
		callback = function()
			local win = vim.api.nvim_get_current_win()
			local list = win == menu_win or win == items_win
			vim.o.guicursor = list and "n-v-sm:block-CardCursor,i-c-ci-ve:ver25,r-cr-o:hor20" or default_cursor
			render_menu()
			render_items()
		end,
	})
	vim.api.nvim_set_current_win(menu_win)
	vim.o.guicursor = "n-v-sm:block-CardCursor,i-c-ci-ve:ver25,r-cr-o:hor20"
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			if job then
				pcall(job.kill, job, 15)
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimResized", {
		group = "DockerView",
		callback = function()
			for _, win in ipairs({ items_win, menu_win }) do
				if win and vim.api.nvim_win_is_valid(win) then
					vim.api.nvim_win_set_width(win, menu_width())
				end
			end
			refresh()
		end,
	})

	refresh()
	vim.uv.new_timer():start(2000, 2000, vim.schedule_wrap(refresh))
end

return M

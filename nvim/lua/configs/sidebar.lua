-- The sidebar: a Neovim in a narrow pane on the left of a workspace tab (wezterm/agents.lua runs
-- nvim +Sidebar), listing the workspaces (configs/workspaces.lua) or the agents (configs/agents.lua)
-- as cards (configs/cards.lua), like a mailbox. The two sections are tabs in the pane's WezTerm bar entry, like the
-- docker view's entries: the sidebar user var carries them with their counts, which also tells
-- WezTerm this pane is the sidebar, not the workspace's editor. ALT left and right go through them,
-- and past the ends on to the next pane like the rest of the ALT arrow grid (configs/keymaps.lua).
-- j and k (or the arrows) move a card at a time, with a count like 5j, gg and G go to the first and
-- last card and 12G to the twelfth. Enter goes there (a running workspace or agent) or opens it (a
-- closed project, an earlier session), and each section's other actions sit under the leader, as
-- in the docker view, where which-key shows only the current section's.
local workspaces = require("configs.workspaces")
local agents = require("configs.agents")
local cards = require("configs.cards")
local threads = require("configs.threads")
local layout = require("configs.layout")

local state_dir = (vim.env.XDG_STATE_HOME or (vim.env.HOME .. "/.local/state")) .. "/agent-status"
local narrow = 44
local page = 10

local M = {}

-- A card's three lines per section. The pane is narrow, so a folder shows its own name first and
-- where it sits below (ceuz/automator-1.0 and -2.0 would cut to the same text).
local function parent(dir)
	return dir and workspaces.short(vim.fs.dirname(dir)) or ""
end
local sections = {
	{
		name = "agents",
		list = agents,
		multi = true,
		card = function(e)
			local word = e.word
			local place = e.cwd and vim.fs.basename(e.cwd) or e.host
			if e.pane then
				local f = io.open(state_dir .. "/" .. e.pane)
				local fields = f and vim.split(f:read("*l") or "", "\t") or {}
				if f then
					f:close()
				end
				if fields[3] and fields[3] ~= "" then
					place = fields[5] ~= nil and fields[5] ~= "" and fields[5] or vim.fs.basename(fields[3])
				end
				local counts = threads.review_counts(fields[3])
				if (counts.open or 0) > 0 then
					word = word .. " · " .. counts.open .. " open"
				end
				if (counts.resolved or 0) > 0 then
					word = word .. " · " .. counts.resolved .. " resolved"
				end
			end
			return { e.name, place, word }
		end,
	},
	{
		name = "workspaces",
		list = workspaces,
		card = function(e)
			return { vim.fs.basename(e.dir), parent(e.dir), e.word .. (e.here and " · here" or "") }
		end,
	},
}
local state = { section = 1, entries = {}, current = {}, marked = {}, thread = {}, thread_current = nil, in_thread = false }
local buf, win, side_buf, side_win
local ns = vim.api.nvim_create_namespace("sidebar")

local function section()
	return sections[state.section]
end

local function entries()
	return state.entries[section().name] or {}
end

local function current_index()
	for i, e in ipairs(entries()) do
		if e.id == state.current[section().name] then
			return i
		end
	end
	return entries()[1] and 1 or nil
end

local function current_entry()
	local i = current_index()
	return i and entries()[i]
end

-- Tell WezTerm (wezterm/agents.lua) the sections as tabs with their counts, the current one marked,
-- for the bar entry; only when that changed, and empty when Neovim leaves.
local last_report
local function report(value)
	if vim.env.WEZTERM_PANE and value ~= last_report then
		last_report = value
		vim.api.nvim_ui_send(("\27]1337;SetUserVar=sidebar=%s\7"):format(vim.base64.encode(value)))
	end
end

local function report_tabs()
	local tabs = {}
	for i, s in ipairs(sections) do
		table.insert(tabs, { name = s.name, count = #(state.entries[s.name] or {}), current = i == state.section })
	end
	report(vim.json.encode({ tabs = tabs }))
end

local function thread_on()
	local f = io.open(state_dir .. "/sidebar-thread")
	local value = f and f:read("*l")
	if f then
		f:close()
	end
	return value ~= "off"
end

local function thread_filter(e)
	if not e or section().name ~= "agents" then
		return nil
	end
	local root = e.cwd
	if e.pane then
		local f = io.open(state_dir .. "/" .. e.pane)
		local fields = f and vim.split(f:read("*l") or "", "\t") or {}
		if f then
			f:close()
		end
		root = fields[3] ~= nil and fields[3] ~= "" and fields[3] or root
	end
	return { session = e.session, pane = e.pane, root = root }
end

local function thread_index()
	for i, item in ipairs(state.thread) do
		if item.id == state.thread_current then
			return i
		end
	end
	return #state.thread > 0 and #state.thread or nil
end

local function split_lists()
	if section().name ~= "agents" then
		return entries(), {}
	end
	local running, earlier = {}, {}
	for _, e in ipairs(entries()) do
		table.insert(e.pane and running or earlier, e)
	end
	return running, earlier
end

local function valid(w)
	return w and vim.api.nvim_win_is_valid(w)
end

local place_windows

local function render()
	report_tabs()
	state.moving = true
	local running, earlier = split_lists()
	local index = current_index()
	local below = index and index > #running
	local filter = state.thread_shown and thread_filter(current_entry())
	state.thread = filter and threads.items(filter) or {}
	if #state.thread == 0 then
		state.in_thread = false
	end
	local from, to = math.max(1, #state.thread - 2), #state.thread
	if state.in_thread then
		to = #state.thread - math.floor((#state.thread - (thread_index() or #state.thread)) / page) * page
		from = math.max(1, to - page + 1)
	end
	local inline = #state.thread > 0 and {
		items = state.thread,
		card = function(item)
			return item.card
		end,
		selected = state.in_thread and thread_index() or nil,
		active = state.in_thread,
		from = from,
		to = to,
	} or nil
	local function opts(selected, here)
		return {
			selected = selected,
			multi = section().multi,
			marked = state.marked[section().name],
			active = not state.in_thread,
			inline = here and inline or nil,
			keep_visible = true,
		}
	end
	local focused = state.in_thread and inline and current_entry()
	local top = opts(not below and index or nil, not below)
	top.title = valid(side_win) and "active" or nil
	if focused and not below then
		top.selected, top.frozen = 1, true
	end
	cards.render(buf, win, ns, (focused and not below) and { focused } or running, section().card, top)
	if valid(side_win) then
		local o = opts(below and index - #running or nil, below)
		o.title = "inactive"
		o.empty = "no inactive sessions"
		if focused and below then
			o.selected, o.frozen = 1, true
		end
		cards.render(side_buf, side_win, ns, (focused and below) and { focused } or earlier, section().card, o)
	end
	local current = vim.api.nvim_get_current_win()
	local want = below and valid(side_win) and side_win or win
	if (current == win or current == side_win) and current ~= want then
		vim.api.nvim_set_current_win(want)
	end
	state.moving = false
end

-- Natural order like the docker view: the entries a section puts first, then by name with numbers
-- compared as numbers.
local function natural(name)
	return (name or ""):lower():gsub("%d+", function(n)
		return ("%012d"):format(tonumber(n))
	end)
end

local function refresh()
	for _, s in ipairs(sections) do
		s.list.fetch(function(list)
			table.sort(list, function(a, b)
				if (a.order or 1) ~= (b.order or 1) then
					return (a.order or 1) < (b.order or 1)
				end
				return natural(a.name) < natural(b.name)
			end)
			state.entries[s.name] = list
			place_windows()
			render()
		end, { folder = state.folder })
	end
end

-- Moving ---------------------------------------------------------------------------------------

local function select(index)
	local list = entries()
	if #list == 0 then
		return
	end
	index = math.max(1, math.min(#list, index))
	if state.current[section().name] ~= list[index].id then
		state.thread_current = nil
	end
	state.current[section().name] = list[index].id
	state.in_thread = false
	render()
end

local function step(delta)
	select((current_index() or 1) + delta * vim.v.count1)
end

local function go(first)
	select(vim.v.count > 0 and vim.v.count or first and 1 or #entries())
end

local set_actions

-- Past the ends hand the move to WezTerm, like the docker view; the clock makes every request a
-- change for WezTerm's user-var-changed event.
local function hand_off(direction)
	if vim.env.WEZTERM_PANE then
		local value = vim.base64.encode(direction .. ":" .. vim.uv.hrtime())
		vim.api.nvim_ui_send(("\27]1337;SetUserVar=nav=%s\7"):format(value))
	end
end

local function step_thread(delta)
	local list = state.thread
	local index = (thread_index() or 0) + delta * vim.v.count1
	local item = list[math.max(1, math.min(#list, index))]
	if item then
		state.thread_current = item.id
		render()
	end
end

local function go_thread(first)
	local list = state.thread
	local item = list[vim.v.count > 0 and math.min(vim.v.count, #list) or first and 1 or #list]
	if item then
		state.thread_current = item.id
		render()
	end
end

local function open_thread_item()
	local item = state.thread[thread_index() or 0]
	if not item then
		return
	end
	if item.comment then
		threads.show_comment(item.comment.root, item.comment.id)
	elseif item.pane then
		workspaces.request("pane", item.pane)
	else
		local e = current_entry()
		if e and e.pane then
			workspaces.request("pane", e.pane)
		end
	end
end

function place_windows()
	if not (valid(side_win) and valid(win)) then
		return
	end
	local total = vim.api.nvim_win_get_height(win) + vim.api.nvim_win_get_height(side_win)
	vim.api.nvim_win_set_height(side_win, total - math.floor(total / 2))
end

local function show_earlier(on)
	if on and not valid(side_win) then
		local current = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(win)
		state.moving = true
		vim.cmd("rightbelow split")
		side_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(side_win, side_buf)
		for option, value in pairs({
			number = false,
			relativenumber = false,
			signcolumn = "no",
			foldcolumn = "0",
			statuscolumn = "",
			cursorline = false,
			list = false,
			spell = false,
			wrap = false,
			scrolloff = 0,
			winfixheight = true,
		}) do
			vim.wo[side_win][option] = value
		end
		vim.wo[win].statusline = " "
		vim.wo[win].winhighlight = "StatusLine:CardOffDetail,StatusLineNC:CardOffDetail"
		vim.api.nvim_set_current_win(valid(current) and current or win)
		state.moving = false
	elseif not on and valid(side_win) then
		state.moving = true
		vim.api.nvim_win_close(side_win, true)
		side_win = nil
		state.moving = false
	end
	place_windows()
end

local function toggle_thread()
	state.thread_shown = not state.thread_shown
	state.in_thread = false
	local f = io.open(state_dir .. "/sidebar-thread", "w")
	if f then
		f:write(state.thread_shown and "on" or "off", "\n")
		f:close()
	end
	render()
end

local function switch(delta, direction)
	if not sections[state.section + delta] then
		return hand_off(direction)
	end
	state.section = state.section + delta
	state.in_thread = false
	set_actions()
	show_earlier(section().name == "agents")
	render()
end

-- Actions --------------------------------------------------------------------------------------

-- What the sections' actions get besides their entry, like the docker view's.
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

function view.entries()
	return entries()
end

function view.balance()
	layout.balance(narrow)
end

function view.folder()
	return state.folder
end

function view.refresh()
	refresh()
end

function view.confirm(question)
	return view.batch or vim.fn.confirm(question, "&yes\n&no", 2) == 1
end

local function marked_entries()
	local marks = state.marked[section().name] or {}
	return vim.tbl_filter(function(e)
		return marks[e.id]
	end, entries())
end

local function run_on(a, list)
	local names = vim.tbl_map(function(e)
		return e.name
	end, list)
	if vim.fn.confirm(a[3] .. ": " .. table.concat(names, ", ") .. "?", "&yes\n&no", 2) ~= 1 then
		return
	end
	view.batch = true
	for _, e in ipairs(list) do
		local ok, err = pcall(a[2], e, view)
		if not ok then
			vim.notify(tostring(err), vim.log.levels.ERROR)
		end
	end
	view.batch = nil
end

local mapped = {}

function set_actions()
	for _, b in ipairs({ buf, side_buf }) do
		for _, lhs in ipairs(mapped) do
			pcall(vim.keymap.del, "n", lhs, { buffer = b })
		end
	end
	mapped = {}
	for _, a in ipairs(section().list.actions or {}) do
		table.insert(mapped, a[1])
		for _, b in ipairs({ buf, side_buf }) do
			vim.keymap.set("n", a[1], function()
				local marked = marked_entries()
				if #marked > 0 and not a.single and not a.always then
					state.marked[section().name] = nil
					run_on(a, marked)
					render()
					return
				end
				local e = current_entry()
				if e or a.always then
					a[2](e, view)
				end
			end, { buffer = b, desc = a[3], nowait = true })
		end
	end
	-- which-key reads a buffer's mappings once; have it read them again.
	local ok, wk_buf = pcall(require, "which-key.buf")
	if ok and wk_buf.clear then
		for _, b in ipairs({ buf, side_buf }) do
			pcall(wk_buf.clear, { buf = b })
		end
	end
end

local function leave_thread()
	state.in_thread = false
	render()
end

local function keymaps(b)
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = b, desc = desc, nowait = true })
	end
	local function either(card_fn, thread_fn)
		return function()
			if state.in_thread then
				thread_fn()
			else
				card_fn()
			end
		end
	end
	for _, lhs in ipairs({ "j", "<Down>" }) do
		map(lhs, either(function()
			step(1)
		end, function()
			step_thread(1)
		end), "next card")
	end
	for _, lhs in ipairs({ "k", "<Up>" }) do
		map(lhs, either(function()
			step(-1)
		end, function()
			step_thread(-1)
		end), "previous card")
	end
	map("gg", either(function()
		go(true)
	end, function()
		go_thread(true)
	end), "first card")
	map("G", either(function()
		go(false)
	end, function()
		go_thread(false)
	end), "last card")
	map("<M-Left>", function()
		switch(-1, "Left")
	end, "previous section")
	map("<M-Right>", function()
		switch(1, "Right")
	end, "next section")
	map("<CR>", either(function()
		local e = current_entry()
		if e then
			section().list.enter(e, view)
		end
	end, open_thread_item), "go there, or open it")
	for _, lhs in ipairs({ "l", "<Right>" }) do
		map(lhs, function()
			if #state.thread > 0 and not state.in_thread then
				state.in_thread = true
				state.thread_current = state.thread[math.max(1, #state.thread - page + 1)].id
				render()
			end
		end, "into the thread")
	end
	for _, lhs in ipairs({ "h", "<Left>" }) do
		map(lhs, leave_thread, "out of the thread")
	end
	map("t", toggle_thread, "show or hide threads")
	local function toggle_mark(delta)
		local e = current_entry()
		if not (e and section().multi) then
			return
		end
		local marks = state.marked[section().name] or {}
		marks[e.id] = not marks[e.id] or nil
		state.marked[section().name] = marks
		select((current_index() or 1) + delta)
	end
	map("<Tab>", function()
		toggle_mark(1)
	end, "mark and next")
	map("<S-Tab>", function()
		toggle_mark(-1)
	end, "mark and previous")
	map("<Esc>", function()
		state.marked[section().name] = nil
		leave_thread()
	end, "clear marks")
	-- Oil's - (packs/oil.lua) has no folder to open here.
	map("-", "<nop>")
end

function M.open()
	vim.g.sidebar = true
	local start = vim.env.PWD or vim.fn.getcwd()
	local git = vim.fs.find(".git", { path = start, upward = true })[1]
	if git and vim.fn.isdirectory(git) == 0 then
		local f = io.open(git)
		local gitdir = f and f:read("*l") or ""
		if f then
			f:close()
		end
		state.folder = gitdir:match("^gitdir: (.+)/%.git/worktrees/[^/]+$") or vim.fs.dirname(git)
	else
		state.folder = git and vim.fs.dirname(git) or start
	end
	buf = vim.api.nvim_get_current_buf()
	win = vim.api.nvim_get_current_win()
	vim.api.nvim_buf_set_name(buf, "sidebar://")
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	for option, value in pairs({
		number = false,
		relativenumber = false,
		signcolumn = "no",
		foldcolumn = "0",
		statuscolumn = "",
		cursorline = false,
		list = false,
		spell = false,
		wrap = false,
		scrolloff = 0,
	}) do
		vim.wo[win][option] = value
	end
	-- In normal mode the cursor takes the card's background, so it doesn't show where the terminal
	-- honors cursor colors; typing (a rename, a prompt) keeps the usual one.
	vim.o.guicursor = "n-v-sm:block-CardCursor,i-c-ci-ve:ver25,r-cr-o:hor20"
	side_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(side_buf, "sidebar://earlier")
	vim.bo[side_buf].modifiable = false
	keymaps(buf)
	keymaps(side_buf)
	set_actions()

	local function clicked(b, w)
		local line = vim.api.nvim_win_get_cursor(w)[1]
		local t = cards.inline_at(line, b)
		if t and state.thread[t] then
			state.in_thread = true
			state.thread_current = state.thread[t].id
			return render()
		end
		if state.in_thread then
			return render()
		end
		local index = cards.index_at(line, b)
		if index then
			select(index + (b == side_buf and #split_lists() or 0))
		else
			render()
		end
	end
	local group = vim.api.nvim_create_augroup("Sidebar", { clear = true })
	-- A click on a card picks it.
	for _, b in ipairs({ buf, side_buf }) do
		vim.api.nvim_create_autocmd("CursorMoved", {
			group = group,
			buffer = b,
			callback = function()
				if not state.moving then
					clicked(b, vim.api.nvim_get_current_win())
				end
			end,
		})
	end
	vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = refresh })
	local resize_timer = vim.uv.new_timer()
	vim.api.nvim_create_autocmd("VimResized", {
		group = group,
		callback = function()
			place_windows()
			refresh()
			resize_timer:start(400, 0, vim.schedule_wrap(function()
				layout.balance(narrow)
				place_windows()
				render()
			end))
		end,
	})
	vim.api.nvim_create_autocmd("WinEnter", { group = group, callback = function()
		if not state.moving then
			local current = vim.api.nvim_get_current_win()
			if current == win or current == side_win then
				clicked(current == win and buf or side_buf, current)
			else
				render()
			end
		end
	end })
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			report("")
		end,
	})

	local focus_watcher, focus_timer = vim.uv.new_fs_event(), vim.uv.new_timer()
	focus_watcher:start(state_dir, {}, function(_, filename)
		if filename and vim.fs.basename(filename) == "focus" then
			focus_timer:start(50, 0, vim.schedule_wrap(function()
				local f = io.open(state_dir .. "/focus")
				local pane = f and tonumber(((f:read("*l") or ""):match("^[^\t]*\t(%d+)")))
				if f then
					f:close()
				end
				for _, e in ipairs(state.entries.agents or {}) do
					if pane and e.pane == pane and state.current.agents ~= e.id then
						state.current.agents = e.id
						state.thread_current = nil
						state.in_thread = false
						render()
					end
				end
			end))
		end
	end)
	state.thread_shown = thread_on()
	show_earlier(section().name == "agents")
	if vim.o.columns ~= narrow then
		vim.schedule(function()
			layout.balance(narrow)
			place_windows()
			render()
		end)
	end
	refresh()
	vim.uv.new_timer():start(2000, 2000, vim.schedule_wrap(refresh))
end

vim.api.nvim_create_user_command("Sidebar", M.open, { desc = "workspaces and agents sidebar" })

return M

local app = require("workspace.workbench.presentation.nvim.app")
local cards = require("workspace.workbench.presentation.nvim.cards")
local board = require("workspace.workbench.presentation.nvim.board")
local SidebarScreen = require("workspace.workbench.presentation.sidebar_screen")
local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")

local M = {}

local page = 10
local sections = {
	{ name = "legio", list = board, multi = true },
}
local state = { section = 1, entries = {}, current = {}, marked = {}, thread = nil, thread_current = nil, in_thread = false, threads_shown = true }
local buf, win
local ns = vim.api.nvim_create_namespace("sidebar")
local log = {}

local function valid(w)
	return w and vim.api.nvim_win_is_valid(w)
end

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

local function thread_items()
	return state.thread and state.thread.items or {}
end

local function thread_index()
	return state.thread and state.thread:index_of(state.thread_current) or (#thread_items() > 0 and 1 or nil)
end

local function build_thread(e)
	if not (e and state.threads_shown and section().list.thread_on_select) then
		return nil
	end
	return section().list.thread_on_select(e, { log = log })
end

local function report_sections()
	local tabs = {}
	for i, s in ipairs(sections) do
		local list = state.entries[s.name] or {}
		table.insert(tabs, { name = s.name, count = s.list.count and s.list.count(list) or #list, current = i == state.section })
	end
	local text = vim.json.encode(tabs)
	if text ~= state.reported then
		state.reported = text
		app.update_screen(SidebarScreen, function(v)
			v:report_sections(tabs, section().name)
		end)
	end
end

local function selected_item()
	return state.in_thread and thread_items()[thread_index() or 0] or nil
end

local function follow_selection(opts)
	local e = current_entry()
	if e and section().list.show_conversation_on_select then
		section().list.show_conversation_on_select(e, selected_item(), opts)
	end
end

local function render()
	if not valid(win) then
		return
	end
	report_sections()
	state.moving = true
	local index = current_index()
	local entry = current_entry()
	state.thread = build_thread(entry)
	local items = thread_items()
	if #items == 0 then
		state.in_thread = false
	end
	local latest = items[1] and items[1].id
	local before = entry and state.latest and state.latest.agent == entry.id and state.latest.id or nil
	state.latest = entry and { agent = entry.id, id = latest } or nil
	if before and before ~= latest and state.in_thread and latest and (state.thread_current == nil or state.thread_current == before) then
		state.thread_current = latest
		vim.schedule(function()
			follow_selection({ incoming = true })
		end)
	end
	local from, to = 1, math.min(3, #items)
	if state.in_thread then
		local selected = thread_index() or 1
		from = state.thread and state.page_top and state.thread:index_of(state.page_top) or nil
		if not from or selected < from or selected >= from + page then
			from = math.floor((selected - 1) / page) * page + 1
		end
		to = math.min(#items, from + page - 1)
		state.page_top = items[from] and items[from].id
	end
	local inline = state.in_thread and #items > 0 and {
		items = items,
		card = function(item)
			return item.card
		end,
		selected = thread_index(),
		active = true,
		from = from,
		to = to,
		unread = state.thread and state.thread.unread or 0,
	} or nil
	local card = section().list.card_on_render
	local function opts(selected, here)
		return { selected = selected, multi = section().multi, marked = state.marked[section().name], active = not state.in_thread, inline = here and inline or nil, keep_visible = true, wrap = true }
	end
	local focused = inline and current_entry()
	local top = opts(index, true)
	top.empty = section().list.empty or "nothing here"
	if focused then
		top.selected, top.frozen = 1, true
	end
	cards.render(buf, win, ns, focused and { focused } or entries(), card, top)
	state.moving = false
end

local function moved()
	render()
	follow_selection()
end

local function natural(name)
	return (name or ""):lower():gsub("%d+", function(n)
		return ("%012d"):format(tonumber(n))
	end)
end

local function refresh()
	for _, s in ipairs(sections) do
		s.list.entries_on_refresh(state.folder, function(list)
			table.sort(list, function(a, b)
				if (a.order or 1) ~= (b.order or 1) then
					return (a.order or 1) < (b.order or 1)
				end
				return natural(a.sort_name or a.name) < natural(b.sort_name or b.name)
			end)
			state.entries[s.name] = list
			render()
		end)
	end
end

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
	moved()
end

local function step_thread(delta)
	local items = thread_items()
	local item = items[math.max(1, math.min(#items, (thread_index() or 0) + delta * vim.v.count1))]
	if item then
		state.thread_current = item.id
		moved()
	end
end

local function go_thread(first)
	local items = thread_items()
	local item = items[vim.v.count > 0 and math.min(vim.v.count, #items) or first and 1 or #items]
	if item then
		state.thread_current = item.id
		moved()
	end
end

local view = {}

function view.folder()
	return state.folder
end

function view.refresh()
	refresh()
end

function view.confirm(question)
	return view.batch or vim.fn.confirm(question, "&yes\n&no", 2) == 1
end

local mapped = {}

local function set_actions()
	for _, lhs in ipairs(mapped) do
		pcall(vim.keymap.del, "n", lhs, { buffer = buf })
	end
	mapped = {}
	local groups = vim.tbl_map(function(g)
		return { g[1], group = g[2], buffer = buf }
	end, section().list.groups or {})
	if #groups > 0 then
		pcall(function()
			require("which-key").add(groups)
		end)
	end
	for _, a in ipairs(section().list.actions or {}) do
		table.insert(mapped, a[1])
		vim.keymap.set("n", a[1], function()
			local marks = state.marked[section().name] or {}
			local marked = vim.tbl_filter(function(e)
				return marks[e.id]
			end, entries())
			if #marked > 0 and not a.single and not a.always then
				state.marked[section().name] = nil
				local names = vim.tbl_map(function(e)
					return e.name
				end, marked)
				if vim.fn.confirm(a[3] .. ": " .. table.concat(names, ", ") .. "?", "&yes\n&no", 2) == 1 then
					view.batch = true
					for _, e in ipairs(marked) do
						pcall(a[2], e, view)
					end
					view.batch = nil
				end
				return render()
			end
			local e = current_entry()
			if e or a.always then
				a[2](e, view, selected_item())
			end
		end, { buffer = buf, desc = a[3], nowait = true })
	end
	local ok, wk_buf = pcall(require, "which-key.buf")
	if ok and wk_buf.clear then
		pcall(wk_buf.clear, { buf = buf })
	end
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
			select((current_index() or 1) + vim.v.count1)
		end, function()
			step_thread(1)
		end), "next card")
	end
	for _, lhs in ipairs({ "k", "<Up>" }) do
		map(lhs, either(function()
			select((current_index() or 1) - vim.v.count1)
		end, function()
			step_thread(-1)
		end), "previous card")
	end
	map("gg", either(function()
		select(vim.v.count > 0 and vim.v.count or 1)
	end, function()
		go_thread(true)
	end), "first card")
	map("G", either(function()
		select(vim.v.count > 0 and vim.v.count or #entries())
	end, function()
		go_thread(false)
	end), "last card")
	map("<M-Left>", function()
		app.hand_off("Left")
	end, "window on the left")
	map("<M-Right>", function()
		app.hand_off("Right")
	end, "window on the right")
	map("<CR>", either(function()
		local e = current_entry()
		if not e then
			return
		end
		local latest = state.thread and state.thread:latest_turn()
		if latest then
			state.in_thread, state.thread_current = true, latest.id
		end
		section().list.open_on_enter(e, view)
		moved()
	end, function()
		app.focus("conversation")
	end), "go there, or open it")
	for _, lhs in ipairs({ "l", "<Right>" }) do
		map(lhs, function()
			local items = thread_items()
			if #items > 0 and not state.in_thread then
				state.in_thread, state.thread_current = true, items[1].id
				moved()
			end
		end, "into the thread")
	end
	for _, lhs in ipairs({ "h", "<Left>" }) do
		map(lhs, function()
			state.in_thread = false
			moved()
		end, "out of the thread")
	end
	map("t", function()
		state.threads_shown = not state.threads_shown
		state.in_thread = false
		render()
	end, "show or hide threads")
	local function toggle_mark(delta)
		local e = current_entry()
		if e and section().multi then
			local marks = state.marked[section().name] or {}
			marks[e.id] = not marks[e.id] or nil
			state.marked[section().name] = marks
			select((current_index() or 1) + delta)
		end
	end
	map("<Tab>", function()
		toggle_mark(1)
	end, "mark and next")
	map("<S-Tab>", function()
		toggle_mark(-1)
	end, "mark and previous")
	map("<Esc>", function()
		local item = selected_item()
		local e = current_entry()
		if item and e and section().list.handled_on_escape and section().list.handled_on_escape(e, item) then
			return
		end
		state.marked[section().name] = nil
		state.in_thread = false
		render()
	end, "clear marks, send a held message now, or interrupt the agent and edit a working or queued message")
	map("-", "<nop>")
end

local function follow_ask(view)
	local ask = view.state == "ask" and view.ask
	if not (ask and section().name == "legio" and state.current.legio == view.agent) then
		return false
	end
	state.thread = build_thread(current_entry())
	for _, item in ipairs(thread_items()) do
		if item.ask == ask then
			local changed = not (state.in_thread and state.thread_current == item.id)
			state.in_thread, state.thread_current = true, item.id
			return changed
		end
	end
	return false
end

local function follow_view(change)
	if change.id ~= app.workspace or not change.model or state.moving then
		return
	end
	local focus = change.model:focus()
	local switched = false
	if focus and section().name == "legio" and state.current.legio ~= focus then
		for _, e in ipairs(state.entries.legio or {}) do
			if e.id == focus then
				state.current.legio, state.in_thread, switched = focus, false, true
				break
			end
		end
	end
	local drafting = change.model.state == "draft"
	local draft_changed = drafting ~= state.drafting
	state.drafting = drafting
	local followed = follow_ask(change.model)
	if draft_changed then
		return refresh()
	elseif followed or switched then
		return render()
	end
end

function M.open()
	state.folder = app.folder()
	win = app.main_window()
	buf = vim.api.nvim_win_get_buf(win)
	vim.api.nvim_buf_set_name(buf, "sidebar://")
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	for option, value in pairs({ number = false, relativenumber = false, signcolumn = "no", foldcolumn = "0", statuscolumn = "", cursorline = false, list = false, spell = false, wrap = false, scrolloff = 0, sidescrolloff = 0 }) do
		vim.wo[win][option] = value
	end
	vim.o.mousescroll = "ver:3,hor:0"
	vim.o.guicursor = "n-v-sm:block-CardCursor,i-c-ci-ve:ver25,r-cr-o:hor20"
	keymaps(buf)
	set_actions()
	log = app.read_log(2000)

	local group = vim.api.nvim_create_augroup("Sidebar", { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = buf,
		callback = function()
			if state.moving then
				return
			end
			local line = vim.api.nvim_win_get_cursor(0)[1]
			local t = cards.inline_at(line, buf)
			if t and thread_items()[t] then
				local id = thread_items()[t].id
				if state.in_thread and state.thread_current == id then
					return
				end
				state.in_thread, state.thread_current = true, id
				return moved()
			end
			local index = not state.in_thread and cards.index_at(line, buf)
			if index then
				if index == current_index() then
					return
				end
				return select(index)
			end
			render()
		end,
	})
	vim.api.nvim_create_autocmd("WinScrolled", {
		group = group,
		callback = function()
			if vim.api.nvim_win_is_valid(win) and vim.fn.getwininfo(win)[1].leftcol > 0 then
				vim.api.nvim_win_call(win, function()
					vim.fn.winrestview({ leftcol = 0 })
				end)
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimResized", {
		group = group,
		callback = function()
			render()
		end,
	})
	vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = refresh })

	app.on("log", function(entry)
		table.insert(log, entry)
		render()
	end)
	app.on("milites", refresh)
	app.on("legiones", refresh)
	app.on("cohortes", refresh)
	app.on("centuriae", refresh)
	app.on("contubernia", refresh)
	app.on("runtimes", refresh)
	app.on("mandata", refresh)
	app.on("expeditiones", refresh)
	app.on("usage", refresh)
	app.on("reviews", render)
	app.on("merge_requests", render)
	app.on("asks", function()
		follow_ask(app.screen(ConversationScreen))
		render()
	end)
	app.on("transcripts", function(change)
		if change.id == state.current.legio then
			render()
		end
	end)
	app.on("conversation_screens", follow_view)

	refresh()
	require("workspace.legio.presentation.nvim.miles_panel").watch_session_files()
	local merge_requests = app.services().merge_request_process
	if merge_requests:available() then
		vim.uv.new_timer():start(2000, merge_requests.interval * 1000, vim.schedule_wrap(function()
			merge_requests:poll(app.services().roster:all())
		end))
	end
	vim.uv.new_timer():start(5000, 5000, vim.schedule_wrap(function()
		for _, e in ipairs(state.entries.legio or {}) do
			if e.busy then
				return refresh()
			end
		end
	end))
	local anim_ns = vim.api.nvim_create_namespace("sidebar_working")
	local frames = { "", " ·", " · ·", " · · ·" }
	vim.uv.new_timer():start(500, 500, vim.schedule_wrap(function()
		local frame = frames[math.floor(vim.uv.now() / 500) % #frames + 1]
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, anim_ns, 0, -1)
			for t, item in ipairs(thread_items()) do
				local line = item.working and frame ~= "" and cards.inline_line(buf, t)
				if line then
					vim.api.nvim_buf_set_extmark(buf, anim_ns, line - 1, 0, { virt_text = { { frame, "CardBusy" } }, virt_text_pos = "eol", hl_mode = "combine" })
				end
			end
		end
	end))
end

return M

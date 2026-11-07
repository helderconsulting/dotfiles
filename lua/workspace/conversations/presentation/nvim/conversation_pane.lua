local app = require("workspace.workbench.presentation.nvim.app")
local answer = require("workspace.conversations.presentation.nvim.answer_view")
local asks = require("workspace.conversations.presentation.nvim.question_view")
local drafts = require("workspace.conversations.presentation.nvim.drafts")
local link = require("workspace.shared.providers").current().attach_link
local miles_view_mapper = require("workspace.legio.presentation.mappers.miles_view_mapper")
local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")

local M = {}

local win, spacer
local shown = {}
local terminal_focus = nil

local function valid(w)
	return w and vim.api.nvim_win_is_valid(w)
end

local function focused()
	return terminal_focus == true and valid(win) and vim.api.nvim_get_current_win() == win
end

local function editing()
	if not valid(win) then
		return false
	end
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		local cfg = vim.api.nvim_win_get_config(w)
		if cfg.relative ~= "" and cfg.win == win then
			return true
		end
	end
	return false
end

local function window()
	if valid(win) then
		return win
	end
	local lost = win
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if w ~= spacer and vim.api.nvim_win_get_config(w).relative == "" then
			win = w
		end
	end
	if not valid(win) and valid(spacer) then
		vim.api.nvim_set_current_win(spacer)
		vim.cmd("leftabove vnew")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_width(spacer, 2)
	end
	shown.key = nil
	app.state().log.warn("conversation.window.recovered", { lost = lost, now = win, trace = debug.traceback("", 2) })
	return win
end

function M.window()
	return window()
end


local function roster()
	return app.services().roster
end

local function runner()
	return app.services().miles_runner
end

local function miles_view(id)
	return id and roster():get(id) or nil
end

local function running_here()
	return roster():running_in(app.folder())
end

local function target(view)
	local agent = miles_view(view.agent)
	return view.agent and { agent = view.agent, cwd = agent and agent.root, name = agent and agent.name }
end

function M.current()
	return target(app.screen(ConversationScreen))
end

local function set(buf, key)
	local w = window()
	if shown.key == key and vim.api.nvim_win_get_buf(w) == buf then
		return
	end
	shown.key = key
	vim.api.nvim_win_set_buf(w, buf)
	answer.window_options(w)
end

local function keys(buf)
	if vim.b[buf].conversation_keys then
		return
	end
	vim.b[buf].conversation_keys = true
	vim.keymap.set("n", "<leader>m", function()
		local t = M.current()
		if t then
			drafts.compose(t)
		end
	end, { buffer = buf, desc = "write to the agent" })
	vim.keymap.set("n", "<C-c>", function()
		local agent = miles_view(app.screen(ConversationScreen).agent)
		if agent then
			runner():interrupt(agent.id)
		end
	end, { buffer = buf, desc = "interrupt the agent" })
end

local function transcripts()
	return app.services().conversation_transcript
end

local function awaiting(agent)
	return agent
			and roster():awaiting_turn(agent.id, function(text, at)
				return transcripts():received(agent.id, text, at)
			end)
		or nil
end

local function scrolled_up()
	if not valid(win) then
		return false
	end
	local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
	local bottom = vim.api.nvim_win_call(win, function()
		return vim.fn.line("w$")
	end)
	return bottom < last
end

local function indicate(waiting)
	if valid(win) then
		vim.api.nvim_set_option_value("winbar", waiting and " ↓ new message below" or " ", { win = win, scope = "local" })
	end
end

local function displayed()
	local id, turn = (shown.key or ""):match("^(.*)/(%d+)$")
	return id, tonumber(turn)
end

local function record_move()
	app.update_screen(ConversationScreen, function(v)
		return v:moved(app.now(), not scrolled_up())
	end)
end

local function publish()
	local agent, turn = displayed()
	app.update_screen(ConversationScreen, function(v)
		return v:observe({
			focused = focused(),
			editing = editing(),
			scrolled_up = scrolled_up(),
			shown_agent = agent,
			shown_turn = turn,
			waiting = shown.waiting,
			owner_pid = vim.fn.getpid(),
		})
	end)
end

local function show_answer(view)
	local agent = miles_view(view.agent)
	shown.waiting = false
	if view.history then
		return set(asks.history(view.history, win), "history" .. tostring(view.history.at))
	end
	if not view.agent then
		return set(answer.placeholder("select an agent in the sidebar"), "none")
	end
	local transcript = transcripts():get(view.agent)
	if not transcript then
		return set(answer.placeholder("loading…"), "loading")
	end
	local sending = awaiting(agent)
	if sending then
		return set(answer.pending_buffer(sending.text), "pending")
	end
	local n = transcript.count
	if n == 0 then
		return set(answer.placeholder("no turns yet"), "empty")
	end
	local i = math.min(view.turn or n, n)
	shown.waiting = view:follows_latest() and view:holds_view(view.agent, i)
	if shown.waiting then
		return indicate(true)
	end
	local buf = answer.buffer(transcript, i, agent and agent.root, i == n and agent and agent.busy)
	keys(buf)
	set(buf, view.agent .. "/" .. i)
	indicate(ConversationScreen.is_behind(i, n))
	local read = transcripts():seen_through(view.agent, i, agent and agent.activity)
	if agent then
		runner():mark_read(miles_view_mapper.to_mark_read_command(agent.id, read))
	end
end

local function finish_draft()
	shown.key, shown.draft_buf = nil, nil
	app.update_screen(ConversationScreen, function(v)
		v:release()
		v:finish_compose()
	end)
	vim.schedule(M.render)
end

local function draw()
	if shown.terminal or not window() then
		shown.waiting = false
		return
	end
	local view = app.screen(ConversationScreen)
	if view.state == "ask" then
		shown.waiting = false
		local buf = shown.ask == view.ask and vim.api.nvim_win_get_buf(win) or asks.buffer(view.ask, win)
		if buf then
			shown.ask = view.ask
			return set(buf, "ask" .. view.ask)
		end
		return app.update_screen(ConversationScreen, function(v)
			v:settle_ask(true)
		end)
	end
	shown.ask = nil
	shown.waiting = false
	if view.state == "entry" and view.entry and view.entry.kind == "mandatum" then
		local buf = require("workspace.workflow.presentation.nvim.mandatum_view").buffer(view.entry.id)
		if buf then
			return set(buf, "mandatum" .. view.entry.id)
		end
	end
	if view.state == "entry" and view.entry then
		local doc = require("workspace.workflow.presentation.nvim.mandatum_actions").document(view.entry)
		if doc then
			return set(answer.entry_buffer(doc), "entry" .. vim.json.encode(doc))
		end
		return app.update_screen(ConversationScreen, function(v)
			return v:select(v.agent)
		end)
	end
	if view.state == "draft" and view.draft then
		local key = "draft" .. drafts.key(view.draft)
		if shown.key == key and vim.api.nvim_win_get_buf(win) ~= shown.draft_buf then
			return finish_draft()
		elseif shown.key ~= key then
			shown.key = key
			shown.draft_buf = drafts.edit(win, view.draft, finish_draft, { quiet = view.draft.quiet })
		end
		return
	end
	show_answer(view)
end

local rendering = false

function M.render()
	if rendering then
		return
	end
	rendering = true
	local ok, err = pcall(function()
		publish()
		draw()
		publish()
		app.update_screen(ConversationScreen, function(v)
			return v:settle()
		end)
	end)
	rendering = false
	if not ok then
		error(err, 0)
	end
end

local function sync_asks()
	local inquiry = app.services().inquiry
	local sessions = {}
	for i, agent in ipairs(running_here()) do
		sessions[i] = agent.id
	end
	local pending = inquiry:next_for(sessions)
	if pending and not inquiry:can_surface(app.workspace, app.pane) then
		return
	end
	if pending and pending.unseen then
		pending = inquiry:claim(pending.id)
	end
	local view = app.screen(ConversationScreen)
	if pending and view.ask ~= pending.id then
		app.update_screen(ConversationScreen, function(v)
			v:show_ask(pending.id, pending.session)
		end)
		app.focus("conversation")
	elseif not pending and view.state == "ask" then
		app.update_screen(ConversationScreen, function(v)
			v:settle_ask(true)
		end)
	end
end

local function open_search()
	local requested = false
	app.update_screen(ConversationScreen, function(v)
		requested = v:take_search()
		return requested
	end)
	if requested then
		require("workspace.legio.presentation.nvim.miles_panel").find()
	end
end

local function open_pick()
	local pick
	app.update_screen(ConversationScreen, function(v)
		pick = v:take_pick()
		return pick ~= nil
	end)
	require("workspace.legio.presentation.nvim.miles_panel").pick(pick)
end

local function pick_default()
	if app.screen(ConversationScreen).agent then
		return
	end
	local first = running_here()[1]
	if first then
		app.update_screen(ConversationScreen, function(v)
			return not v.agent and v:select(first.id)
		end)
	end
end

function M.slash(line)
	local agent = miles_view(app.screen(ConversationScreen).agent)
	if not agent then
		return vim.notify("select a running agent first", vim.log.levels.WARN)
	end
	shown.terminal = link.run(agent.id, line, window(), function()
		shown.terminal, shown.key = nil, nil
		M.render()
	end)
end

local function add_margin()
	vim.opt.fillchars:append({ vert = " ", eob = " " })
	local main = vim.api.nvim_get_current_win()
	vim.cmd("rightbelow vnew")
	spacer = vim.api.nvim_get_current_win()
	vim.bo.buftype = "nofile"
	vim.bo.bufhidden = "wipe"
	vim.bo.swapfile = false
	vim.bo.modifiable = false
	for option, value in pairs({
		number = false,
		relativenumber = false,
		signcolumn = "no",
		foldcolumn = "0",
		statuscolumn = "",
		cursorline = false,
		winfixwidth = true,
		winbar = " ",
	}) do
		vim.api.nvim_set_option_value(option, value, { win = spacer, scope = "local" })
	end
	vim.api.nvim_win_set_width(spacer, 2)
	vim.api.nvim_set_current_win(main)
	vim.api.nvim_create_autocmd("WinEnter", {
		callback = function()
			if vim.api.nvim_get_current_win() ~= spacer then
				return
			elseif valid(win) then
				vim.api.nvim_set_current_win(win)
			else
				vim.schedule(function()
					vim.api.nvim_set_current_win(window())
				end)
			end
		end,
	})
end

local function watch_close(group)
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = function(ev)
			if tonumber(ev.match) == win then
				app.state().log
					.warn("conversation.window.closed", { win = win, buf = ev.buf, trace = debug.traceback("", 2) })
				app.update_screen(ConversationScreen, function(v)
					return v:vacate()
				end)
			else
				vim.schedule(M.render)
			end
		end,
	})
end

function M.open()
	win = app.main_window()
	ConversationScreen.clock = app.now
	local group = vim.api.nvim_create_augroup("ConversationPane", { clear = true })
	watch_close(group)
	vim.keymap.set("c", "<CR>", function()
		if vim.fn.getcmdtype() == ":" then
			local line = vim.trim(vim.fn.getcmdline())
			local name = line:match("^(%S+)")
			if name and link.is_command(name) then
				vim.schedule(function()
					M.slash(line)
				end)
				return "<C-u><Esc>"
			end
		end
		return "<CR>"
	end, { expr = true, desc = "run slash commands for the agent" })
	add_margin()
	local function mine(change)
		return change.id == app.screen(ConversationScreen).agent
	end
	app.on("conversation_screens", function(change)
		if change.id == app.workspace then
			if change.model and change.model.search then
				open_search()
			end
			if change.model and change.model.pick then
				open_pick()
			end
			M.render()
		end
	end)
	app.on("transcripts", function(change)
		if mine(change) then
			M.render()
		end
	end)
	app.on("milites", function(change)
		local agent = change.record and miles_view(change.id)
		if agent and agent.can_release then
			runner():release(change.id)
		end
		if mine(change) then
			M.render()
		end
		pick_default()
	end)
	vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
		group = group,
		callback = function()
			if terminal_focus == false or not valid(win) or vim.api.nvim_get_current_win() ~= win then
				return
			end
			record_move()
			publish()
			if shown.waiting or shown.draft_buf then
				vim.schedule(M.render)
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			app.update_screen(ConversationScreen, function(v)
				return v:vacate(true)
			end)
		end,
	})
	vim.api.nvim_create_autocmd({ "FocusGained", "FocusLost" }, {
		group = group,
		callback = function(ev)
			terminal_focus = ev.event == "FocusGained"
			vim.schedule(M.render)
		end,
	})
	vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
		group = group,
		callback = function()
			vim.schedule(M.render)
		end,
	})
	vim.api.nvim_create_autocmd({ "BufEnter", "BufLeave" }, {
		group = group,
		callback = function()
			if shown.draft_buf then
				vim.schedule(M.render)
			end
		end,
	})
	app.on("asks", sync_asks)
	local function entry_changed()
		if app.screen(ConversationScreen).state == "entry" then
			M.render()
		end
	end
	app.on("mandata", entry_changed)
	app.on("expeditiones", entry_changed)
	runner():watch_agentd()
	pick_default()
	sync_asks()
	if valid(win) and vim.api.nvim_get_current_win() == win then
		record_move()
	end
	M.render()
end

return M

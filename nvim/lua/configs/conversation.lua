local app = require("configs.app")
local answer = require("configs.answer")
local transcripts = require("configs.transcripts")
local asks = require("configs.asks")
local drafts = require("configs.drafts")
local runner = require("configs.runner")
local link = require("configs.link")

local M = {}

local win
local shown = {}

local function valid(w)
	return w and vim.api.nvim_win_is_valid(w)
end

function M.window()
	return win
end

local function target(view)
	local agent = app.agent(view.agent)
	return view.agent and { agent = view.agent, cwd = agent and agent.root, name = agent and agent:display_name() }
end

function M.current()
	return target(app.view())
end

local function set(buf, key)
	if shown.key == key and vim.api.nvim_win_get_buf(win) == buf then
		return
	end
	shown.key = key
	vim.api.nvim_win_set_buf(win, buf)
	answer.window_options(win)
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
		local agent = app.agent(app.view().agent)
		if agent then
			runner.interrupt(agent)
		end
	end, { buffer = buf, desc = "interrupt the agent" })
end

local function show_answer(view)
	local agent = app.agent(view.agent)
	if view.history then
		return set(asks.history(view.history, win), "history" .. tostring(view.history.at))
	end
	if not view.agent then
		return set(answer.placeholder("select an agent in the sidebar"), "none")
	end
	local transcript = transcripts.get(view.agent)
	if not transcript then
		return set(answer.placeholder("loading…"), "loading")
	end
	local sending = agent and agent:awaiting_turn(transcript, app.now())
	if sending then
		return set(answer.pending_buffer(sending.text), "pending")
	end
	local n = transcript:count()
	if n == 0 then
		return set(answer.placeholder("no turns yet"), "empty")
	end
	local i = math.min(view.turn or n, n)
	local buf = answer.buffer(transcript, i, agent and agent.root, i == n and agent and agent:is_busy())
	keys(buf)
	set(buf, view.agent .. "/" .. i)
	local read = transcript:seen_through(i, agent and agent.activity)
	if agent and not agent:is_read(read) then
		app.store():update(app.models.Agent, agent.id, function(a)
			return a:mark_read(read)
		end)
	end
end

function M.render()
	if not valid(win) or shown.terminal then
		return
	end
	local view = app.view()
	if view.state == "ask" then
		local buf = shown.ask == view.ask and vim.api.nvim_win_get_buf(win) or asks.buffer(view.ask, win)
		if buf then
			shown.ask = view.ask
			return set(buf, "ask" .. view.ask)
		end
		return app.update_view(function(v)
			v:settle_ask(true)
		end)
	end
	shown.ask = nil
	if view.state == "todo" and view.todo then
		local todo = app.store():get(app.models.Todo, view.todo)
		if todo then
			local card = require("configs.todos").card_of(todo)
			return set(answer.todo_buffer(todo, card), "todo" .. todo.id .. vim.json.encode(card) .. todo.text)
		end
		return app.update_view(function(v)
			return v:select(v.agent)
		end)
	end
	if view.state == "draft" and view.draft then
		local key = "draft" .. app.models.Draft.key(view.draft)
		if shown.key ~= key then
			shown.key = key
			drafts.edit(win, view.draft, function()
				shown.key = nil
				app.update_view(function(v)
					v:finish_compose()
				end)
			end, { quiet = view.draft.quiet })
		end
		return
	end
	show_answer(view)
end

local function sync_asks()
	local mine = app.models.Agent.running_in(app.agents(), app.folder())
	local asks = {}
	for _, agent in ipairs(mine) do
		vim.list_extend(asks, agent:pending_asks())
	end
	local pending = app.models.Ask.next_pending(asks, mine, app.now(), function(pid)
		return vim.uv.kill(pid, 0) == 0
	end)
	local view = app.view()
	if pending and view.ask ~= pending.id then
		app.update_view(function(v)
			v:show_ask(pending.id, pending.session)
		end)
		app.focus("conversation")
	elseif not pending and view.state == "ask" then
		app.update_view(function(v)
			v:settle_ask(true)
		end)
	end
end

local function open_search()
	local requested = false
	app.update_view(function(v)
		requested = v:take_search()
		return requested
	end)
	if requested then
		require("configs.agents").find()
	end
end

local function open_pick()
	local pick
	app.update_view(function(v)
		pick = v:take_pick()
		return pick ~= nil
	end)
	require("configs.agents").pick(pick)
end

local function pick_default()
	if app.view().agent then
		return
	end
	local first = app.models.Agent.running_in(app.agents(), app.folder())[1]
	if first then
		app.update_view(function(v)
			return not v.agent and v:select(first.id)
		end)
	end
end

function M.slash(line)
	local agent = app.agent(app.view().agent)
	if not agent then
		return vim.notify("select a running agent first", vim.log.levels.WARN)
	end
	shown.terminal = link.run(agent.id, line, win, function()
		shown.terminal, shown.key = nil, nil
		M.render()
	end)
end

local function add_margin()
	vim.opt.fillchars:append({ vert = " ", eob = " " })
	local main = vim.api.nvim_get_current_win()
	vim.cmd("rightbelow vnew")
	local spacer = vim.api.nvim_get_current_win()
	vim.bo.buftype = "nofile"
	vim.bo.bufhidden = "wipe"
	vim.bo.swapfile = false
	vim.bo.modifiable = false
	for option, value in pairs({ number = false, relativenumber = false, signcolumn = "no", foldcolumn = "0", statuscolumn = "", cursorline = false, winfixwidth = true, winbar = " " }) do
		vim.api.nvim_set_option_value(option, value, { win = spacer, scope = "local" })
	end
	vim.api.nvim_win_set_width(spacer, 2)
	vim.api.nvim_set_current_win(main)
	vim.api.nvim_create_autocmd("WinEnter", {
		callback = function()
			if vim.api.nvim_get_current_win() == spacer and valid(main) then
				vim.api.nvim_set_current_win(main)
			end
		end,
	})
end

function M.open()
	win = app.main_window()
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
	end, { expr = true, desc = "run Claude commands for the agent" })
	add_margin()
	local function mine(change)
		return change.id == app.view().agent
	end
	app.on("views", function(change)
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
	app.on("agents", function(change)
		if change.model and change.model:can_release() then
			require("configs.runner").release(change.id)
		end
		if mine(change) then
			M.render()
		end
		pick_default()
	end)
	app.on("asks", sync_asks)
	app.on("todos", function(change)
		local view = app.view()
		if view.state == "todo" and view.todo == change.id then
			M.render()
		end
	end)
	require("configs.agentd").hold()
	pick_default()
	sync_asks()
	M.render()
end

return M

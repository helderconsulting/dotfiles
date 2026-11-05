local app = require("configs.app")
local runner = require("configs.runner")
local drafts = require("configs.drafts")
local Agent = app.models.Agent
local Session = app.models.Session

local todos = require("configs.todos")

local M = {}

M.empty = "no active sessions"

local cache = {}

local function parse(text, mtime)
	local info = { mtime = mtime }
	local custom, ai
	for line in (text or ""):gmatch("[^\n]+") do
		if not info.cwd and line:sub(1, 7) == '"cwd":"' then
			info.cwd = line:match('^"cwd":"(.*)"$')
		elseif line:sub(1, 1) == "{" then
			local ok, entry = pcall(vim.json.decode, line)
			if ok and type(entry) == "table" then
				custom = entry.customTitle or custom
				ai = entry.aiTitle or ai
			end
		end
	end
	info.title = custom or ai
	return info
end

local function recent(folder, limit, done)
	local files = {}
	for _, path in ipairs(vim.fn.glob(app.paths.claude_projects .. "/" .. folder:gsub("[^%w]", "-") .. "*/*.jsonl", false, true)) do
		local st = vim.uv.fs_stat(path)
		if st then
			table.insert(files, { path = path, mtime = st.mtime.sec, id = vim.fn.fnamemodify(path, ":t:r") })
		end
	end
	table.sort(files, function(a, b)
		return a.mtime > b.mtime
	end)
	files = vim.list_slice(files, 1, limit)
	local stale = vim.tbl_filter(function(f)
		return not cache[f.path] or cache[f.path].mtime ~= f.mtime
	end, files)
	if #stale == 0 then
		return done(files)
	end
	local left = #stale
	for _, f in ipairs(stale) do
		vim.system({ "/usr/bin/grep", "-o", "-E", '"cwd":"[^"]*"|^\\{"type":"(custom-title|ai-title)".*', f.path }, { text = true, env = { LC_ALL = "C" } }, function(res)
			vim.schedule(function()
				cache[f.path] = parse(res.stdout, f.mtime)
				left = left - 1
				if left == 0 then
					done(files)
				end
			end)
		end)
	end
end

function M.card(e)
	if e.todo then
		return e.card
	end
	if not e.agent then
		return e:card()
	end
	return e:card(require("configs.review").counts(e.agent.root))
end

local function sessions(folder, limit, done)
	recent(folder, limit, function(files)
		done(Session.list(app.agents(), files, cache, folder, app.now()))
	end)
end

function M.fetch(folder, done)
	local view = app.view()
	local list = Session.active(app.agents(), folder, app.now(), view.state == "draft" and view.draft or nil)
	vim.list_extend(list, todos.entries(folder))
	done(list)
end

function M.count(list)
	return #vim.tbl_filter(function(e)
		return not e.todo
	end, list)
end

local function warn(ui, why)
	if why and not ui.batch then
		vim.notify(why, vim.log.levels.WARN)
	end
end

function M.enter(e)
	if e.todo then
		return todos.send(e)
	elseif e.drafting then
		return drafts.compose(e:target())
	end
	app.update_view(function(v)
		v:select(e.id)
	end)
	if e:needs_resume() then
		runner.resume(e.id, e.cwd)
	end
end

local function finish(e, ui)
	local ok, why = e:can_end()
	if not ok then
		return warn(ui, why)
	end
	if ui.confirm("end session " .. e.name .. "? it stays resumable") then
		runner.stop(e.agent)
	end
end

local function toggle(e, ui)
	if e:toggle() == "resume" then
		return M.enter(e)
	end
	finish(e, ui)
end

local function interrupt(e, ui)
	local ok, why = e:can_interrupt(app.agent(e.id))
	if not ok then
		return warn(ui, why)
	end
	runner.interrupt(app.agent(e.id))
	if not ui.batch then
		vim.notify("interrupted " .. e.name)
	end
end

local function message(e)
	drafts.compose(e:target())
end

local pickers = {
	new_session = function(p, picker)
		runner.catalog(p.cwd, function(catalog)
			picker.pick(picker.flatten(catalog), { prompt = "new session", header = "Enter picks the model, then the mode" }, function(choice)
				picker.pick(picker.modes("auto"), { prompt = "mode", header = "Enter picks it, then write the task" }, function(mode)
					drafts.compose({ cwd = p.cwd, name = p.name, provider = choice.provider, model = choice.value, mode = mode.value })
				end)
			end)
		end)
	end,
	model = function(p, picker)
		local agent = app.agent(p.agent)
		if not agent then
			return vim.notify(p.name .. " isn't running", vim.log.levels.WARN)
		end
		runner.models(agent, function(catalog)
			picker.pick(picker.flatten(catalog, runner.current(agent)), { prompt = "model for " .. p.name, header = "Enter switches to it" }, function(choice)
				runner.set_model(agent, choice.value, function(ok)
					if ok then
						vim.notify(p.name .. " now uses " .. choice.value)
					end
				end)
			end)
		end)
	end,
	send_todo = function(p, picker)
		require("configs.todos").send_picker(p, picker)
	end,
	mode = function(p, picker)
		local agent = app.agent(p.agent)
		if not agent then
			return vim.notify(p.name .. " isn't running", vim.log.levels.WARN)
		end
		picker.pick(picker.modes(runner.current(agent).mode), { prompt = "mode for " .. p.name, header = "Enter switches to it" }, function(choice)
			runner.set_mode(agent, choice.value, function(ok)
				if ok then
					vim.notify(p.name .. " is now in " .. choice.value .. " mode")
				end
			end)
		end)
	end,
}

function M.pick(p)
	local open = p and pickers[p.kind]
	if open then
		open(p, require("configs.model_picker"))
	end
end

local function request_pick(pick)
	app.update_view(function(v)
		v:request_pick(pick, app.now())
	end)
	app.focus("conversation")
end

local function move_to_sdk(e, ui)
	local ok, why = e:can_move()
	if not ok then
		return warn(ui, why)
	end
	runner.move_to_sdk(app.agent(e.id), function(moved, reason)
		vim.notify(moved and (e.name .. " moved to the sdk") or ("couldn't move " .. e.name .. ": " .. tostring(reason)), moved and vim.log.levels.INFO or vim.log.levels.WARN)
	end)
end

local function switch_mode(e, ui)
	if not (e.agent and e.agent:on_sdk()) then
		return warn(ui, e.name .. " isn't on the sdk, its mode can't change from here")
	end
	request_pick({ kind = "mode", agent = e.id, name = e.name })
end

local function switch_model(e, ui)
	if not (e.agent and app.agent(e.id)) then
		return warn(ui, e.name .. " isn't running")
	end
	request_pick({ kind = "model", agent = e.id, name = e.name })
end

local function rename(e, ui)
	vim.ui.input({ prompt = "rename session: ", default = e.name }, function(name)
		local entry, why = e:rename_entry(name)
		if not entry then
			return warn(ui, why)
		end
		local f = io.open(e.path, "a")
		if f then
			f:write(vim.json.encode(entry), "\n")
			f:close()
		end
		ui.refresh()
	end)
end

local function remove(e, ui)
	local plan, why = e:removal(vim.fn.glob(app.paths.claude_projects .. "/*/" .. e.id .. ".jsonl"))
	if not plan then
		return warn(ui, why)
	end
	if not ui.confirm((plan.stop_first and "stop and delete session " or "delete session ") .. e.name .. "?") then
		return
	end
	local function delete()
		vim.fs.rm(plan.path, { force = true })
		if vim.fn.isdirectory(plan.sidecar) == 1 then
			vim.fs.rm(plan.sidecar, { recursive = true, force = true })
		end
		cache[plan.path] = nil
		ui.refresh()
	end
	if plan.stop_first then
		runner.stop(e.agent, function()
			vim.defer_fn(delete, 500)
		end)
	else
		delete()
	end
end

local search_limit = 200
local tone_colors = { busy = "#A58BD3", ok = "#77DD77", bad = "#E0955A", off = "#8C8C8C" }

local search_actions = {
	{ key = "enter", label = "go there or resume", run = M.enter },
	{ key = "ctrl-x", label = "end", run = finish },
	{ key = "ctrl-t", label = "interrupt", run = interrupt },
	{ key = "ctrl-o", label = "message", run = message },
	{ key = "ctrl-r", label = "rename", run = rename },
	{ key = "ctrl-d", label = "delete", run = remove },
}

local search_ui = {
	confirm = function(question)
		return vim.fn.confirm(question, "&yes\n&no", 2) == 1
	end,
	refresh = function() end,
}

function M.find()
	local folder = app.folder()
	sessions(folder, search_limit, function(list)
		if #list == 0 then
			return vim.notify("no sessions in " .. app.short(folder), vim.log.levels.WARN)
		end
		require("packs.fzf")
		local fzf = require("fzf-lua")
		local utils = require("fzf-lua.utils")
		local width = 4
		for _, e in ipairs(list) do
			width = math.max(width, vim.fn.strdisplaywidth(e.name))
		end
		local lines, by_line = {}, {}
		for _, e in ipairs(list) do
			local word, name, detail = e:search_columns()
			local line = ("%s  %s  %s"):format(
				utils.ansi_from_rgb(tone_colors[e.kind] or tone_colors.off, ("%-8s"):format(word)),
				name .. string.rep(" ", width - vim.fn.strdisplaywidth(name)),
				utils.ansi_from_rgb("#3F6F3F", detail)
			)
			table.insert(lines, line)
			by_line[vim.trim(utils.strip_ansi_coloring(line))] = e
		end
		local legend, actions = { {}, {} }, {}
		for i, a in ipairs(search_actions) do
			table.insert(legend[i <= 3 and 1 or 2], utils.ansi_from_rgb("#77DD77", a.key) .. " " .. a.label)
			actions[a.key] = function(selected)
				local e = selected and selected[1] and by_line[vim.trim(utils.strip_ansi_coloring(selected[1]))]
				if e then
					a.run(e, search_ui)
				end
			end
		end
		fzf.fzf_exec(lines, {
			prompt = "sessions> ",
			fzf_opts = { ["--ansi"] = true, ["--no-sort"] = true, ["--header"] = table.concat(legend[1], "  ·  ") .. "\n" .. table.concat(legend[2], "  ·  ") },
			actions = actions,
		})
	end)
end

local function either(on_session, on_todo)
	return function(e, ui)
		local fn = e.todo and on_todo or not e.todo and on_session
		if not fn then
			return warn(ui, e.todo and "that's a todo, not a session" or "that's a session, not a todo")
		end
		return fn(e, ui)
	end
end

M.groups = {
	{ "<leader>a", "agent" },
	{ "<leader>o", "options" },
	{ "<leader>t", "todo" },
}

M.actions = {
	{
		"<leader>aa",
		function(_, ui)
			local folder = ui.folder()
			request_pick({ kind = "new_session", cwd = folder, name = app.short(folder) })
		end,
		"new session",
		always = true,
	},
	{
		"<leader>af",
		function()
			app.update_view(function(v)
				v:request_search(app.now())
			end)
			app.focus("conversation")
		end,
		"find a session",
		always = true,
	},
	{ "<leader>as", either(toggle), "resume or end" },
	{ "<leader>am", either(message), "message", single = true },
	{ "<leader>ai", either(interrupt), "interrupt" },
	{ "<leader>ar", either(rename), "rename", single = true },
	{ "<leader>au", either(move_to_sdk), "move to the sdk" },
	{ "<leader>ad", either(remove), "delete" },
	{ "<leader>om", either(switch_model), "model", single = true },
	{ "<leader>op", either(switch_mode), "permission mode", single = true },
	{ "<leader>ta", todos.add, "add", always = true },
	{ "<leader>ts", either(nil, todos.send), "send", single = true },
	{ "<leader>te", either(nil, todos.edit), "edit", single = true },
	{ "<leader>tc", either(nil, todos.finish), "complete" },
	{ "<leader>td", either(nil, todos.drop), "drop" },
}

local function registry()
	local fs = require("workspace.nvim").fs
	local entries = {}
	for _, name in ipairs(fs.list(app.paths.claude_sessions)) do
		local ok, entry = pcall(vim.json.decode, (name:match("%.json$") and fs.read(app.paths.claude_sessions .. "/" .. name)) or "")
		if ok and type(entry) == "table" then
			table.insert(entries, entry)
		end
	end
	return app.models.Registry.new(entries, function(pid)
		return vim.uv.kill(pid, 0) == 0
	end)
end

function M.reconcile()
	local reg, store, now = registry(), app.store(), app.now()
	local asking = {}
	local alive = function(pid)
		return pid == nil or vim.uv.kill(pid, 0) == 0
	end
	for _, agent in ipairs(app.agents()) do
		for _, ask in ipairs(agent:pending_asks()) do
			if not ask:is_stale(now, alive(ask.pid)) then
				asking[agent.id] = true
			end
		end
	end
	local known, wait = {}, nil
	for _, agent in ipairs(store:all(Agent)) do
		known[agent.id] = true
		local model = agent
		if reg:needs_reconcile(agent) then
			model = store:update(Agent, agent.id, function(a)
				return reg:reconcile(a, now, asking[a.id])
			end)
		end
		local left = reg:wait(model, now)
		wait = left and math.min(wait or left, left) or wait
	end
	for _, entry in ipairs(reg:untracked(known)) do
		store:update(Agent, entry.sessionId, function(a)
			app.models.Registry.adopt(a, entry, now)
		end)
	end
	return wait
end

function M.watch_registry()
	local debounce, again = vim.uv.new_timer(), vim.uv.new_timer()
	local function run()
		local wait = M.reconcile()
		again:stop()
		if wait then
			again:start(math.ceil(wait * 1000) + 50, 0, vim.schedule_wrap(run))
		end
	end
	local watcher = vim.uv.new_fs_event()
	vim.fn.mkdir(app.paths.claude_sessions, "p")
	watcher:start(app.paths.claude_sessions, {}, function()
		debounce:start(50, 0, vim.schedule_wrap(run))
	end)
	vim.api.nvim_create_autocmd("FocusGained", { callback = run })
	run()
end

return M

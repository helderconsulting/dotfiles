local app = require("configs.app")
local runner = require("configs.runner")

local M = {}

local Todo = app.models.Todo
local Draft = app.models.Draft

local function names()
	local by_id = {}
	for _, a in ipairs(app.agents()) do
		by_id[a.id] = a:display_name()
	end
	return function(id)
		return by_id[id] or (id and id:sub(1, 8)) or "an agent"
	end
end

local function entry(t, name_of, now)
	return { id = t.id, todo = t, name = t:title(), kind = t:tone(), order = t.state == "open" and 10 or 11, card = t:card(name_of, now) }
end

function M.card_of(todo)
	return todo:card(names(), app.now())
end

function M.entries(folder)
	local name_of, now = names(), app.now()
	return vim.tbl_map(function(t)
		return entry(t, name_of, now)
	end, Todo.listed_in(app.store():all(Todo), folder))
end

local function update(id, fn)
	return app.store():update(Todo, id, function(t, created)
		if created then
			return false
		end
		return fn(t, app.now())
	end)
end

function M.create(root, text, from)
	local id = Todo.new_id(math.random)
	while app.store():get(Todo, id) do
		id = Todo.new_id(math.random)
	end
	app.store():update(Todo, id, function(t)
		local fresh = Todo.make(id, text, root, from or "you", app.now())
		for _, f in ipairs(Todo.fields) do
			t[f] = fresh[f]
		end
	end)
	return id
end

function M.save(target, text)
	text = vim.trim(text or "")
	if text == "" then
		return
	end
	if target.todo == true then
		return M.create(target.cwd, text, "you")
	end
	update(target.todo, function(t, now)
		return t:edit(text, now)
	end)
end

function M.add(_, ui)
	local folder = ui.folder()
	require("configs.drafts").compose({ todo = true, cwd = folder, name = "a new todo" })
end

function M.send(e)
	app.update_view(function(v)
		v:request_pick({ kind = "send_todo", todo = e.id, cwd = e.todo.root }, app.now())
	end)
	app.focus("conversation")
end

function M.finish(e)
	update(e.id, function(t, now)
		return t:finish("", now)
	end)
end

function M.drop(e, ui)
	if ui.batch or ui.confirm("drop todo " .. e.name .. "?") then
		update(e.id, function(t, now)
			return t:drop(now)
		end)
	end
end

function M.edit(e)
	local drafts = require("configs.drafts")
	local target = { todo = e.id, cwd = e.todo.root, name = "todo " .. e.id }
	if not drafts.load(target) then
		drafts.write(target, e.todo.text)
	end
	drafts.compose(target)
end

local function deliver(todo, agent, done)
	local draft = Draft.new({ agent = agent.id, cwd = agent.root or agent.cwd, name = agent:display_name() }, todo:message())
	runner.deliver(draft, done)
end

function M.send_picker(p, picker)
	local todo = app.store():get(Todo, p.todo)
	if not (todo and todo:is_listed()) then
		return vim.notify("that todo is gone", vim.log.levels.WARN)
	end
	local agents = app.models.Agent.running_in(app.agents(), p.cwd or app.folder())
	local entries = { { tag = "new", value = "new session", description = "start one with this todo right away" } }
	for _, a in ipairs(agents) do
		table.insert(entries, { tag = a:status(), value = a:display_name(), description = a.worktree or "", agent = a })
	end
	picker.pick(entries, { prompt = "send todo", header = "Enter sends it: " .. todo:title() }, function(choice)
		local function sent(ok, id)
			if ok then
				update(todo.id, function(t, now)
					return t:send(id, now)
				end)
				vim.notify("sent todo to " .. choice.value)
			end
		end
		if choice.agent then
			deliver(todo, choice.agent, function(ok)
				sent(ok, choice.agent.id)
			end)
		else
			runner.start(todo.root, todo:message(), function(ok, id)
				sent(ok, id)
			end)
		end
	end)
end

return M

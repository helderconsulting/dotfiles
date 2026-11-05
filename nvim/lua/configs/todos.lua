local app = require("configs.app")
local runner = require("configs.runner")
local repo = require("workspace.epics")

local M = {}

local Todo, Epic, Draft = app.models.Todo, app.models.Epic, app.models.Draft

local function clock()
	return require("workspace.nvim").clock()
end

function M.names()
	local by_id = {}
	for _, a in ipairs(app.agents()) do
		by_id[a.id] = a:display_name()
	end
	return function(id)
		return by_id[id] or (id and id:sub(1, 8)) or "an agent"
	end
end

function M.listed(folder)
	return repo.listed(app.store(), folder)
end

function M.epic(id)
	return repo.get(app.store(), id)
end

function M.epic_of(todo_id)
	return repo.of_todo(app.store(), todo_id)
end

function M.todo(id)
	local epic = M.epic_of(id)
	return epic and epic:todo(id) or nil
end

function M.create_epic(root, title, from)
	return repo.find_or_create(app.store(), root, title, from or "you", clock()).id
end

function M.create(root, spec, from, epic_id)
	local epic = epic_id and M.epic(epic_id) or repo.find_or_create(app.store(), root, Epic.loose_ends, "you", clock())
	return repo.add(app.store(), epic, spec, from or "you", clock())
end

local function change(todo_id, action, ...)
	return repo.change(app.store(), todo_id, action, ...)
end

function M.save(target, text)
	text = vim.trim(text or "")
	if text == "" then
		return
	end
	if target.epic == true then
		return M.create_epic(target.cwd, text:match("[^\n]+"), "you")
	elseif target.epic then
		return app.store():update(Epic, target.epic, function(e, created)
			if created then
				return false
			end
			e.title = text:match("[^\n]+")
			return true
		end)
	end
	local ok, why = Todo.validate(Todo.parse(text))
	if not ok then
		return false, why
	end
	if target.todo == true then
		return M.create(target.cwd, text, "you", target.in_epic)
	end
	return change(target.todo, "edit", text, app.now())
end

local function compose(target, text)
	local drafts = require("configs.drafts")
	if text and not drafts.load(target) then
		drafts.write(target, text)
	end
	drafts.compose(target)
end

function M.new_epic(folder)
	compose({ epic = true, cwd = folder, name = "a new epic" })
end

function M.add_to(epic_id, folder, text)
	compose({ todo = true, in_epic = epic_id, cwd = folder, name = "a new todo" }, text or Todo.template)
end

function M.edit_epic(epic)
	compose({ epic = epic.id, cwd = epic.root, name = "epic " .. epic.title }, epic.title)
end

function M.finish(todo_id)
	return change(todo_id, "finish", "", app.now())
end

function M.drop(todo_id)
	return change(todo_id, "drop", app.now())
end

function M.drop_epic(epic)
	repo.remove(app.store(), epic, app.now())
end

local documents = {
	todo = function(id)
		local t = M.todo(id)
		return t and t:document(M.names(), app.now())
	end,
	epic = function(id)
		local e = M.epic(id)
		return e and e:document(M.names(), app.now())
	end,
}

function M.document(entry)
	local render = entry and documents[entry.kind]
	return render and render(entry.id)
end

function M.request_send(ids, cwd)
	app.update_view(function(v)
		v:request_pick({ kind = "send_todo", todos = ids, cwd = cwd }, app.now())
	end)
	app.focus("conversation")
end

local function message(todos)
	if #todos == 1 then
		return todos[1]:message()
	end
	local parts = { "Work through these todos in order:" }
	for _, t in ipairs(todos) do
		table.insert(parts, t:message())
	end
	return table.concat(parts, "\n\n")
end

local function free(ids)
	local list = {}
	for _, id in ipairs(ids) do
		local t = M.todo(id)
		if t and t:is_free(app.now()) then
			table.insert(list, t)
		end
	end
	return list
end

local function what_of(todos)
	return #todos == 1 and todos[1]:title() or (#todos .. " todos")
end

local function hand_over(todos, root, agent, launch)
	local what = what_of(todos)
	local assignee = agent and agent.id or app.models.Agent.new_id(math.random)
	todos = vim.tbl_filter(function(t)
		return change(t.id, "assign", assignee, app.now())
	end, todos)
	if #todos == 0 then
		return vim.notify(what .. " was just sent from somewhere else", vim.log.levels.WARN)
	end
	local function sent(ok, id)
		for _, t in ipairs(todos) do
			if ok then
				change(t.id, "send", id or assignee, app.now(), assignee)
			else
				change(t.id, "release", assignee, app.now())
			end
		end
		if not ok then
			return
		end
		if id then
			local title = Todo.session_title(todos, function(epic_id)
				local e = M.epic(epic_id)
				return e and e.title
			end)
			app.store():update(app.models.Agent, id, function(a, created)
				if created then
					return false
				end
				a.title = title
			end)
			if not agent then
				app.update_view(function(v)
					return v:select(id)
				end)
			end
		end
		vim.notify("sent " .. what .. " to " .. (agent and agent:display_name() or "a new session"))
	end
	if agent then
		runner.deliver(Draft.new({ agent = agent.id, cwd = agent.root or agent.cwd, name = agent:display_name() }, message(todos)), function(ok)
			sent(ok, agent.id)
		end)
	else
		runner.start(root, message(todos), sent, vim.tbl_extend("force", launch or {}, { id = assignee }))
	end
end

local function nothing_free()
	vim.notify("nothing left to send there, an agent already has it", vim.log.levels.WARN)
end

function M.send_picker(p, picker)
	local todos = free(p.todos or { p.todo })
	if #todos == 0 then
		return nothing_free()
	end
	local root = p.cwd or todos[1].root
	local entries = { { tag = "new", value = "new session", description = "start one with it right away" } }
	for _, a in ipairs(app.models.Agent.running_in(app.agents(), root)) do
		table.insert(entries, { tag = a:status(), value = a:display_name(), description = a.worktree or "", agent = a })
	end
	picker.pick(entries, { prompt = "send", header = "Enter sends " .. what_of(todos) }, function(choice)
		hand_over(todos, root, choice.agent)
	end)
end

function M.start_new(ids, root, launch)
	local todos = free(ids)
	if #todos == 0 then
		return nothing_free()
	end
	hand_over(todos, root or todos[1].root, nil, launch)
end

function M.titles(ids)
	return what_of(vim.tbl_filter(function(t)
		return t ~= nil
	end, vim.tbl_map(M.todo, ids)))
end

return M

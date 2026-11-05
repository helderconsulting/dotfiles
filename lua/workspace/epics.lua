local models = require("workspace.models")
local nvim = require("workspace.nvim")
local Epic, Todo = models.Epic, models.Todo

local M = {}

local function new_id(store, cls)
	local id = cls.new_id(math.random)
	while store:get(cls, id) do
		id = cls.new_id(math.random)
	end
	return id
end

local function put(store, cls, model)
	store:update(cls, model.id, function(x)
		for _, f in ipairs(cls.fields) do
			x[f] = model[f]
		end
	end)
end

function M.all(store)
	local todos = store:all(Todo)
	local out = {}
	for _, e in ipairs(store:all(Epic)) do
		table.insert(out, e:attach(todos))
	end
	return out
end

function M.listed(store, folder)
	return Epic.listed_in(M.all(store), folder)
end

function M.get(store, id)
	local e = id and store:get(Epic, id)
	return e and e:attach(store:all(Todo)) or nil
end

function M.of_todo(store, todo_id)
	local t = todo_id and store:get(Todo, todo_id)
	return t and M.get(store, t.epic) or nil
end

function M.find_or_create(store, root, title, from, now)
	root = nvim.repo_root(root)
	local found = Epic.find(store:all(Epic), root, title)
	if found then
		return M.get(store, found.id)
	end
	local epic = Epic.make(new_id(store, Epic), title, root, from or "you", now)
	put(store, Epic, epic)
	return epic:attach({})
end

function M.add(store, epic, spec, from, now)
	local todo = epic:new_todo(new_id(store, Todo), spec, from or "you", now)
	put(store, Todo, todo)
	return todo.id
end

function M.change(store, todo_id, action, ...)
	local args = { ... }
	local ok, why
	store:update(Todo, todo_id, function(t, created)
		if created then
			why = "no todo " .. tostring(todo_id)
			return false
		end
		local epic = M.get(store, t.epic) or Epic.make(t.epic, Epic.loose_ends, t.root, "you", t.created)
		epic.list = epic.list or {}
		for i, other in ipairs(epic.list) do
			if other.id == t.id then
				epic.list[i] = t
			end
		end
		if not epic:todo(t.id) then
			table.insert(epic.list, t)
		end
		ok, why = epic[action](epic, todo_id, unpack(args))
		return ok
	end)
	return ok, why
end

function M.remove(store, epic, now)
	for _, t in ipairs(epic:todos()) do
		M.change(store, t.id, "drop", now)
	end
	store:remove(Epic, epic.id)
end

function M.open_todos(store, root)
	root = nvim.repo_root(root)
	local list = {}
	for _, e in ipairs(M.all(store)) do
		if e.root == root then
			for _, t in ipairs(e:todos()) do
				if t:is_listed() then
					table.insert(list, t)
				end
			end
		end
	end
	return list
end

return M

local app = require("configs.app")
local todos = require("configs.todos")

local M = {}

M.name = "epic"

function M.fetch(folder, done)
	local name_of, now = todos.names(), app.now()
	local list = {}
	for i, epic in ipairs(todos.listed(folder)) do
		table.insert(list, {
			id = epic.id,
			component = M,
			epic = epic,
			name = epic.title,
			kind = epic:tone(),
			order = 100 + i,
			card = epic:card(name_of, now),
		})
	end
	done(list)
end

function M.card(e)
	return e.card
end

function M.thread(e)
	return e.epic:thread(todos.names(), app.now())
end

local function show(kind, id)
	if app.view():show_entry(kind, id) then
		app.update_view(function(v)
			return v:show_entry(kind, id)
		end)
	end
end

function M.follow(e, item)
	if item and item.todo then
		return show("todo", item.todo.id)
	end
	show("epic", e.id)
end

function M.enter() end

function M.escape()
	return false
end

local function warn(ui, why)
	if not ui.batch then
		vim.notify(why, vim.log.levels.WARN)
	end
end

local function selected_epic(e)
	return e and e.component == M and e.epic or nil
end

local function add(e, ui)
	local epic = selected_epic(e)
	todos.add_to(epic and epic.id, ui.folder())
end

local function new_epic(_, ui)
	todos.new_epic(ui.folder())
end

local function send(e, _, item)
	if item and item.todo then
		return todos.request_send({ item.todo.id }, e.epic.root)
	end
	local waiting = e.epic:waiting()
	if #waiting == 0 then
		return vim.notify("nothing in " .. e.name .. " is waiting to be picked up", vim.log.levels.WARN)
	end
	todos.request_send(waiting, e.epic.root)
end

local function edit(e, _, item)
	if item and item.todo then
		show("todo", item.todo.id)
		return app.focus("conversation")
	end
	todos.edit_epic(e.epic)
end

local function complete(e, ui, item)
	if not (item and item.todo) then
		return warn(ui, "open " .. e.name .. " and pick the todo that's done")
	end
	todos.finish(item.todo.id)
end

local function drop(e, ui, item)
	if item and item.todo then
		if ui.batch or ui.confirm("drop todo " .. item.todo:title() .. "?") then
			todos.drop(item.todo.id)
		end
		return
	end
	if ui.batch or ui.confirm("drop epic " .. e.name .. " and its todos?") then
		todos.drop_epic(e.epic)
	end
end

M.groups = {
	{ "<leader>t", "todo" },
}

M.actions = {
	{ "<leader>ta", add, "add a todo", always = true },
	{ "<leader>tn", new_epic, "new epic", always = true },
	{ "<leader>ts", send, "send", single = true },
	{ "<leader>te", edit, "edit", single = true },
	{ "<leader>tc", complete, "complete", single = true },
	{ "<leader>td", drop, "drop" },
}

return M

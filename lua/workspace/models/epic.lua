local Model = require("workspace.model")
local format = require("workspace.format")
local ItemThread = require("workspace.models.item_thread")
local Todo = require("workspace.models.todo")

local Epic = Model.extend({
	kind = "epics",
	fields = { "id", "title", "root", "from", "created" },
})

Epic.loose_ends = "loose ends"

local tones = { todo = "off", ["in progress"] = "busy", done = "ok" }
local marks = { done = "[x]", ["in progress"] = "[~]", todo = "[ ]" }

function Epic.make(id, title, root, from, at)
	return Epic:new({ id = id, title = title, root = root, from = from, created = at })
end

function Epic.new_id(random)
	return ("e%04x"):format(random(0, 0xffff))
end

function Epic:attach(all)
	self.list = {}
	for _, t in ipairs(all or {}) do
		if t.epic == self.id and t:counts() then
			table.insert(self.list, t)
		end
	end
	table.sort(self.list, Todo.before)
	return self
end

function Epic:todos()
	return self.list or {}
end

function Epic:todo(id)
	for _, t in ipairs(self:todos()) do
		if t.id == id then
			return t
		end
	end
end

function Epic:progress()
	local p = { total = #self:todos(), done = 0, ["in progress"] = 0, todo = 0 }
	for _, t in ipairs(self:todos()) do
		p[t:status()] = (p[t:status()] or 0) + 1
	end
	return p
end

function Epic:status()
	local p = self:progress()
	if p.total > 0 and p.done == p.total then
		return "done"
	elseif p["in progress"] > 0 or p.done > 0 then
		return "in progress"
	end
	return "todo"
end

function Epic:is_finished()
	return self:status() == "done"
end

function Epic:tone()
	return tones[self:status()]
end

function Epic:waiting()
	local ids = {}
	for _, t in ipairs(self:todos()) do
		if t.state == "open" then
			table.insert(ids, t.id)
		end
	end
	return ids
end

function Epic.listed_in(epics, folder)
	local out = {}
	for _, e in ipairs(epics) do
		if format.inside(folder, e.root) and not e:is_finished() then
			table.insert(out, e)
		end
	end
	table.sort(out, function(a, b)
		return (a.created or 0) < (b.created or 0)
	end)
	return out
end

function Epic.find(epics, root, title)
	for _, e in ipairs(epics) do
		if e.root == root and e.title == title then
			return e
		end
	end
end

function Epic:new_todo(id, spec, from, at)
	local todo = Todo.make(id, spec, self.root, from, at, self.id)
	self.list = self:todos()
	table.insert(self.list, todo)
	return todo
end

local function on_todo(self, id, fn)
	local t = self:todo(id)
	if not t then
		return false, "no todo " .. tostring(id) .. " in " .. tostring(self.title)
	end
	return fn(t)
end

function Epic:assign(id, agent, at)
	return on_todo(self, id, function(t)
		return t:assign(agent, at)
	end)
end

function Epic:release(id, agent, at)
	return on_todo(self, id, function(t)
		return t:release(agent, at)
	end)
end

function Epic:send(id, agent, at, assigned_as)
	return on_todo(self, id, function(t)
		return t:send(agent, at, assigned_as)
	end)
end

function Epic:finish(id, note, at)
	return on_todo(self, id, function(t)
		return t:finish(note or "", at)
	end)
end

function Epic:drop(id, at)
	return on_todo(self, id, function(t)
		return t:drop(at)
	end)
end

function Epic:amend(id, changes, at)
	return on_todo(self, id, function(t)
		return t:amend(changes, at)
	end)
end

function Epic:edit(id, text, at)
	return on_todo(self, id, function(t)
		return t:edit(text, at)
	end)
end

function Epic:card(name_of, now)
	local p = self:progress()
	local who = self.from and self.from ~= "you" and name_of(self.from) or "you"
	local counts = {}
	for _, s in ipairs({ "in progress", "todo" }) do
		if p[s] > 0 then
			table.insert(counts, p[s] .. " " .. s)
		end
	end
	local fraction = p.total > 0 and p.done / p.total or 0
	return {
		self.title,
		"epic · from " .. who .. " · " .. format.age(self.created, now),
		self:status() .. " · " .. p.done .. " of " .. p.total .. " done",
		{ fraction = fraction, percent = ("%d%%"):format(math.floor(fraction * 100 + 0.5)), label = table.concat(counts, " · ") },
	}
end

function Epic:document(name_of, now)
	local card = self:card(name_of, now)
	local lines = { "# " .. self.title, "" }
	for _, t in ipairs(self:todos()) do
		local c = t:card(name_of, now)
		table.insert(lines, ("- %s %s  _%s · %s_"):format(marks[t:status()] or "[ ]", t:title(), c[1], c[3]))
	end
	if #self:todos() == 0 then
		table.insert(lines, "_no todos yet_")
	end
	return { header = card[2] .. " · " .. card[3], lines = lines }
end

function Epic:thread(name_of, now)
	local list, next_up = {}, nil
	for _, t in ipairs(self:todos()) do
		table.insert(list, { id = t.id, todo = t, kind = t:tone(), card = t:card(name_of, now) })
		if not next_up and t.state ~= "done" then
			next_up = t.id
		end
	end
	return ItemThread.new(list, { entry = next_up })
end

return Epic

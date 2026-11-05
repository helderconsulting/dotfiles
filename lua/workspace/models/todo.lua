local Model = require("workspace.model")
local format = require("workspace.format")

local Todo = Model.extend({
	kind = "todos",
	fields = { "id", "state", "text", "root", "from", "created", "agent", "sent_at", "done_at", "note" },
	machine = {
		initial = "open",
		states = {
			open = { send = "sent", finish = "done", drop = "dropped", edit = "open" },
			sent = { send = "sent", finish = "done", drop = "dropped", reopen = "open", edit = "sent" },
			done = { reopen = "open" },
			dropped = { reopen = "open" },
		},
	},
})

Todo.done_command = "~/.config/wezterm/bin/todo"

local listed = { open = true, sent = true }
local tones = { open = "off", sent = "busy" }

function Todo.make(id, text, root, from, at)
	return Todo:new({ id = id, text = text, root = root, from = from, created = at })
end

function Todo.new_id(random)
	return ("%04x"):format(random(0, 0xffff))
end

function Todo.listed_in(todos, folder)
	local out = {}
	for _, t in ipairs(todos) do
		if t:is_listed() and format.inside(folder, t.root) then
			table.insert(out, t)
		end
	end
	table.sort(out, function(a, b)
		if (a.state == "open") ~= (b.state == "open") then
			return a.state == "open"
		end
		return (a.created or 0) > (b.created or 0)
	end)
	return out
end

function Todo:is_listed()
	return listed[self.state] == true
end

function Todo:title()
	return (self.text or ""):match("[^\n]+") or ""
end

function Todo:tone()
	return tones[self.state] or "off"
end

function Todo:send(agent, at)
	if not self:transition("send", at) then
		return false
	end
	self.agent, self.sent_at = agent, at
	return true
end

function Todo:finish(note, at)
	if not self:transition("finish", at) then
		return false
	end
	self.done_at, self.note = at, note ~= "" and note or nil
	return true
end

function Todo:drop(at)
	return self:transition("drop", at)
end

function Todo:edit(text, at)
	if not text or text == "" or text == self.text or not self:transition("edit", at) then
		return false
	end
	self.text = text
	return true
end

function Todo:message()
	return self.text .. ("\n\n(todo %s: when it's done, run `%s done %s \"<what you did>\"`)"):format(self.id, Todo.done_command, self.id)
end

function Todo:card(name_of, now)
	local who = self.from and self.from ~= "you" and name_of(self.from) or "you"
	local word = self.state == "sent" and ("sent to " .. name_of(self.agent) .. " · " .. format.age(self.sent_at, now)) or ("open · " .. format.age(self.created, now))
	return { self:title(), "todo · from " .. who, word }
end

return Todo

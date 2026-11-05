local Model = require("workspace.model")
local format = require("workspace.format")

local Todo = Model.extend({
	kind = "todos",
	fields = { "id", "state", "text", "root", "from", "created", "assignee", "assigned_at", "sent_at", "done_at", "note", "epic", "headline", "description", "criteria" },
	machine = {
		initial = "open",
		states = {
			open = { assign = "assigned", send = "sent", finish = "done", drop = "dropped", edit = "open" },
			assigned = { assign = "assigned", send = "sent", release = "open", finish = "done", drop = "dropped", edit = "assigned" },
			sent = { finish = "done", drop = "dropped", reopen = "open", edit = "sent" },
			done = { reopen = "open" },
			dropped = { reopen = "open" },
		},
	},
})

Todo.done_command = "~/.config/wezterm/bin/todo"

local listed = { open = true, assigned = true, sent = true }
local tones = { open = "off", assigned = "busy", sent = "busy", done = "ok" }
local statuses = { open = "todo", assigned = "in progress", sent = "in progress", done = "done" }
local ranks = { open = 1, assigned = 2, sent = 2, done = 3 }

Todo.assign_timeout = 300

function Todo:init(data)
	self.assignee = self.assignee or data.agent
	self._extra.agent = nil
end

Todo.description_limit = 300
Todo.criteria_heading = "## Acceptance criteria"
Todo.template = "# \n\n\n\n" .. Todo.criteria_heading .. "\n- Given , when , then \n"

local function trim(s)
	return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Todo.parse(text)
	local spec, section, description = { criteria = {} }, "head", {}
	for raw in ((text or "") .. "\n"):gmatch("(.-)\n") do
		local line = trim(raw)
		if section == "head" and line ~= "" then
			spec.title = trim(line:gsub("^#+%s*", ""))
			section = "description"
		elseif section == "description" and line:lower():match("^#+%s*acceptance criteria") then
			section = "criteria"
		elseif section == "description" then
			table.insert(description, line)
		elseif section == "criteria" and line ~= "" then
			table.insert(spec.criteria, trim(line:gsub("^[-*]%s*", "")))
		end
	end
	spec.description = trim(table.concat(description, "\n"))
	return spec
end

function Todo.is_scenario(line)
	local given, when, thn = (line or ""):lower():match("^given%s+(.-)[,%s]+when%s+(.-)[,%s]+then%s+(.-)%s*$")
	local function said(part)
		return part ~= nil and part:match("%w") ~= nil
	end
	return said(given) and said(when) and said(thn)
end

function Todo.validate(spec)
	if trim(spec.title) == "" then
		return false, "a todo needs a title"
	elseif trim(spec.description) == "" then
		return false, "a todo needs a short, plain description"
	elseif #spec.description > Todo.description_limit then
		return false, ("keep the description under %d characters, put the detail in the acceptance criteria"):format(Todo.description_limit)
	elseif #(spec.criteria or {}) == 0 then
		return false, "a todo needs at least one acceptance criterion: Given …, when …, then …"
	end
	for _, c in ipairs(spec.criteria) do
		if not Todo.is_scenario(c) then
			return false, "write each acceptance criterion as Given …, when …, then …: " .. c
		end
	end
	return true
end

function Todo.render(spec)
	local lines = { "# " .. trim(spec.title), "", trim(spec.description), "", Todo.criteria_heading }
	for _, c in ipairs(spec.criteria or {}) do
		table.insert(lines, "- " .. c)
	end
	return table.concat(lines, "\n")
end

function Todo.make(id, spec, root, from, at, epic)
	local fields = type(spec) == "table" and spec or Todo.parse(spec)
	local t = Todo:new({ id = id, root = root, from = from, created = at, epic = epic })
	t:specify(fields)
	return t
end

function Todo:specify(spec)
	self.headline, self.description, self.criteria = trim(spec.title), trim(spec.description), spec.criteria or {}
	self.text = Todo.render(spec)
end

function Todo:spec()
	return { title = self:title(), description = self.description or "", criteria = self.criteria or {} }
end

function Todo:is_specified()
	return Todo.validate(self:spec())
end

function Todo:amend(changes, at)
	local spec = self:spec()
	for _, key in ipairs({ "title", "description", "criteria" }) do
		if changes[key] ~= nil then
			spec[key] = changes[key]
		end
	end
	local ok, why = Todo.validate(spec)
	if not ok then
		return false, why
	end
	if not self:transition("edit", at) then
		return false, "a " .. self:status() .. " todo can't be changed"
	end
	self:specify(spec)
	return true
end

function Todo.new_id(random)
	return ("%04x"):format(random(0, 0xffff))
end

function Todo:is_free(now)
	return self.state == "open" or (self.state == "assigned" and now - (self.assigned_at or 0) >= Todo.assign_timeout)
end

function Todo:is_listed()
	return listed[self.state] == true
end

function Todo:title()
	if self.headline and self.headline ~= "" then
		return self.headline
	end
	return trim(((self.text or ""):match("[^\n]+") or ""):gsub("^#+%s*", ""))
end

function Todo.session_title(todos, epic_title)
	local first = todos[1]
	if #todos == 1 then
		return first:title()
	end
	for _, t in ipairs(todos) do
		if t.epic ~= first.epic then
			return ("%s and %d more"):format(first:title(), #todos - 1)
		end
	end
	return epic_title(first.epic) or first:title()
end

function Todo:tone()
	return tones[self.state] or "off"
end

function Todo:status()
	return statuses[self.state] or self.state
end

function Todo.before(a, b)
	local ra, rb = ranks[a.state] or 4, ranks[b.state] or 4
	if ra ~= rb then
		return ra < rb
	end
	return (a.created or 0) < (b.created or 0)
end

function Todo:counts()
	return self.state ~= "dropped"
end

function Todo:assign(agent, at)
	if not (agent and self:is_free(at)) then
		return false
	end
	self:transition("assign", at)
	self.assignee, self.assigned_at = agent, at
	return true
end

function Todo:is_assigned_to(agent)
	return self.assignee ~= nil and self.assignee == agent
end

function Todo:release(agent, at)
	if not (self:is_assigned_to(agent) and self:transition("release", at)) then
		return false
	end
	self.assignee, self.assigned_at = nil, nil
	return true
end

function Todo:send(agent, at, assigned_as)
	if self.state == "assigned" and not self:is_assigned_to(assigned_as or agent) then
		return false
	end
	if not self:transition("send", at) then
		return false
	end
	self.assignee, self.sent_at = agent, at
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
	local spec = Todo.parse(text)
	return self:amend({ title = spec.title, description = spec.description, criteria = spec.criteria }, at)
end

function Todo:message()
	return self.text .. ("\n\n(todo %s: when it's done, run `%s done %s \"<what you did>\"`)"):format(self.id, Todo.done_command, self.id)
end

function Todo:who(name_of)
	if self.state == "open" then
		return "from " .. (self.from and self.from ~= "you" and name_of(self.from) or "you")
	elseif self.state == "assigned" then
		return "sending to " .. name_of(self.assignee)
	end
	return name_of(self.assignee)
end

function Todo:document(name_of, now)
	local card = self:card(name_of, now)
	local lines = {}
	for line in ((self.text or "") .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	if not self:is_specified() then
		table.insert(lines, "")
		table.insert(lines, "_needs a description and acceptance criteria, amend it with `" .. Todo.done_command .. " amend " .. self.id .. "`_")
	end
	if self.state == "done" and self.note then
		table.insert(lines, "")
		table.insert(lines, "done: " .. self.note)
	end
	return { header = "todo · " .. card[1] .. " · " .. card[3], lines = lines }
end

function Todo:card(name_of, now)
	local when = self.state == "done" and self.done_at or self.state == "sent" and self.sent_at or self.state == "assigned" and self.assigned_at or self.created
	local detail = self:who(name_of) .. " · " .. format.age(when, now)
	if self.state ~= "done" and not self:is_specified() then
		detail = detail .. " · needs details"
	end
	if self.state == "done" and self.note then
		detail = detail .. " · " .. self.note
	end
	return { self:status(), self:title(), detail }
end

return Todo

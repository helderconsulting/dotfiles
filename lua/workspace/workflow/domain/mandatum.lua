local Model = require("workspace.shared.lib.model")

local Mandatum = Model.extend({
	kind = "mandata",
	fields = { "id", "state", "text", "root", "from", "created", "assignee", "assigned_at", "sent_at", "done_at", "note", "expeditio", "headline", "description", "criteria" },
	machine = {
		initial = "open",
		states = {
			open = { assign = "assigned", send = "sent", finish = "done", drop = "dropped", edit = "open" },
			assigned = { assign = "assigned", send = "sent", release = "open", reassign = "assigned", finish = "done", drop = "dropped", edit = "assigned" },
			sent = { reassign = "sent", finish = "done", drop = "dropped", reopen = "open", edit = "sent" },
			done = { reopen = "open" },
			dropped = { reopen = "open" },
		},
	},
})

Mandatum.done_command = "~/.config/wezterm/bin/todo"

local listed = { open = true, assigned = true, sent = true }
local tones = { open = "off", assigned = "busy", sent = "busy", done = "ok" }
local statuses = { open = "open", assigned = "in progress", sent = "in progress", done = "done" }
local ranks = { open = 1, assigned = 2, sent = 2, done = 3 }

Mandatum.assign_timeout = 300

function Mandatum:init(data)
	self.assignee = self.assignee or data.agent
	self.expeditio = self.expeditio or data.epic
	self._extra.agent = nil
	self._extra.epic = nil
end

Mandatum.description_limit = 300
Mandatum.criteria_heading = "## Acceptance criteria"
Mandatum.template = "# \n\n\n\n" .. Mandatum.criteria_heading .. "\n- Given , when , then \n"

local function trim(s)
	return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Mandatum.parse(text)
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

function Mandatum.is_scenario(line)
	local given, when, thn = (line or ""):lower():match("^given%s+(.-)[,%s]+when%s+(.-)[,%s]+then%s+(.-)%s*$")
	local function said(part)
		return part ~= nil and part:match("%w") ~= nil
	end
	return said(given) and said(when) and said(thn)
end

function Mandatum.validate(spec)
	if trim(spec.title) == "" then
		return false, "a mandatum needs a title"
	elseif trim(spec.description) == "" then
		return false, "a mandatum needs a short, plain description"
	elseif #spec.description > Mandatum.description_limit then
		return false, ("keep the description under %d characters, put the detail in the acceptance criteria"):format(Mandatum.description_limit)
	elseif #(spec.criteria or {}) == 0 then
		return false, "a mandatum needs at least one acceptance criterion: Given …, when …, then …"
	end
	for _, c in ipairs(spec.criteria) do
		if not Mandatum.is_scenario(c) then
			return false, "write each acceptance criterion as Given …, when …, then …: " .. c
		end
	end
	return true
end

function Mandatum.render(spec)
	local lines = { "# " .. trim(spec.title), "", trim(spec.description), "", Mandatum.criteria_heading }
	for _, c in ipairs(spec.criteria or {}) do
		table.insert(lines, "- " .. c)
	end
	return table.concat(lines, "\n")
end

function Mandatum.make(id, spec, root, from, at, expeditio)
	local fields = type(spec) == "table" and spec or Mandatum.parse(spec)
	local t = Mandatum:new({ id = id, root = root, from = from, created = at, expeditio = expeditio })
	t:specify(fields)
	return t
end

function Mandatum:specify(spec)
	self.headline, self.description, self.criteria = trim(spec.title), trim(spec.description), spec.criteria or {}
	self.text = Mandatum.render(spec)
end

function Mandatum:spec()
	return { title = self:title(), description = self.description or "", criteria = self.criteria or {} }
end

function Mandatum:is_specified()
	return Mandatum.validate(self:spec())
end

function Mandatum:amend(changes, at)
	local spec = self:spec()
	for _, key in ipairs({ "title", "description", "criteria" }) do
		if changes[key] ~= nil then
			spec[key] = changes[key]
		end
	end
	local ok, why = Mandatum.validate(spec)
	if not ok then
		return false, why
	end
	if not self:transition("edit", at) then
		return false, "a " .. self:status() .. " mandatum can't be changed"
	end
	self:specify(spec)
	return true
end

function Mandatum.new_id(random)
	return ("%04x"):format(random(0, 0xffff))
end

function Mandatum:is_free(now)
	return self.state == "open" or (self.state == "assigned" and now - (self.assigned_at or 0) >= Mandatum.assign_timeout)
end

function Mandatum:is_listed()
	return listed[self.state] == true
end

function Mandatum:title()
	if self.headline and self.headline ~= "" then
		return self.headline
	end
	return trim(((self.text or ""):match("[^\n]+") or ""):gsub("^#+%s*", ""))
end

function Mandatum.session_title(mandata, expeditio_title)
	local first = mandata[1]
	if #mandata == 1 then
		return first:title()
	end
	for _, t in ipairs(mandata) do
		if t.expeditio ~= first.expeditio then
			return ("%s and %d more"):format(first:title(), #mandata - 1)
		end
	end
	return expeditio_title(first.expeditio) or first:title()
end

function Mandatum:tone()
	return tones[self.state] or "off"
end

function Mandatum:status()
	return statuses[self.state] or self.state
end

function Mandatum.before(a, b)
	local ra, rb = ranks[a.state] or 4, ranks[b.state] or 4
	if ra ~= rb then
		return ra < rb
	end
	return (a.created or 0) < (b.created or 0)
end

function Mandatum:counts()
	return self.state ~= "dropped"
end

function Mandatum:assign(agent, at)
	if not (agent and self:is_free(at)) then
		return false
	end
	self:transition("assign", at)
	self.assignee, self.assigned_at = agent, at
	return true
end

function Mandatum:is_assigned_to(agent)
	return self.assignee ~= nil and self.assignee == agent
end

function Mandatum.in_progress_for(mandata, agent)
	local out = {}
	for _, t in ipairs(mandata or {}) do
		if t.state == "sent" and t:is_assigned_to(agent) then
			table.insert(out, t)
		end
	end
	table.sort(out, function(a, b)
		return (a.sent_at or 0) < (b.sent_at or 0)
	end)
	return out
end

function Mandatum:release(agent, at)
	if not (self:is_assigned_to(agent) and self:transition("release", at)) then
		return false
	end
	self.assignee, self.assigned_at = nil, nil
	return true
end

function Mandatum:reassign(from, to, at)
	if not (to and self:is_assigned_to(from) and self:transition("reassign", at)) then
		return false
	end
	self.assignee = to
	return true
end

function Mandatum:send(agent, at, assigned_as)
	if self.state == "assigned" and not self:is_assigned_to(assigned_as or agent) then
		return false
	end
	if not self:transition("send", at) then
		return false
	end
	self.assignee, self.sent_at = agent, at
	return true
end

function Mandatum:finish(note, at)
	if not self:transition("finish", at) then
		return false
	end
	self.done_at, self.note = at, note ~= "" and note or nil
	return true
end

function Mandatum:drop(at)
	return self:transition("drop", at)
end

function Mandatum:edit(text, at)
	local spec = Mandatum.parse(text)
	return self:amend({ title = spec.title, description = spec.description, criteria = spec.criteria }, at)
end

function Mandatum:message()
	return self.text .. ("\n\n(mandatum %s: when it's done, run `%s done %s \"<what you did>\"`)"):format(self.id, Mandatum.done_command, self.id)
end

return Mandatum

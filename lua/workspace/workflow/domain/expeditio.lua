local Model = require("workspace.shared.lib.model")
local format = require("workspace.shared.lib.format")
local Mandatum = require("workspace.workflow.domain.mandatum")

local Expeditio = Model.extend({
	kind = "expeditiones",
	fields = { "id", "title", "root", "from", "created" },
})

Expeditio.loose_ends = "loose ends"

local tones = { open = "off", ["in progress"] = "busy", done = "ok" }

function Expeditio.make(id, title, root, from, at)
	return Expeditio:new({ id = id, title = title, root = root, from = from, created = at })
end

function Expeditio.new_id(random)
	return ("e%04x"):format(random(0, 0xffff))
end

function Expeditio:hydrate(all)
	self.list = {}
	for _, t in ipairs(all or {}) do
		if t.expeditio == self.id and t:counts() then
			table.insert(self.list, t)
		end
	end
	table.sort(self.list, Mandatum.before)
	return self
end

function Expeditio:mandata()
	return self.list or {}
end

function Expeditio:mandatum(id)
	for _, t in ipairs(self:mandata()) do
		if t.id == id then
			return t
		end
	end
end

function Expeditio:progress()
	local p = { total = #self:mandata(), done = 0, ["in progress"] = 0, open = 0 }
	for _, t in ipairs(self:mandata()) do
		p[t:status()] = (p[t:status()] or 0) + 1
	end
	return p
end

function Expeditio:status()
	local p = self:progress()
	if p.total > 0 and p.done == p.total then
		return "done"
	elseif p["in progress"] > 0 or p.done > 0 then
		return "in progress"
	end
	return "open"
end

function Expeditio:is_finished()
	return self:status() == "done"
end

function Expeditio:tone()
	return tones[self:status()]
end

function Expeditio:waiting()
	local ids = {}
	for _, t in ipairs(self:mandata()) do
		if t.state == "open" then
			table.insert(ids, t.id)
		end
	end
	return ids
end

function Expeditio.listed_in(expeditiones, folder)
	local out = {}
	for _, e in ipairs(expeditiones) do
		if format.inside(folder, e.root) and not e:is_finished() then
			table.insert(out, e)
		end
	end
	table.sort(out, function(a, b)
		return (a.created or 0) < (b.created or 0)
	end)
	return out
end

function Expeditio.find(expeditiones, root, title)
	for _, e in ipairs(expeditiones) do
		if e.root == root and e.title == title then
			return e
		end
	end
end

function Expeditio:new_mandatum(id, spec, from, at)
	local mandatum = Mandatum.make(id, spec, self.root, from, at, self.id)
	self.list = self:mandata()
	table.insert(self.list, mandatum)
	return mandatum
end

local function on_mandatum(self, id, fn)
	local t = self:mandatum(id)
	if not t then
		return false, "no mandatum " .. tostring(id) .. " in " .. tostring(self.title)
	end
	return fn(t)
end

function Expeditio:assign_mandatum(id, agent, at)
	return on_mandatum(self, id, function(t)
		return t:assign(agent, at)
	end)
end

function Expeditio:reassign_mandatum(id, from, to, at)
	return on_mandatum(self, id, function(t)
		return t:reassign(from, to, at)
	end)
end

function Expeditio:release_mandatum(id, agent, at)
	return on_mandatum(self, id, function(t)
		return t:release(agent, at)
	end)
end

function Expeditio:send_mandatum(id, agent, at, assigned_as)
	return on_mandatum(self, id, function(t)
		return t:send(agent, at, assigned_as)
	end)
end

function Expeditio:finish_mandatum(id, note, at)
	return on_mandatum(self, id, function(t)
		return t:finish(note or "", at)
	end)
end

function Expeditio:drop_mandatum(id, at)
	return on_mandatum(self, id, function(t)
		return t:drop(at)
	end)
end

function Expeditio:amend_mandatum(id, changes, at)
	return on_mandatum(self, id, function(t)
		return t:amend(changes, at)
	end)
end

function Expeditio:edit_mandatum(id, text, at)
	return on_mandatum(self, id, function(t)
		return t:edit(text, at)
	end)
end

return Expeditio

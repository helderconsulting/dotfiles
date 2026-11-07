local Model = require("workspace.shared.lib.model")

local Contubernium = Model.extend({
	kind = "contubernia",
	fields = { "id", "name", "todo", "root", "base", "members", "created", "centuria", "stood_by", "earlier", "plan", "plan_required" },
})

Contubernium.names = { "ash", "birch", "cedar", "elm", "fir", "hazel", "oak", "pine", "rowan", "yew" }
Contubernium.contubernium_names = { "lutra", "ardea", "lynx", "meles", "falco", "martes", "regulus", "ibis", "triturus", "orca", "mustela", "pluvialis" }
Contubernium.min, Contubernium.max = 2, #Contubernium.names
Contubernium.command = "~/.config/wezterm/bin/contubernium"

function Contubernium:init()
	self.members = self.members or {}
	self.earlier = self.earlier or {}
end

function Contubernium:stand_by(at)
	self.stood_by = self.stood_by or at
	return true
end

function Contubernium:is_idle(mandatum_state)
	return self.stood_by ~= nil or mandatum_state == "done"
end

function Contubernium:take(todo)
	if self.todo then
		table.insert(self.earlier, self.todo)
	end
	self.todo, self.stood_by = todo, nil
	self.plan_required, self.plan = true, nil
end

function Contubernium:held(todo)
	if self.todo == todo then
		return true
	end
	for _, id in ipairs(self.earlier) do
		if id == todo then
			return true
		end
	end
	return false
end

function Contubernium.new_id(random)
	return ("%04x"):format(random(0, 0xffff))
end

function Contubernium.fits(size)
	return type(size) == "number" and size % 1 == 0 and size >= Contubernium.min and size <= Contubernium.max
end

function Contubernium.pick_name(contubernia, random)
	local taken = {}
	for _, t in ipairs(contubernia) do
		taken[t.name or ""] = true
	end
	local free = {}
	for _, name in ipairs(Contubernium.contubernium_names) do
		if not taken[name] then
			table.insert(free, name)
		end
	end
	local pool = #free > 0 and free or Contubernium.contubernium_names
	return pool[random(1, #pool)]
end

function Contubernium.make(id, todo, root, base, milites, at, name)
	local members = {}
	for i, miles in ipairs(milites) do
		members[i] = { name = Contubernium.names[i], miles = miles }
	end
	return Contubernium:new({ id = id, name = name, todo = todo, root = root, base = base, members = members, created = at })
end

function Contubernium.enlist(fields)
	if fields.plan_required == nil then
		fields.plan_required = true
	end
	return Contubernium:new(fields)
end

function Contubernium.of(contubernia, miles)
	local newest
	for _, t in ipairs(contubernia) do
		if t:has(miles) and (not newest or (t.created or 0) >= (newest.created or 0)) then
			newest = t
		end
	end
	return newest
end

function Contubernium:label()
	return "contubernium " .. (self.name or self.id)
end

function Contubernium:decanus()
	for _, m in ipairs(self.members) do
		if m.role == "decanus" then
			return m
		end
	end
	return self.members[1]
end

function Contubernium:is_enlisted()
	return self.centuria ~= nil
end

function Contubernium:member_names()
	local out = {}
	for i, m in ipairs(self.members) do
		out[i] = m.name
	end
	return out
end

function Contubernium:milites_under(name)
	local out = {}
	for _, m in ipairs(self.members) do
		if m.name ~= name then
			table.insert(out, m.name)
		end
	end
	return out
end

function Contubernium:fall(miles, seniority_of)
	local fallen = self:member_for(miles)
	if not fallen then
		return nil
	end
	local position = self:position(miles)
	table.remove(self.members, position)
	if fallen.role ~= "decanus" or #self.members == 0 then
		return { role = fallen.role, at = position, fallen = fallen }
	end
	local best, best_seniority
	for _, m in ipairs(self.members) do
		local s = seniority_of(m.miles) or 0
		if not best or s > best_seniority then
			best, best_seniority = m, s
		end
	end
	local role = best.role
	best.role = "decanus"
	return { role = role, at = self:position(best.miles) + 1, fallen = fallen, promoted = best, replaces = best }
end

function Contubernium:fill(vacancy, name, miles)
	local member = { name = name, miles = miles, role = vacancy.role }
	table.insert(self.members, math.min(vacancy.at or #self.members + 1, #self.members + 1), member)
	return member
end

function Contubernium:member(name)
	for _, m in ipairs(self.members) do
		if m.name == name then
			return m
		end
	end
end

function Contubernium:member_for(miles)
	for _, m in ipairs(self.members) do
		if m.miles == miles then
			return m
		end
	end
end

function Contubernium:position(miles)
	for i, m in ipairs(self.members) do
		if m.miles == miles then
			return i
		end
	end
end

function Contubernium:has(miles)
	return self:member_for(miles) ~= nil
end

function Contubernium:started(name, miles)
	local m = self:member(name)
	if not m then
		return false
	end
	m.miles = miles
	return true
end

function Contubernium:leave(miles)
	local was_decanus = self:decanus() ~= nil and self:decanus().miles == miles
	for i, m in ipairs(self.members) do
		if m.miles == miles then
			table.remove(self.members, i)
			return m, was_decanus and self:decanus() or nil
		end
	end
end

function Contubernium:is_empty()
	return #self.members == 0
end

function Contubernium:submit_plan(text, at)
	local shared = self.plan and self.plan.shared
	self.plan = { text = text, at = at, shared = shared }
	return true
end

function Contubernium:mark_handed_out(at)
	self.plan.handed_out_at = at
	return true
end

function Contubernium:handed_out()
	return self.plan ~= nil and self.plan.handed_out_at ~= nil
end

function Contubernium:approve_plan(by, at)
	if not self.plan then
		return false
	end
	self.plan.approved_by, self.plan.at = by, at
	return true
end

function Contubernium:plan_approved()
	return self.plan ~= nil and self.plan.approved_by ~= nil
end

function Contubernium:plan_gate_open()
	return not self.plan_required or self:plan_approved()
end

function Contubernium:add_shared(text, by, at)
	if not self.plan then
		return false
	end
	self.plan.shared = self.plan.shared or {}
	table.insert(self.plan.shared, { text = text, by = by, at = at })
	return true
end

function Contubernium.shared_line(by, text)
	return ("Shared with other contubernia, agreed by %s: %s"):format(by, text)
end

function Contubernium:plan_for(role)
	local lines = { ("Your role: %s."):format(role or "miles"), "", "## The plan", "", self.plan.text }
	for _, s in ipairs(self.plan.shared or {}) do
		table.insert(lines, "")
		table.insert(lines, Contubernium.shared_line(s.by, s.text))
	end
	return table.concat(lines, "\n")
end

function Contubernium.plans_digest(entries)
	local out = {}
	for _, e in ipairs(entries) do
		table.insert(out, ("## Contubernium %s (decanus %s)\n\n%s"):format(e.name, e.decanus, e.plan and e.plan.text or "no plan yet"))
	end
	return table.concat(out, "\n\n")
end

function Contubernium:news(gone, new_decanus, done_command)
	local roster = "The contubernium now, bottom of the stack first:\n\n" .. self:roster()
	local out = {}
	for _, m in ipairs(self.members) do
		local lines
		if new_decanus and m.miles == new_decanus.miles then
			lines = {
				("%s's session is gone, so you lead the contubernium now."):format(gone.name),
				("You keep the split going, and once every layer is in and stacked, you mark the todo done: `%s done %s \"<what the contubernium did>\"`."):format(done_command, self.todo),
			}
		else
			lines = { ("%s's session is gone%s."):format(gone.name, new_decanus and (", " .. new_decanus.name .. " leads the contubernium now") or "") }
		end
		table.insert(lines, ("Whoever stacked on %s's branch now stacks on the branch below it; agree with the others who picks up %s's layer."):format(gone.name, gone.name))
		table.insert(lines, "")
		table.insert(lines, roster)
		table.insert(out, { miles = m.miles, text = table.concat(lines, "\n") })
	end
	return out
end

function Contubernium:below(name)
	for i, m in ipairs(self.members) do
		if m.name == name then
			return self.members[i - 1]
		end
	end
end

function Contubernium:recipients(from, to)
	local out = {}
	for _, m in ipairs(self.members) do
		if m.miles ~= from and (to == "all" or m.name == to) then
			table.insert(out, m)
		end
	end
	return out
end

function Contubernium:letter(from, text)
	local sender = self:member_for(from)
	local name = sender and sender.name or "someone"
	local body = text:gsub("^%s*" .. name .. "%f[%W][%s,:%-]*", "", 1)
	return ("%s: %s\n\n(from %s on %s, todo %s; answer with `%s send %s \"<message>\"`)"):format(name, body, name, self:label(), self.todo, Contubernium.command, name)
end

function Contubernium:roster()
	local names = {}
	for i, m in ipairs(self.members) do
		local what = m.role and (" (" .. m.role .. ")") or (i == 1 and " (lead)" or "")
		table.insert(names, ("%d. %s%s"):format(i, m.name, what))
	end
	return table.concat(names, "\n")
end

function Contubernium.for_todo(contubernia, todo)
	local found
	for _, t in ipairs(contubernia) do
		if t:held(todo) and (not found or (t.created or 0) > (found.created or 0)) then
			found = t
		end
	end
	return found
end

function Contubernium:brief(todo, name)
	local decanus, below = self:decanus(), self:below(name)
	local is_decanus = decanus.name == name
	local base = self.base and ("`" .. self.base .. "`") or "the current branch"
	local start = below and ("Branch off " .. below.name .. "'s branch once it exists, so your work stacks on theirs.")
		or ("Branch off " .. base .. ": the stack starts with you.")
	local lines = {
		todo.text,
		"",
		("## Working as a contubernium of %d"):format(#self.members),
		"",
		("You're %s. The contubernium, bottom of the stack first:"):format(name),
		"",
		self:roster(),
		"",
		"- Work in your own git worktree on your own branch, never in the shared checkout. " .. start,
		"- The branches stack in the order above: each one builds on the one below it, so each can be rebased onto the one below and merged in order.",
		is_decanus and "- You propose the split first: who builds which layer, the branch names, and the shared code the lower layers provide for the ones above. Send it to everyone, then start on your layer."
			or ("- " .. decanus.name .. " proposes the split first. Wait for it, answer with objections if you have any, then start on your layer."),
		"- Share code by committing it on your branch and telling the agents above you to rebase onto it. Don't copy code between branches.",
		"- When the branch below yours changes, rebase onto it.",
		("- Your session is titled `%s · <what you work on>`. If you rename it with agent-title, your name stays in front."):format(name),
		("- Talk to the others with `%s send <name|all> \"<message>\"`, and see everyone's branch and state with `%s list`. A message reaches its receiver when their current turn ends."):format(Contubernium.command, Contubernium.command),
	}
	if is_decanus then
		table.insert(lines, ("- Once every layer is in and stacked, mark the todo done: `%s done %s \"<what the contubernium did>\"`."):format(todo.done_command or "todo", todo.id))
	else
		table.insert(lines, ("- Tell %s when your layer is done. Only %s marks the todo done."):format(decanus.name, decanus.name))
	end
	return table.concat(lines, "\n")
end

local function topic_of(title, name)
	local t = (title or ""):gsub("%s*·%s*", ": "):gsub("[%s:%-]*%f[%w]" .. name .. "%f[%W][%s:%-]*", " ")
	return (t:gsub("^[%s:%-]+", ""):gsub("[%s:%-]+$", ""):gsub("%s+", " "))
end

function Contubernium.member_title(name, title, fallback)
	local topic = topic_of(title, name)
	if topic == "" then
		topic = topic_of(fallback, name)
	end
	return topic == "" and name or (name .. " · " .. topic)
end

return Contubernium

local Model = require("workspace.shared.lib.model")

local Centuria = Model.extend({
	kind = "centuriae",
	fields = { "id", "legio", "cohors", "expeditio", "title", "root", "centurio", "optio", "contubernia", "account", "created", "waiting", "decisions" },
})

function Centuria:init()
	self.contubernia = self.contubernia or {}
	self.waiting = self.waiting or {}
	self.decisions = self.decisions or {}
end

function Centuria:record_decision(to, text, at)
	table.insert(self.decisions, { at = at, to = to, text = text })
	return true
end

function Centuria:wait_for_contubernium(mandatum)
	if not self:is_waiting(mandatum) then
		table.insert(self.waiting, mandatum)
	end
end

function Centuria:is_waiting(mandatum)
	for _, id in ipairs(self.waiting) do
		if id == mandatum then
			return true
		end
	end
	return false
end

function Centuria:stop_waiting(mandatum)
	for i, id in ipairs(self.waiting) do
		if id == mandatum then
			table.remove(self.waiting, i)
			return true
		end
	end
	return false
end

function Centuria.new_id(random)
	return ("c%04x"):format(random(0, 0xffff))
end

function Centuria.make(fields)
	return Centuria:new(fields)
end

function Centuria:write_account(text, by)
	self.account = { by = by, text = text }
	return true
end

function Centuria:label()
	return "centuria " .. (self.title or self.id)
end

function Centuria:post_of(miles)
	if miles == nil then
		return nil
	elseif self.centurio == miles then
		return "centurio"
	elseif self.optio == miles then
		return "optio"
	end
end

function Centuria:fall(miles)
	local post = self:post_of(miles)
	if post == "centurio" then
		local optio = self.optio
		self.centurio, self.optio = optio, nil
		return { post = optio and "optio" or "centurio", promoted = optio }
	elseif post == "optio" then
		self.optio = nil
		return { post = "optio" }
	end
end

function Centuria:fill(post, miles)
	if post == "centurio" and self.centurio == nil then
		self.centurio = miles
		return true
	elseif post == "optio" and self.optio == nil then
		self.optio = miles
		return true
	end
	return false
end

return Centuria

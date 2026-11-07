local Model = require("workspace.shared.lib.model")

local Cohors = Model.extend({
	kind = "cohortes",
	fields = { "id", "root", "primus_pilus", "commander_commits", "centuriae", "created" },
})

function Cohors:init(data)
	self.centuriae = self.centuriae or {}
	self.primus_pilus = self.primus_pilus or data.pilus_prior
	self._extra.pilus_prior = nil
	self.commander_commits = self.commander_commits == true
end

function Cohors:committed_by_commander()
	return self.commander_commits == true
end

function Cohors.key(root)
	return (root:gsub("/", "%%"))
end

function Cohors.form(root, at)
	return Cohors:new({ id = Cohors.key(root), root = root, created = at })
end

function Cohors:name()
	return (self.root or ""):match("([^/]+)/?$")
end

function Cohors:label()
	return "cohors " .. self:name()
end

function Cohors:is_led_by(miles)
	return miles ~= nil and miles.id == self.primus_pilus and (miles.role == "primus pilus" or miles.role == "pilus prior")
end

function Cohors:release()
	self.primus_pilus = nil
end

function Cohors:join(centuria)
	for _, id in ipairs(self.centuriae) do
		if id == centuria then
			return false
		end
	end
	table.insert(self.centuriae, centuria)
	return true
end

function Cohors:has_leader()
	return self.primus_pilus ~= nil
end

function Cohors:lead(miles)
	if self.primus_pilus then
		return false
	end
	self.primus_pilus = miles
	return true
end

function Cohors:leave(centuria)
	for i, id in ipairs(self.centuriae) do
		if id == centuria then
			table.remove(self.centuriae, i)
			return true
		end
	end
	return false
end

function Cohors:replace_leader(fallen, successor)
	if self.primus_pilus ~= fallen then
		return false
	end
	self.primus_pilus = successor
	return true
end

return Cohors

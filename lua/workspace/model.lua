local machine = require("workspace.machine")

local Model = {}
Model.__index = Model

function Model.extend(spec)
	local cls = setmetatable({}, { __index = Model })
	cls.__index = cls
	cls.kind = spec.kind
	cls.machine = spec.machine and machine.define(spec.machine)
	cls.fields = spec.fields
	cls.known = {}
	for _, f in ipairs(spec.fields or {}) do
		cls.known[f] = true
	end
	return cls
end

function Model.new(cls, data)
	local self = setmetatable({}, cls)
	for _, f in ipairs(cls.fields) do
		self[f] = data and data[f]
	end
	self._extra = {}
	for k, v in pairs(data or {}) do
		if type(k) == "string" and not cls.known[k] then
			self._extra[k] = v
		end
	end
	if cls.machine and (self.state == nil or not machine.knows(cls.machine, self.state)) then
		self.state = cls.machine.initial
	end
	self._transitions = {}
	if self.init then
		self:init(data or {})
	end
	return self
end

function Model:can(event)
	return machine.accepts(self.machine, self.state, event)
end

function Model:transition(event, at)
	local to = machine.step(self.machine, self.state, event)
	local record = { event = event, from = self.state, to = to, at = at }
	table.insert(self._transitions, record)
	if not to then
		record.rejected = true
		return false
	end
	self.state = to
	return true
end

function Model:take_transitions()
	local list = self._transitions
	self._transitions = {}
	return list
end

function Model:to_table()
	local out = {}
	for k, v in pairs(self._extra or {}) do
		out[k] = v
	end
	for _, f in ipairs(self.fields) do
		local v = self[f]
		if type(v) == "table" and v.to_table then
			v = v:to_table()
		elseif type(v) == "table" and v[1] and type(v[1]) == "table" and v[1].to_table then
			local list = {}
			for i, item in ipairs(v) do
				list[i] = item:to_table()
			end
			v = list
		end
		out[f] = v
	end
	return out
end

return Model

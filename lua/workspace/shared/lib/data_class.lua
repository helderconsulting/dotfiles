local M = {}

function M.define(name, fields)
	local cls = { name = name, fields = fields }
	cls.__index = cls
	local known = {}
	for _, f in ipairs(fields) do
		known[f] = true
	end
	function cls.new(values)
		for k in pairs(values or {}) do
			if not known[k] then
				error(("%s has no field %s"):format(name, tostring(k)), 2)
			end
		end
		local self = setmetatable({}, cls)
		for _, f in ipairs(fields) do
			self[f] = values and values[f]
		end
		return self
	end
	function cls.is(value)
		return getmetatable(value) == cls
	end
	return cls
end

return M

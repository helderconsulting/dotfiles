local M = {}

function M.define(spec)
	spec.any = spec.any or {}
	spec.known = { [spec.initial] = true }
	for state, row in pairs(spec.states) do
		spec.known[state] = true
		for _, target in pairs(row) do
			spec.known[target] = true
		end
	end
	for _, target in pairs(spec.any) do
		spec.known[target] = true
	end
	return spec
end

function M.knows(def, state)
	return def.known[state] == true
end

function M.step(def, state, event)
	local from = state or def.initial
	local row = def.states[from] or {}
	return row[event] or def.any[event]
end

function M.accepts(def, state, event)
	return M.step(def, state, event) ~= nil
end

return M

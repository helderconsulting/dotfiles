local M = {}

function M.define(spec)
	spec.any = spec.any or {}
	return spec
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

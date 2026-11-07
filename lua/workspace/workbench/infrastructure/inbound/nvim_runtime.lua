local nvim = require("workspace.shared.adapters.nvim")
local observer = require("workspace.shared.state.observer")
local stored_kinds = require("workspace.stored_kinds")
local composition_root = require("workspace.composition_root")

local M = {}

M.paths = nvim.paths

function M.state()
	return observer.start(stored_kinds.all)
end

function M.store()
	return M.state().store
end

function M.services(clock)
	return composition_root.build(M.store(), { clock = clock })
end

function M.on(topic, fn)
	return M.state().bus.on(topic, fn)
end

function M.read_log(limit)
	return nvim.read_log(limit)
end

function M.screen(cls, id)
	return id and M.store():get(cls, id) or cls:new({ id = "none" })
end

function M.update_screen(cls, id, fn)
	if not id then
		return
	end
	return M.store():update(cls, id, fn)
end

return M

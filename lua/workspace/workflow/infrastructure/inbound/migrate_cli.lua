local nvim = require("workspace.shared.adapters.nvim")
local composition_root = require("workspace.composition_root")

local M = {}

function M.run()
	local store = nvim.new_store(nil, nvim.logger("migrate", { pid = vim.uv.os_getpid() }))
	local moved = composition_root.build(store, { clock = nvim.clock }).workflow_migration.run()
	io.write(("copied %d epics to expeditiones/ and %d todos to mandata/, retargeted %d screens, copied %d drafts; epics/ and todos/ are left as they were\n"):format(moved.expeditiones, moved.mandata, moved.screens, moved.drafts))
	return 0
end

return M

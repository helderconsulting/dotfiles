local nvim = require("workspace.shared.adapters.nvim")
local composition_root = require("workspace.composition_root")
local mapper = require("workspace.legio.infrastructure.inbound.mappers.title_cli_mapper")

local M = {}

function M.run(args)
	local title = mapper.to_title(args)
	local session = require("workspace.shared.providers").current().current_session()
	if title == "" or not session then
		vim.uv.fs_write(2, "usage: agent-title <title>    name this agent session in the WezTerm bar and sidebar\n")
		return 2
	end
	local runner = composition_root.build(nvim.new_store(), { clock = nvim.clock }).miles_runner
	runner:set_title(mapper.to_set_title_command(session, title))
	return 0
end

return M

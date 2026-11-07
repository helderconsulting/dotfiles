local M = {}

function M.register(services, store, opts)
	services.workspace_process = require("workspace.workbench.application.workspace_process").new({
		workspaces = require("workspace.workbench.infrastructure.outbound.filesystem.workspace_repository").new(store),
		provider = setmetatable({}, {
			__index = function(_, key)
				return require("workspace.shared.providers")[key]
			end,
		}),
		clock = opts.clock,
	})
end

return M

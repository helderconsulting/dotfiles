local M = {
	Agent = require("workspace.models.agent"),
	Review = require("workspace.models.review"),
	Ask = require("workspace.models.ask"),
	Resource = require("workspace.models.resource"),
	Workspace = require("workspace.models.workspace"),
	View = require("workspace.models.view"),
	Transcript = require("workspace.models.transcript"),
	Draft = require("workspace.models.draft"),
	Thread = require("workspace.models.thread"),
	Turn = require("workspace.models.turn"),
	Registry = require("workspace.models.registry"),
	Session = require("workspace.models.session"),
	Runtime = require("workspace.models.runtime"),
	Usage = require("workspace.models.usage"),
	Daemon = require("workspace.models.daemon"),
	Todo = require("workspace.models.todo"),
}

M.stored = { M.Agent, M.Review, M.Ask, M.Workspace, M.View, M.Runtime, M.Usage, M.Daemon, M.Todo }

function M.by_kind(kind)
	for _, cls in ipairs(M.stored) do
		if cls.kind == kind then
			return cls
		end
	end
end

return M

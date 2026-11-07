local filesystem = "workspace.conversations.infrastructure.outbound.filesystem."

local M = {}

function M.register(services, store, opts)
	local clock = opts.clock
	local function pid_alive(pid)
		return pid == nil or vim.uv.kill(pid, 0) == 0
	end
	local transcripts = {
		get = function(id)
			return require(filesystem .. "transcript_repository").get(id)
		end,
	}
	services.conversation_thread = require("workspace.conversations.application.conversation_thread").new({
		agents = require("workspace.legio.composition").miles_port(store),
		transcripts = transcripts,
		pid_alive = pid_alive,
		clock = clock,
	})
	services.conversation_transcript =
		require("workspace.conversations.application.conversation_transcript").new({ transcripts = transcripts })
	services.inquiry = require("workspace.conversations.application.inquiry").new({
		questions = require(filesystem .. "question_repository").new(store),
		workspaces = {
			get = function(id)
				return store:get(require("workspace.workbench.domain.workspace"), id)
			end,
		},
		pid_alive = pid_alive,
		clock = clock,
	})
	services.drafting = require("workspace.conversations.application.drafting").new({
		drafts = require(filesystem .. "draft_repository").new(store.paths),
	})
end

return M

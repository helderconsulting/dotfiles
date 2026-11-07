local M = {}

M.all = {
	require("workspace.legio.domain.miles"),
	require("workspace.legio.domain.miles_process"),
	require("workspace.legio.domain.agentd_status"),
	require("workspace.legio.domain.usage"),
	require("workspace.legio.domain.contubernium"),
	require("workspace.legio.domain.legio"),
	require("workspace.legio.domain.cohors"),
	require("workspace.legio.domain.centuria"),
	require("workspace.conversations.domain.question"),
	require("workspace.workflow.domain.expeditio"),
	require("workspace.workflow.domain.mandatum"),
	require("workspace.workflow.domain.review"),
	require("workspace.workflow.domain.merge_request"),
	require("workspace.workflow.domain.diff_progress"),
	require("workspace.workbench.domain.workspace"),
	require("workspace.conversations.presentation.conversation_screen"),
	require("workspace.workbench.presentation.sidebar_screen"),
	require("workspace.infra.presentation.infra_screen"),
}

function M.by_kind(kind)
	for _, cls in ipairs(M.all) do
		if cls.kind == kind then
			return cls
		end
	end
end

return M

local AgentdStatus = require("workspace.legio.domain.agentd_status")

local M = {}

function M.to_domain(record)
	return AgentdStatus:new({
		id = record.id,
		state = record.state,
		reason = record.reason,
		since = record.since,
	})
end

function M.to_record(status)
	return {
		id = status.id,
		state = status.state,
		reason = status.reason,
		since = status.since,
	}
end

return M

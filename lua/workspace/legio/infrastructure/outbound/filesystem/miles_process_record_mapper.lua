local MilesProcess = require("workspace.legio.domain.miles_process")

local M = {}

function M.to_domain(record)
	return MilesProcess:new({
		id = record.id,
		state = record.state,
		provider = record.provider,
		model = record.model,
		reason = record.reason,
		since = record.since,
		context = record.context,
		mode = record.mode,
	})
end

function M.to_record(process)
	return {
		id = process.id,
		state = process.state,
		provider = process.provider,
		model = process.model,
		reason = process.reason,
		since = process.since,
		context = process.context,
		mode = process.mode,
	}
end

return M

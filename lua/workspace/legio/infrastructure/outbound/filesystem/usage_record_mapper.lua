local Usage = require("workspace.legio.domain.usage")

local M = {}

function M.to_domain(record)
	return Usage:new({
		id = record.id,
		windows = record.windows,
		overage = record.overage,
		extra = record.extra,
		updated = record.updated,
	})
end

function M.to_record(usage)
	return {
		id = usage.id,
		windows = usage.windows,
		overage = usage.overage,
		extra = usage.extra,
		updated = usage.updated,
	}
end

return M

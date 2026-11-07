local Expeditio = require("workspace.workflow.domain.expeditio")

local M = {}

function M.to_domain(record)
	return Expeditio:new({
		id = record.id,
		title = record.title,
		root = record.root,
		from = record.from,
		created = record.created,
	})
end

function M.to_record(expeditio)
	return {
		id = expeditio.id,
		title = expeditio.title,
		root = expeditio.root,
		from = expeditio.from,
		created = expeditio.created,
	}
end

return M

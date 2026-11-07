local Mandatum = require("workspace.workflow.domain.mandatum")

local M = {}

function M.to_domain(record)
	return Mandatum:new({
		id = record.id,
		state = record.state,
		text = record.text,
		root = record.root,
		from = record.from,
		created = record.created,
		assignee = record.assignee,
		assigned_at = record.assigned_at,
		sent_at = record.sent_at,
		done_at = record.done_at,
		note = record.note,
		expeditio = record.expeditio,
		headline = record.headline,
		description = record.description,
		criteria = record.criteria,
	})
end

function M.to_record(mandatum)
	return {
		id = mandatum.id,
		state = mandatum.state,
		text = mandatum.text,
		root = mandatum.root,
		from = mandatum.from,
		created = mandatum.created,
		assignee = mandatum.assignee,
		assigned_at = mandatum.assigned_at,
		sent_at = mandatum.sent_at,
		done_at = mandatum.done_at,
		note = mandatum.note,
		expeditio = mandatum.expeditio,
		headline = mandatum.headline,
		description = mandatum.description,
		criteria = mandatum.criteria,
	}
end

return M

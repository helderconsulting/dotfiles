local Centuria = require("workspace.legio.domain.centuria")

local M = {}

function M.to_domain(record)
	return Centuria:new({
		id = record.id,
		legio = record.legio,
		cohors = record.cohors,
		expeditio = record.expeditio,
		title = record.title,
		root = record.root,
		centurio = record.centurio,
		optio = record.optio,
		contubernia = record.contubernia,
		account = record.account,
		created = record.created,
		waiting = record.waiting,
		decisions = record.decisions,
	})
end

function M.to_record(centuria)
	return {
		id = centuria.id,
		legio = centuria.legio,
		cohors = centuria.cohors,
		expeditio = centuria.expeditio,
		title = centuria.title,
		root = centuria.root,
		centurio = centuria.centurio,
		optio = centuria.optio,
		contubernia = centuria.contubernia,
		account = centuria.account,
		created = centuria.created,
		waiting = centuria.waiting,
		decisions = centuria.decisions,
	}
end

return M

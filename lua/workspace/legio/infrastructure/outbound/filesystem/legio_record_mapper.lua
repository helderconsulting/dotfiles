local Legio = require("workspace.legio.domain.legio")

local M = {}

function M.to_domain(record)
	return Legio:new({
		id = record.id,
		name = record.name,
		munus = record.munus,
		roles = record.roles,
		annales = record.annales,
		mos_maiorum = record.mos_maiorum,
		cognomen = record.cognomen,
		expeditiones = record.expeditiones,
		expeditio = record.expeditio,
		centuria = record.centuria,
		raised = record.raised,
	})
end

function M.to_record(legio)
	return {
		id = legio.id,
		name = legio.name,
		munus = legio.munus,
		roles = legio.roles,
		annales = legio.annales,
		mos_maiorum = legio.mos_maiorum,
		cognomen = legio.cognomen,
		expeditiones = legio.expeditiones,
		expeditio = legio.expeditio,
		centuria = legio.centuria,
		raised = legio.raised,
	}
end

return M

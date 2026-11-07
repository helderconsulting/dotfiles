local Cohors = require("workspace.legio.domain.cohors")

local M = {}

function M.to_domain(record)
	return Cohors:new({
		id = record.id,
		root = record.root,
		primus_pilus = record.primus_pilus or record.pilus_prior,
		commander_commits = record.commander_commits == true,
		centuriae = record.centuriae,
		created = record.created,
	})
end

function M.to_record(cohors)
	return {
		id = cohors.id,
		root = cohors.root,
		primus_pilus = cohors.primus_pilus,
		commander_commits = cohors.commander_commits == true,
		centuriae = cohors.centuriae,
		created = cohors.created,
	}
end

return M

local Miles = require("workspace.legio.domain.miles")

local M = {}

function M.to_domain(record)
	return Miles:new({
		id = record.id,
		state = record.state,
		cwd = record.cwd,
		root = record.root,
		branch = record.branch,
		worktree = record.worktree,
		title = record.title,
		name = record.name,
		pid = record.pid,
		pane = record.pane,
		read_at = record.read_at,
		activity = record.activity,
		sending = record.sending,
		outbox = record.outbox,
		updated = record.updated,
		doing = record.doing,
		host = record.host,
		prompt = record.prompt,
		limit = record.limit,
		legio = record.legio,
		role = record.role,
		roman_name = record.roman_name,
		mandata = record.mandata,
		expeditiones = record.expeditiones,
		traditio = record.traditio,
		caller = record.caller,
		due = record.due,
		stopped_by = record.stopped_by,
	})
end

function M.to_record(miles)
	return {
		id = miles.id,
		state = miles.state,
		cwd = miles.cwd,
		root = miles.root,
		branch = miles.branch,
		worktree = miles.worktree,
		title = miles.title,
		name = miles.name,
		pid = miles.pid,
		pane = miles.pane,
		read_at = miles.read_at,
		activity = miles.activity,
		sending = miles.sending,
		outbox = miles.outbox,
		updated = miles.updated,
		doing = miles.doing,
		host = miles.host,
		prompt = miles.prompt,
		limit = miles.limit,
		legio = miles.legio,
		role = miles.role,
		roman_name = miles.roman_name,
		mandata = miles.mandata,
		expeditiones = miles.expeditiones,
		traditio = miles.traditio,
		caller = miles.caller,
		due = miles.due,
		stopped_by = miles.stopped_by,
	}
end

return M

local ExpeditioDto = require("workspace.workflow.application.dto.expeditio_dto")
local ExpeditioProgressDto = require("workspace.workflow.application.dto.expeditio_progress_dto")
local MandatumDto = require("workspace.workflow.application.dto.mandatum_dto")

local M = {}

local function copy(list)
	local out = {}
	for i, v in ipairs(list or {}) do
		out[i] = v
	end
	return out
end

function M.to_mandatum_dto(mandatum)
	return MandatumDto.new({
		id = mandatum.id,
		expeditio = mandatum.expeditio,
		state = mandatum.state,
		status = mandatum:status(),
		tone = mandatum:tone(),
		title = mandatum:title(),
		text = mandatum.text,
		description = mandatum.description,
		criteria = copy(mandatum.criteria),
		root = mandatum.root,
		from = mandatum.from,
		created = mandatum.created,
		assignee = mandatum.assignee,
		assigned_at = mandatum.assigned_at,
		sent_at = mandatum.sent_at,
		done_at = mandatum.done_at,
		note = mandatum.note,
		specified = mandatum:is_specified() == true,
		listed = mandatum:is_listed(),
	})
end

function M.to_mandatum_dtos(list)
	local out = {}
	for i, m in ipairs(list or {}) do
		out[i] = M.to_mandatum_dto(m)
	end
	return out
end

function M.to_progress_dto(expeditio)
	local p = expeditio:progress()
	return ExpeditioProgressDto.new({
		total = p.total,
		done = p.done,
		in_progress = p["in progress"],
		open = p.open,
		fraction = p.total > 0 and p.done / p.total or 0,
	})
end

local function next_up(expeditio)
	for _, m in ipairs(expeditio:mandata()) do
		if m.state ~= "done" then
			return m.id
		end
	end
end

function M.to_expeditio_dto(expeditio)
	return ExpeditioDto.new({
		id = expeditio.id,
		title = expeditio.title,
		root = expeditio.root,
		from = expeditio.from,
		created = expeditio.created,
		status = expeditio:status(),
		tone = expeditio:tone(),
		progress = M.to_progress_dto(expeditio),
		mandata = M.to_mandatum_dtos(expeditio:mandata()),
		waiting = expeditio:waiting(),
		next_up = next_up(expeditio),
		finished = expeditio:is_finished(),
	})
end

function M.to_expeditio_dtos(list)
	local out = {}
	for i, e in ipairs(list or {}) do
		out[i] = M.to_expeditio_dto(e)
	end
	return out
end

return M

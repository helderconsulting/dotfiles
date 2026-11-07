local Miles = require("workspace.legio.domain.miles")
local LegioDto = require("workspace.legio.application.dto.legio_dto")
local UnitDto = require("workspace.legio.application.dto.unit_dto")
local PostDto = require("workspace.legio.application.dto.post_dto")
local MilesStatusDto = require("workspace.legio.application.dto.miles_status_dto")
local DeployedDto = require("workspace.legio.application.dto.deployed_dto")
local miles_dto_mapper = require("workspace.legio.application.mappers.miles_dto_mapper")

local M = {}

local function copy(list)
	local out = {}
	for i, item in ipairs(list or {}) do
		out[i] = type(item) == "table" and item.text or item
	end
	return out
end

function M.to_post_dto(miles_id, post, miles, name)
	if not miles_id then
		return nil
	end
	local state, tone = "starting", "busy"
	if miles then
		state, tone = miles:status()
	end
	return PostDto.new({
		miles_id = miles_id,
		name = miles and (miles.roman_name or miles:display_name()) or name or "…",
		post = post,
		rank = miles and miles:rank() or Miles.ranks[#Miles.ranks].name,
		standing = miles_dto_mapper.to_rank_dto(miles and miles:standing() or Miles.standing_of(0, 0)),
		state = state,
		tone = tone,
		running = miles ~= nil and miles:is_running(),
	})
end

function M.to_contubernium_unit(contubernium, find)
	local decanus = contubernium:decanus()
	local milites = {}
	for _, m in ipairs(contubernium.members) do
		if m ~= decanus then
			table.insert(milites, M.to_post_dto(m.miles, m.role, find(m.miles), m.name))
		end
	end
	return UnitDto.new({
		kind = "contubernium",
		id = contubernium.id,
		label = contubernium:label(),
		leader = decanus and M.to_post_dto(decanus.miles, "decanus", find(decanus.miles), decanus.name) or nil,
		milites = milites,
		units = {},
	})
end

function M.to_centuria_unit(centuria, contubernia, find)
	local units = {}
	for _, c in ipairs(contubernia) do
		table.insert(units, M.to_contubernium_unit(c, find))
	end
	return UnitDto.new({
		kind = "centuria",
		id = centuria.id,
		label = centuria:label(),
		leader = M.to_post_dto(centuria.centurio, "centurio", find(centuria.centurio)),
		second = M.to_post_dto(centuria.optio, "optio", find(centuria.optio)),
		milites = {},
		units = units,
	})
end

function M.to_cohors_unit(cohors, centuria_unit, find)
	return UnitDto.new({
		kind = "cohors",
		id = cohors.id,
		label = cohors:name(),
		leader = cohors:is_led_by(find(cohors.primus_pilus)) and M.to_post_dto(cohors.primus_pilus, "primus pilus", find(cohors.primus_pilus)) or nil,
		milites = {},
		units = { centuria_unit },
	})
end

function M.to_legio_dto(legio, cohors_unit, expeditio_title)
	return LegioDto.new({
		id = legio.id,
		name = legio.name,
		cognomen = legio.cognomen,
		munus = legio.munus,
		duty = legio:duty(),
		roles = copy(legio.roles),
		deployed = legio:is_deployed(),
		expeditio = expeditio_title,
		annales = copy(legio.annales),
		mos_maiorum = copy(legio.mos_maiorum),
		cohors = cohors_unit,
		ranks = Miles.ladder(),
	})
end

local stopped_states = { stopped = true, fallen = true }

function M.to_miles_status_dto(name, post, pulse, depth)
	return MilesStatusDto.new({ name = name, post = post, state = pulse.state, doing = pulse.doing, running = pulse.running, quiet = pulse.quiet, waiting = pulse.waiting, depth = depth or 0, stopped = stopped_states[pulse.state] == true })
end

function M.to_deployed_dto(legio, expeditio, size, centurio)
	return DeployedDto.new({ legio = legio.name, expeditio = expeditio.title, size = size, centurio_id = centurio })
end

return M

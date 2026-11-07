local mapper = require("workspace.legio.application.mappers.miles_dto_mapper")
local Miles = require("workspace.legio.domain.miles")
local MilesProcess = require("workspace.legio.domain.miles_process")
local Contubernium = require("workspace.legio.domain.contubernium")

local Roster = {}
Roster.__index = Roster

local M = {}

function M.new(ports)
	return setmetatable({
		milites = ports.milites,
		contubernia = ports.contubernia,
		daemons = ports.agentd_status,
		todos = ports.todos,
		clock = ports.clock or os.time,
	}, Roster)
end

function Roster:all()
	return mapper.to_milites_dtos(self.milites:all(), self.clock())
end

function Roster:get(id)
	local miles = id and self.milites:get(id)
	return miles and mapper.to_miles_dto(miles, self.clock()) or nil
end

function Roster:called(name)
	local miles = name and Miles.called(self.milites:all(), name)
	return miles and mapper.to_miles_dto(miles, self.clock()) or nil
end

function Roster:running_in(folder)
	return mapper.to_milites_dtos(Miles.running_in(self.milites:all(), folder), self.clock())
end

function Roster:awaiting_turn(id, received)
	local miles = id and self.milites:find(id)
	local transcript = {
		received = function(_, text, at)
			return received(text, at)
		end,
	}
	local turn = miles and miles:awaiting_turn(transcript, self.clock())
	return turn and mapper.to_awaiting_turn_dto(turn) or nil
end

function Roster:contubernium_of(miles_id)
	local contubernium = self.contubernia:of(miles_id)
	return contubernium and self:to_contubernium_dto(contubernium) or nil
end

function Roster:all_contubernia()
	local out = {}
	for i, contubernium in ipairs(self.contubernia:all()) do
		out[i] = self:to_contubernium_dto(contubernium)
	end
	return out
end

function Roster:to_contubernium_dto(contubernium)
	return mapper.to_contubernium_dto(contubernium, function(id)
		return self.milites:find(id)
	end, self.todos.title(contubernium.todo))
end

function Roster:contubernium_stack(todo_id)
	local contubernium = Contubernium.for_todo(self.contubernia:all(), todo_id)
	if not contubernium then
		return {}
	end
	return mapper.to_contubernium_stack_dtos(contubernium, function(id)
		return self.milites:get(id)
	end)
end

function Roster:contubernium_sizes()
	return mapper.to_contubernium_sizes_dto(Contubernium.min, Contubernium.max)
end

function Roster:fits_contubernium(size)
	return Contubernium.fits(size)
end

function Roster:agentd_status()
	local status = self.daemons:get()
	return status and mapper.to_agentd_status_dto(status) or nil
end

function Roster:permission_modes()
	return mapper.to_permission_mode_dtos(MilesProcess.modes)
end

function Roster:default_mode()
	return MilesProcess.default_mode
end

return M

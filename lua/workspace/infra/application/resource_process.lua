local unpack = table.unpack or unpack
local mapper = require("workspace.infra.application.mappers.resource_dto_mapper")

local ResourceProcess = {}
ResourceProcess.__index = ResourceProcess

local M = {}

function M.new(ports)
	return setmetatable({
		names = ports.names,
		providers = ports.providers,
		usage = ports.usage,
		desktops = ports.desktops,
		resources = ports.resources,
		clock = ports.clock or os.time,
	}, ResourceProcess)
end

function ResourceProcess:section_names()
	return { unpack(self.names) }
end

function ResourceProcess:section(name)
	return mapper.to_section_dto(name, self.providers[name])
end

function ResourceProcess:fetch(name, done)
	self.providers[name].fetch(function(list)
		done(list and mapper.to_entry_dtos(name, list) or nil)
	end)
end

function ResourceProcess:show(name, entry, mode)
	local lines, command, terminal = self.providers[name].show(entry.source, mode)
	return mapper.to_show_dto(lines, command, terminal)
end

function ResourceProcess:actions(name)
	return mapper.to_action_dtos(self.providers[name].actions)
end

function ResourceProcess:perform(command)
	local entry = command.entry
	local source = entry and entry.source
	if source then
		source.word, source.kind = entry.word, entry.kind
	end
	for _, action in ipairs(self.providers[command.section].actions or {}) do
		if action[1] == command.key then
			return action[2](source, command.view)
		end
	end
end

function ResourceProcess:observe(command)
	local resource = self.resources:get_or_new(command.section .. ":" .. command.id)
	local now = self.clock()
	resource:observe(command.word, command.kind, now)
	resource:tick(now)
	resource:take_transitions()
	return mapper.to_resource_status_dto(resource:label())
end

function ResourceProcess:toggle(command)
	local resource = self.resources:get(command.section .. ":" .. command.id)
	if not resource then
		return nil
	end
	resource:toggle(self.clock())
	return mapper.to_resource_status_dto(resource:label())
end

function ResourceProcess:mark_usage(entries)
	for _, entry in ipairs(entries) do
		local used = self.usage.in_use(entry.refs)
		entry.word, entry.kind = used and "in use" or "unused", used and "ok" or "off"
	end
end

function ResourceProcess:docker_project()
	return self.usage.project()
end

function ResourceProcess:desktops_dir()
	return self.desktops.dir
end

return M

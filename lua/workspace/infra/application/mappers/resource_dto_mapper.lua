local EntryDto = require("workspace.infra.application.dto.entry_dto")
local ActionDto = require("workspace.infra.application.dto.action_dto")
local SectionDto = require("workspace.infra.application.dto.section_dto")
local ShowDto = require("workspace.infra.application.dto.show_dto")
local ResourceStatusDto = require("workspace.infra.application.dto.resource_status_dto")

local M = {}

local details = {
	containers = function(e)
		return e.port and ("localhost:" .. e.port) or (e.container ~= e.name and e.container) or ""
	end,
	images = function(e)
		return e.id
	end,
	vms = function(e)
		return e.dir and vim.fn.fnamemodify(e.dir, ":~") or ""
	end,
	desktops = function(e)
		return e.host
	end,
	["vpn devices"] = function(e)
		return e.dns or e.os
	end,
	ports = function(e)
		return e.process
	end,
	scripts = function(e)
		return e.command
	end,
}

function M.to_entry_dto(section, source)
	local detail = details[section]
	return EntryDto.new({
		id = source.id,
		name = source.name,
		word = source.word,
		kind = source.kind,
		detail = detail and detail(source) or nil,
		find_detail = source.host or source.dns or "",
		order = source.order,
		refs = source.refs,
		view_key = source.view_key,
		source = source,
	})
end

function M.to_entry_dtos(section, sources)
	local out = {}
	for i, source in ipairs(sources) do
		out[i] = M.to_entry_dto(section, source)
	end
	return out
end

function M.to_action_dto(action)
	return ActionDto.new({ key = action[1], label = action[3], always = action.always, single = action.single })
end

function M.to_action_dtos(actions)
	local out = {}
	for i, action in ipairs(actions or {}) do
		out[i] = M.to_action_dto(action)
	end
	return out
end

function M.to_section_dto(name, provider)
	local word, kind
	if provider.badge then
		word, kind = provider.badge()
	end
	return SectionDto.new({
		name = name,
		docker = provider.docker == true or nil,
		place = provider.place and provider.place() or nil,
		badge_word = word,
		badge_kind = kind,
	})
end

function M.to_show_dto(lines, command, terminal)
	return ShowDto.new({ lines = lines, command = command, terminal = terminal })
end

function M.to_resource_status_dto(word, kind)
	return ResourceStatusDto.new({ word = word, kind = kind })
end

return M

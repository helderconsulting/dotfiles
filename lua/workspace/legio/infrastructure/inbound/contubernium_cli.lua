local nvim = require("workspace.shared.adapters.nvim")
local composition_root = require("workspace.composition_root")
local mapper = require("workspace.legio.infrastructure.inbound.mappers.contubernium_cli_mapper")

local M = {}

local usage = [[
usage: contubernium list                              the others in your contubernium, their branches and what they're doing
       contubernium ready [<mandatum id>]             your decanus only: the mandatum is built and reviewed, so the contubernium can take another
       contubernium take <mandatum id>                your decanus only: record a mandatum you were given by hand, so it is never handed to another contubernium
       contubernium send <name|all> "<message>"       message one of them, or all of them; it arrives when their turn ends
]]

local function fail(msg)
	vim.uv.fs_write(2, msg .. "\n")
	return 1
end

local commands = {}

function commands.list(_, contubernium, from)
	for _, m in ipairs(contubernium.members) do
		io.write(mapper.to_member_line(m, from))
	end
	return 0
end

function commands.ready(_, contubernium, from, args, services)
	local ok, why = services.legio_process:stand_by(from, args[2])
	if not ok then
		return fail("contubernium: " .. tostring(why))
	end
	io.write("standing by for another mandatum\n")
	return 0
end

function commands.take(_, _, from, args, services)
	if not args[2] then
		return fail(usage)
	end
	local ok, why = services.legio_process:take_mandatum(from, args[2])
	if not ok then
		return fail("contubernium: " .. tostring(why))
	end
	io.write("recorded " .. args[2] .. " on your contubernium\n")
	return 0
end

function commands.send(membership, _, from, args)
	local to, text = args[2], args[3]
	if not (to and text and text ~= "") then
		return fail(usage)
	end
	local sent = membership:send_message(mapper.to_send_command(from, args))
	if not sent then
		return fail(("contubernium: no member %s, see: contubernium list"):format(to))
	end
	io.write(mapper.to_sent_line(sent))
	return 0
end

function M.run(args)
	local command = commands[args[1] or ""]
	if not command then
		vim.uv.fs_write(2, usage)
		return 2
	end
	local from = require("workspace.shared.providers").current().current_session()
	local store = nvim.new_store(nil, nvim.logger("contubernium", { pid = vim.uv.os_getpid(), session = from }))
	local services = composition_root.build(store, { clock = nvim.clock })
	local membership = services.contubernium_membership
	local contubernium = from and membership:contubernium_of(from)
	if not contubernium then
		return fail("contubernium: this session isn't in a contubernium")
	end
	return command(membership, contubernium, from, args, services)
end

return M

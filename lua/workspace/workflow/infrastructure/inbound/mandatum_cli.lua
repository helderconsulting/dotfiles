local nvim = require("workspace.shared.adapters.nvim")
local git = require("workspace.shared.adapters.git")
local composition_root = require("workspace.composition_root")
local cli_mapper = require("workspace.workflow.infrastructure.inbound.mappers.mandatum_cli_mapper")

local M = {}

local usage = [[
usage: mandatum [-C dir] add "<title>" --description "<short, plain>" --criteria "Given …, when …, then …" [--criteria …] [--expeditio "<title>"]
           add a mandatum for this repo, in your session's expeditio or the one named
       mandatum amend <id> [--title "<title>"] [--description "<short, plain>"] [--criteria "Given …, when …, then …" …]
           fix a mandatum; --criteria replaces all of its criteria
       mandatum show <id>                           print a mandatum
       mandatum [-C dir] list                       open mandata for this repo
       mandatum done <id> ["<what you did>"]        mark a mandatum you were given done
       mandatum hand <id> <session>                 hand a mandatum you were given to another running session, by its name

A mandatum is a title, a short plain description, and acceptance criteria written as Given …, when …, then ….
]]

local function fail(msg)
	vim.uv.fs_write(2, msg .. "\n")
	return 1
end

local commands = {}

function commands.hand(ctx, args)
	if not (args[2] and args[3]) then
		return fail(usage)
	end
	local to = ctx.services.roster:called(args[3])
	if not to then
		return fail("mandatum: no running session called " .. args[3])
	end
	if not ctx.services.mandatum_process:hand(cli_mapper.to_hand_command(args[2], ctx.from, to.id)) then
		return fail("mandatum: " .. args[2] .. " isn't an open mandatum given to you")
	end
	io.write(("handed %s to %s\n"):format(args[2], args[3]))
	return 0
end

function commands.add(ctx, args)
	local opts, positional = cli_mapper.flags(args, 2)
	local mandata = ctx.services.mandatum_process
	local title = opts.expeditio or opts.epic
	if not title then
		local agent = ctx.from ~= "you" and ctx.services.roster:get(ctx.from)
		title = agent and agent.name or mandata.loose_ends
	end
	local id, why = mandata:add_mandatum(cli_mapper.to_add_command(ctx.root, positional[1], opts, title, ctx.from))
	if not id then
		return fail("mandatum: " .. tostring(why) .. "\n\n" .. usage)
	end
	io.write(id .. "\n")
	ctx.services.legio_process:offer_mandatum(id)
	return 0
end

function commands.amend(ctx, args)
	local id = args[2]
	local opts = cli_mapper.flags(args, 3)
	if not id or (opts.title == nil and opts.description == nil and opts.criteria == nil) then
		return fail(usage)
	end
	local ok, why = ctx.services.mandatum_process:amend(cli_mapper.to_amend_command(id, opts))
	if not ok then
		return fail("mandatum: " .. tostring(why))
	end
	return 0
end

function commands.show(ctx, args)
	local m = args[2] and ctx.services.mandatum_process:mandatum(args[2])
	if not m then
		return fail("mandatum: no mandatum " .. tostring(args[2]))
	end
	io.write(m.text .. "\n")
	return 0
end

function commands.list(ctx)
	for _, m in ipairs(ctx.services.mandatum_process:open_mandata(ctx.root)) do
		io.write(cli_mapper.to_list_line(m))
	end
	return 0
end

function commands.done(ctx, args)
	if not args[2] then
		return fail(usage)
	end
	local finished = ctx.services.mandatum_process:finish(cli_mapper.to_finish_command(args[2], args[3]))
	if not finished then
		return fail("mandatum: no open mandatum " .. args[2] .. " (see: mandatum list)")
	end
	local stood_down = false
	ctx.services.legio_process:credit_finished(ctx.from, function()
		stood_down = true
	end)
	vim.wait(30000, function()
		return stood_down
	end, 50)
	return 0
end

function M.run(args)
	local dir = vim.uv.cwd()
	if args[1] == "-C" then
		dir = args[2]
		table.remove(args, 1)
		table.remove(args, 1)
	end
	local command = commands[args[1] or ""]
	if not command then
		vim.uv.fs_write(2, usage)
		return 2
	end
	local store = nvim.new_store(nil, nvim.logger("mandatum", { pid = vim.uv.os_getpid(), session = require("workspace.shared.providers").current().current_session() }))
	return command({
		root = git.locate(dir).root,
		services = composition_root.build(store, { clock = nvim.clock }),
		from = require("workspace.shared.providers").current().current_session() or "you",
	}, args)
end

return M

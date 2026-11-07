local nvim = require("workspace.shared.adapters.nvim")
local composition_root = require("workspace.composition_root")
local git = require("workspace.shared.adapters.git")
local mapper = require("workspace.legio.infrastructure.inbound.mappers.legio_cli_mapper")

local M = {}

M.wait_ms = 60000

local usage = [[
usage: legio report "<message>"                 tell your superior: a miles tells his decanus, a decanus or optio his centurio; an auxilium tells the miles who called him in and ends his session
       legio report "<message>" --kind <decision|blocker|done>  a decanus's report goes to the centurio, with the optio copied
       legio order <name|all> "<message>"       give an order to the milites under you
       legio status                             show each miles under you: state, what he is doing, time since his last activity, orders waiting
       legio traditio "<handover>" ["<lesson>"] hand over your post when your context is nearly full
       legio annales "<account>"                the centurio writes the account of the expeditio for the annales
       legio lesson "<lesson>"                  add a lesson to your legio's mos maiorum
       legio plan "<text>"                      a decanus submits his contubernium's plan to his optio for approval
       legio approve "<decanus name>"           an optio approves a decanus's plan, so his faber may edit files
       legio align <decanus name|all> "<text>"  an optio agrees a shared part with the decani whose plans clash
       legio handout                            a decanus with an approved plan sends the full plan to his contubernium
       legio cohors commander-commits on|off    the commander, at a terminal in the codebase: say whether the commander commits here, so decani don't
       legio auxilium "<job>"                   call in a helper for one narrow job; it reports back to you and earns no rank
]]

local function fail(msg)
	vim.uv.fs_write(2, msg .. "\n")
	return 1
end

local function said(text)
	return text ~= nil and text:match("%S") ~= nil
end

local commands = {}

local function sent(names, why)
	if not names then
		return fail("legio: " .. why)
	end
	io.write(mapper.to_sent_line(names))
	if why and #why > 0 then
		io.write(mapper.to_stood_down_line(why))
	end
	return 0
end

function commands.report(services, from, args)
	if not said(args[2]) then
		return fail(usage)
	end
	return sent(services.legio_process:report(mapper.to_report_command(from, args)))
end

function commands.order(services, from, args)
	if not (args[2] and said(args[3])) then
		return fail(usage)
	end
	return sent(services.legio_process:order(mapper.to_order_command(from, args)))
end

function commands.status(services, from)
	local statuses, why = services.legio_process:status(from)
	if not statuses then
		return fail("legio: " .. why)
	end
	io.write(mapper.to_status_lines(statuses))
	return 0
end

function commands.auxilium(services, from, args)
	if not said(args[2]) then
		return fail(usage)
	end
	local finished, ok, result
	services.legio_process:call_auxilium(mapper.to_call_auxilium_command(from, args), function(o, r)
		finished, ok, result = true, o, r
	end)
	vim.wait(M.wait_ms, function()
		return finished
	end, 50)
	if not finished then
		return fail("legio: the auxilium didn't start in time")
	elseif not ok then
		return fail("legio: " .. tostring(result))
	end
	io.write(mapper.to_auxilium_started_line(result))
	return 0
end

function commands.plan(services, from, args)
	if not said(args[2]) then
		return fail(usage)
	end
	local ok, why = services.legio_process:submit_plan(mapper.to_submit_plan_command(from, args))
	if not ok then
		return fail("legio: " .. why)
	end
	io.write("your plan is with your optio for approval\n")
	return 0
end

function commands.approve(services, from, args)
	if not said(args[2]) then
		return fail(usage)
	end
	local ok, why = services.legio_process:approve_plan(mapper.to_approve_plan_command(from, args))
	if not ok then
		return fail("legio: " .. why)
	end
	io.write(("%s's plan is approved\n"):format(args[2]))
	return 0
end

function commands.align(services, from, args)
	if not (args[2] and said(args[3])) then
		return fail(usage)
	end
	local names, skipped = services.legio_process:align_plan(mapper.to_align_plan_command(from, args))
	if not names then
		return fail("legio: " .. skipped)
	end
	io.write(mapper.to_aligned_line(names, skipped or {}))
	return 0
end

function commands.handout(services, from)
	return sent(services.legio_process:hand_out_plan(mapper.to_hand_out_command(from)))
end

function commands.cohors(services, from, args)
	local on = args[3] == "on"
	if not (args[2] == "commander-commits" and (on or args[3] == "off")) then
		return fail(usage)
	end
	local root = git.locate(vim.uv.cwd()).root
	local ok, why = services.legio_process:set_commander_commits(from, root, on)
	if not ok then
		return fail("legio: " .. why)
	end
	io.write(mapper.to_commander_commits_line(root, on))
	return 0
end

function commands.annales(services, from, args)
	if not said(args[2]) then
		return fail(usage)
	end
	local ok, why = services.legio_process:record_account(mapper.to_account_command(from, args))
	if not ok then
		return fail("legio: " .. why)
	end
	io.write("your account will go into the annales when the legio is discharged\n")
	return 0
end

function commands.lesson(services, from, args)
	if not said(args[2]) then
		return fail(usage)
	end
	local ok, learned = services.legio_process:record_lesson(mapper.to_lesson_command(from, args))
	if not ok then
		return fail("legio: " .. learned)
	end
	io.write(learned and "added to the mos maiorum\n" or "the mos maiorum already holds it\n")
	return 0
end

function commands.traditio(services, from, args)
	if not said(args[2]) then
		return fail(usage)
	end
	local finished, ok, result
	services.handover_process:hand_over(mapper.to_hand_over_command(from, args), function(o, r)
		finished, ok, result = true, o, r
	end)
	vim.wait(M.wait_ms, function()
		return finished
	end, 50)
	if not finished then
		return fail("legio: the handover didn't finish in time")
	elseif not ok then
		return fail("legio: " .. tostring(result))
	end
	io.write(mapper.to_handed_over_line(result))
	return 0
end

function M.run(args)
	local command = commands[args[1] or ""]
	if not command then
		vim.uv.fs_write(2, usage)
		return 2
	end
	local from = require("workspace.shared.providers").current().current_session()
	if not from and args[1] ~= "cohors" then
		return fail("legio: run this from inside a miles's session")
	end
	local store = nvim.new_store(nil, nvim.logger("legio", { pid = vim.uv.os_getpid(), session = from }))
	return command(composition_root.build(store, { clock = nvim.clock }), from, args)
end

return M

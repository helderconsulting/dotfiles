local SendLegioMessageCommand = require("workspace.legio.application.commands.send_legio_message_command")
local HandOverCommand = require("workspace.legio.application.commands.hand_over_command")
local CallAuxiliumCommand = require("workspace.legio.application.commands.call_auxilium_command")
local RecordAccountCommand = require("workspace.legio.application.commands.record_account_command")
local RecordLessonCommand = require("workspace.legio.application.commands.record_lesson_command")
local SubmitPlanCommand = require("workspace.legio.application.commands.submit_plan_command")
local ApprovePlanCommand = require("workspace.legio.application.commands.approve_plan_command")
local AlignPlanCommand = require("workspace.legio.application.commands.align_plan_command")
local HandOutCommand = require("workspace.legio.application.commands.hand_out_command")

local M = {}

local function without_kind(args)
	local rest, kind, i = {}, nil, 2
	while args[i] do
		if args[i] == "--kind" then
			kind = args[i + 1] or ""
			i = i + 2
		else
			table.insert(rest, args[i])
			i = i + 1
		end
	end
	return rest, kind
end

function M.to_report_command(from, args)
	local rest, kind = without_kind(args)
	return SendLegioMessageCommand.new({ from = from, text = rest[1], kind = kind })
end

function M.to_order_command(from, args)
	return SendLegioMessageCommand.new({ from = from, to = args[2], text = args[3] })
end

function M.to_hand_over_command(from, args)
	return HandOverCommand.new({ miles_id = from, traditio = args[2], lesson = args[3] })
end

function M.to_account_command(from, args)
	return RecordAccountCommand.new({ from = from, text = args[2] })
end

function M.to_lesson_command(from, args)
	return RecordLessonCommand.new({ from = from, text = args[2] })
end

function M.to_submit_plan_command(from, args)
	return SubmitPlanCommand.new({ from = from, text = args[2] })
end

function M.to_approve_plan_command(from, args)
	return ApprovePlanCommand.new({ from = from, name = args[2] })
end

function M.to_align_plan_command(from, args)
	return AlignPlanCommand.new({ from = from, to = args[2], text = args[3] })
end

function M.to_hand_out_command(from)
	return HandOutCommand.new({ from = from })
end

function M.to_call_auxilium_command(from, args)
	return CallAuxiliumCommand.new({ from = from, job = args[2] })
end

function M.to_auxilium_started_line(name)
	return ("%s started; its report will come to you as \"%s reports: ...\"\n"):format(name, name)
end

local format = require("workspace.shared.lib.format")

local function status_line(s)
	local parts = { s.state }
	if s.stopped and s.state ~= "stopped" then
		table.insert(parts, "stopped")
	end
	if s.doing then
		table.insert(parts, s.doing)
	end
	if s.quiet then
		table.insert(parts, "last activity " .. format.duration(s.quiet) .. " ago")
	end
	table.insert(parts, ("%d %s waiting"):format(s.waiting, s.waiting == 1 and "order" or "orders"))
	return ("%s%s (%s): %s\n"):format(("  "):rep(s.depth or 0), s.name, s.post, table.concat(parts, " · "))
end

function M.to_status_lines(statuses)
	if #statuses == 0 then
		return "no milites under you\n"
	end
	local out = {}
	for i, s in ipairs(statuses) do
		out[i] = status_line(s)
	end
	return table.concat(out)
end

function M.to_commander_commits_line(root, on)
	return ("%s: the commander %s commit in this codebase\n"):format(root, on and "does" or "no longer does")
end

function M.to_sent_line(names)
	return ("sent to %s\n"):format(table.concat(names, ", "))
end

function M.to_stood_down_line(names)
	local verb = #names == 1 and "was" or "were"
	return ("%s %s stood down; your order was not delivered\n"):format(table.concat(names, ", "), verb)
end

function M.to_aligned_line(names, skipped)
	local line = M.to_sent_line(names):gsub("\n$", "")
	if #skipped > 0 then
		line = line .. ("; skipped %s: no plan yet"):format(table.concat(skipped, ", "))
	end
	return line .. "\n"
end

function M.to_handed_over_line(result)
	if not result.supplementum then
		return "your traditio is kept, but no supplementum started\n"
	end
	return ("%s takes over as %s%s\n"):format(result.supplementum, result.role, result.successor and (", " .. result.successor .. " steps up") or "")
end

return M

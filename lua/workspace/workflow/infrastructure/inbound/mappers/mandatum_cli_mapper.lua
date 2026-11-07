local AddMandatumCommand = require("workspace.workflow.application.commands.add_mandatum_command")
local AmendMandatumCommand = require("workspace.workflow.application.commands.amend_mandatum_command")
local FinishMandatumCommand = require("workspace.workflow.application.commands.finish_mandatum_command")
local HandMandatumCommand = require("workspace.workflow.application.commands.hand_mandatum_command")

local M = {}

function M.flags(args, from)
	local out, positional, i = { criteria = nil }, {}, from
	while i <= #args do
		local a = args[i]
		local key = a:match("^%-%-(%a+)$")
		if key and args[i + 1] then
			if key == "criteria" then
				out.criteria = out.criteria or {}
				table.insert(out.criteria, args[i + 1])
			else
				out[key] = args[i + 1]
			end
			i = i + 2
		else
			table.insert(positional, a)
			i = i + 1
		end
	end
	return out, positional
end

function M.to_add_command(root, title, opts, expeditio_title, from)
	return AddMandatumCommand.new({ root = root, expeditio_title = expeditio_title, title = title, description = opts.description, criteria = opts.criteria or {}, from = from })
end

function M.to_amend_command(id, opts)
	return AmendMandatumCommand.new({ mandatum_id = id, title = opts.title, description = opts.description, criteria = opts.criteria })
end

function M.to_finish_command(id, note)
	return FinishMandatumCommand.new({ mandatum_id = id, note = note or "" })
end

function M.to_hand_command(id, from, to)
	return HandMandatumCommand.new({ mandatum_id = id, from = from, to = to })
end

function M.to_list_line(m)
	return ("%s\t%s\t%s%s\n"):format(m.id, m.state, m.title, m.specified and "" or "\t(needs details)")
end

return M

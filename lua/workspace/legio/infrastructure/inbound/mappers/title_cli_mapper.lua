local SetMilesTitleCommand = require("workspace.legio.application.commands.set_miles_title_command")

local M = {}

function M.to_title(args)
	return (table.concat(args, " "):gsub("[\t\n]", " "))
end

function M.to_set_title_command(session, title)
	return SetMilesTitleCommand.new({ miles_id = session, title = title, as_member = true, create = true })
end

return M

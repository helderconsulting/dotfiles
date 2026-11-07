local RETIRED = { "fetch", "card", "thread", "follow", "enter", "escape" }

local HOOKS = {
	"entries_on_refresh",
	"card_on_render",
	"thread_on_select",
	"show_conversation_on_select",
	"open_on_enter",
	"handled_on_escape",
}

local PANELS = {
	"workspace.workflow.presentation.nvim.expeditio_panel",
	"workspace.legio.presentation.nvim.miles_panel",
	"workspace.legio.presentation.nvim.legio_panel",
	"workspace.workbench.presentation.nvim.board",
}

local OPTIONAL = {
	["workspace.legio.presentation.nvim.legio_panel"] = { thread_on_select = true },
}

return function(t)
	local test, check = t.test, t.check

	test("sidebar hooks name when they run and what they return", function()
		for _, mod in ipairs(PANELS) do
			local panel = require(mod)
			local missing, retired, unnamed = {}, {}, {}
			for _, name in ipairs(HOOKS) do
				if type(panel[name]) ~= "function" and not (OPTIONAL[mod] or {})[name] then
					table.insert(missing, name)
				elseif not name:match("^[a-z_]+_on_[a-z_]+$") then
					table.insert(unnamed, name)
				end
			end
			for _, name in ipairs(RETIRED) do
				if rawget(panel, name) ~= nil then
					table.insert(retired, name)
				end
			end
			check(mod .. " exports every hook", #missing == 0, missing)
			check(mod .. " names each hook by its trigger", #unnamed == 0, unnamed)
			check(mod .. " drops the generic hook names", #retired == 0, retired)
		end
	end)
end

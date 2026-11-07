local Legio = require("workspace.legio.domain.legio")

return function(t)
	local test, check = t.test, t.check

	local legio = Legio:new({ id = "x-rapax", name = "Legio X Rapax", munus = "implement", roles = { "faber", "probator", "censor" } })

	local function lines_with(text, needle)
		local out = {}
		for line in (text .. "\n"):gmatch("(.-)\n") do
			if line:find(needle, 1, true) then
				table.insert(out, line)
			end
		end
		return out
	end

	test("the decanus's orders carry the plan, approve and handout commands", function()
		local text = legio:orders({ name = "Quintus", post = "decanus", superior = "Titus", subordinates = { "Gaius" }, mandatum = "m" })
		check("orders name legio plan", text:find("legio plan", 1, true) ~= nil)
		check("orders name legio approve", text:find("legio approve", 1, true) ~= nil)
		check("orders name legio handout", text:find("legio handout", 1, true) ~= nil)
	end)

	test("the decanus does not send his plan with legio report", function()
		local text = legio:orders({ name = "Quintus", post = "decanus", superior = "Titus", subordinates = { "Gaius" }, mandatum = "m" })
		local plan_report = {}
		for _, line in ipairs(lines_with(text, "plan")) do
			if line:find(Legio.command .. " report", 1, true) then
				table.insert(plan_report, line)
			end
		end
		check("no plan line tells him to use legio report", #plan_report == 0, plan_report)
	end)
end

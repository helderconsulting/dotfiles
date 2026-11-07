local Legio = require("workspace.legio.domain.legio")
local ChainOfCommand = require("workspace.legio.domain.chain_of_command")
local HandoverProcess = require("workspace.legio.application.handover_process")

local function contubernium(decanus, members)
	return {
		members = members,
		decanus = function()
			return { miles = decanus.miles, name = decanus.name }
		end,
		has = function(_, id)
			for _, m in ipairs(members) do
				if m.miles == id then
					return true
				end
			end
			return false
		end,
		member_for = function(_, id)
			for _, m in ipairs(members) do
				if m.miles == id then
					return m
				end
			end
		end,
	}
end

return function(t)
	local test, check = t.test, t.check

	local names = { c = "Lucius", o = "Titus", d1 = "Quintus", d2 = "Publius", m1 = "Gaius" }
	local function name_of(id)
		return names[id]
	end
	local legio = Legio:new({ id = "x-rapax", name = "Legio X Rapax", munus = "implement", roles = { "faber", "probator", "censor" } })

	test("the optio runs on opus", function()
		check("optio model is opus", Legio.model_for("optio") == "opus")
	end)

	test("the optio's orders say he keep the centuria aligned", function()
		local text = legio:orders({ name = "Titus", post = "optio", superior = "Lucius", subordinates = { "Quintus" } })
		check("orders say he keep the centuria aligned", text:find("keep the centuria aligned", 1, true) ~= nil)
	end)

	test("a decanus sends his plan to his superior and starts only after approval", function()
		local text = legio:orders({ name = "Quintus", post = "decanus", superior = "Titus", subordinates = { "Gaius" }, mandatum = "m" })
		check("orders say send your plan", text:find("send your plan", 1, true) ~= nil)
		check("orders say work starts after he approves it", text:find("approves it", 1, true) ~= nil)
		check("orders say routine reports go to him too", text:find("routine reports", 1, true) ~= nil)
	end)

	local centuria = { centurio = "c", optio = "o" }
	local contubernia = {
		contubernium({ miles = "d1", name = "Quintus" }, { { miles = "d1", name = "Quintus", role = "decanus" }, { miles = "m1", name = "Gaius", role = "faber" } }),
	}

	test("a decanus reports to the optio when the centuria has one", function()
		local route = ChainOfCommand.of("d1", centuria, contubernia, name_of, nil)
		check("decanus post", route.post == "decanus")
		check("decanus superior is the optio", route.superior and route.superior.miles == "o" and route.superior.name == "Titus")
	end)

	test("a decanus reports to the centurio when the centuria has no optio", function()
		local route = ChainOfCommand.of("d1", { centurio = "c" }, contubernia, name_of, nil)
		check("decanus superior falls back to the centurio", route.superior and route.superior.miles == "c")
	end)

	test("the optio reports to the centurio", function()
		local route = ChainOfCommand.of("o", centuria, contubernia, name_of, nil)
		check("optio post", route.post == "optio")
		check("optio superior is the centurio", route.superior and route.superior.miles == "c")
	end)

	test("a supplementum decanus is told the optio is his superior", function()
		local titus = { name = "Titus", display_name = function() return "Titus" end }
		local milites = { find = function(_, id) return id == "o" and titus or nil end }
		local process = HandoverProcess.new({ milites = milites })
		local vacancy = { role = "decanus", superior = "o" }
		local text = process:orders(legio, vacancy, "Publius")
		check("supplementum reports to the optio", text:find("You report to Titus", 1, true) ~= nil)
	end)

	test("the centurio still orders every decanus directly", function()
		local two = {
			contubernium({ miles = "d1", name = "Quintus" }, { { miles = "d1", name = "Quintus", role = "decanus" } }),
			contubernium({ miles = "d2", name = "Publius" }, { { miles = "d2", name = "Publius", role = "decanus" } }),
		}
		local route = ChainOfCommand.of("c", centuria, two, name_of, "Pilus")
		local under = {}
		for _, s in ipairs(route.subordinates) do
			under[s.name] = true
		end
		check("centurio commands the optio and both decani", under.Titus and under.Quintus and under.Publius and #route.subordinates == 3)
		local picked = ChainOfCommand.pick(route.subordinates, "Publius")
		check("one order by name reaches that decanus", #picked == 1 and picked[1].name == "Publius")
	end)

	test("the optio forwards only plans, blockers, decisions and finished mandata, and answers routine reports himself", function()
		local text = legio:orders({ name = "Titus", post = "optio", superior = "Lucius", subordinates = { "Quintus" } })
		check("forwards approved plans", text:find("approved plans", 1, true) ~= nil)
		check("forwards blockers, decisions and finished mandata", text:find("blockers, decisions and finished mandata", 1, true) ~= nil)
		check("answers routine reports himself", text:find("Answer routine reports", 1, true) ~= nil)
	end)

	test("after a decanus falls with an optio present, his supplementum is told the optio", function()
		local titus = { name = "Titus", display_name = function() return "Titus" end }
		local milites = { find = function(_, id) return id == "o" and titus or nil end }
		local centuriae = { get = function(_, id) return id == "k" and { id = "k", optio = "o" } or nil end }
		local process = HandoverProcess.new({ milites = milites, centuriae = centuriae })
		local unit = {
			centuria = "k",
			decanus = function() return nil end,
			label = function() return "contubernium" end,
			roster = function() return "" end,
		}
		local text = process:orders(legio, { role = "decanus", unit = unit, mandatum = "m" }, "Publius")
		check("supplementum decanus reports to the optio", text:find("You report to Titus", 1, true) ~= nil)
	end)

	test("with no optio in the centuria, there is no optio route and the centurio commands only the decani", function()
		check("no optio, no optio route", ChainOfCommand.of("o", { centurio = "c" }, contubernia, name_of, nil) == nil)
		local route = ChainOfCommand.of("c", { centurio = "c" }, contubernia, name_of, { miles = "p", name = "Marcus" })
		check("centurio commands only the decanus", #route.subordinates == 1 and route.subordinates[1].miles == "d1", route.subordinates)
	end)

	test("with no optio, the centurio orders a decanus directly and the decanus reports to him", function()
		local route = ChainOfCommand.of("c", { centurio = "c" }, contubernia, name_of, nil)
		local picked = ChainOfCommand.pick(route.subordinates, "Quintus")
		check("the order by name reaches the decanus", #picked == 1 and picked[1].miles == "d1", picked)
		local decanus = ChainOfCommand.of("d1", { centurio = "c" }, contubernia, name_of, nil)
		check("the decanus reports straight to the centurio", decanus.superior and decanus.superior.miles == "c")
	end)

	test("only the optio moves up to opus; the decani stay on sonnet", function()
		check("optio is opus", Legio.model_for("optio") == "opus")
		check("decanus is still sonnet", Legio.model_for("decanus") == "sonnet")
	end)

	test("when the centurio falls and the optio steps up with no successor, the decani report to the new centurio", function()
		local route = ChainOfCommand.of("d1", { centurio = "o" }, contubernia, name_of, nil)
		check("decanus superior is the new centurio", route.superior and route.superior.miles == "o" and route.superior.name == "Titus", route.superior)
		local centurio = ChainOfCommand.of("o", { centurio = "o" }, contubernia, name_of, { miles = "p", name = "Marcus" })
		check("new centurio has the centurio post", centurio.post == "centurio")
		check("new centurio reports to the primus pilus", centurio.superior and centurio.superior.miles == "p")
	end)

	local function unit_stub(decanus_name, roster_text)
		return {
			decanus = function()
				return { miles = decanus_name.miles, name = decanus_name.name }
			end,
			label = function()
				return "contubernium " .. decanus_name.name
			end,
			roster = function()
				return roster_text
			end,
		}
	end

	test("an optio's supplementum is briefed on the centurio and the decani", function()
		local people = {
			c = { display_name = function() return "Lucius" end },
			o = { display_name = function() return "Titus" end },
		}
		local function briefed(decanus, name)
			local c = contubernium(decanus, { { miles = decanus.miles, name = decanus.name, role = "decanus" } })
			c.label = function()
				return "contubernium " .. name
			end
			c.roster = function()
				return "decanus " .. name
			end
			return c
		end
		local decani = {
			k1 = briefed({ miles = "d1", name = "Quintus" }, "Quintus"),
			k2 = briefed({ miles = "d2", name = "Publius" }, "Publius"),
		}
		local record = {
			id = "k",
			title = "the api",
			centurio = "c",
			optio = "o",
			contubernia = { "k1", "k2" },
			fall = function(_, id)
				return id == "o" and { post = "optio" } or nil
			end,
		}
		local centuriae = {
			update_existing = function(_, _, fn)
				return fn(record)
			end,
		}
		local contubernia = {
			get = function(_, id)
				return decani[id]
			end,
		}
		local milites = {
			find = function(_, id)
				return people[id]
			end,
		}
		local process = HandoverProcess.new({ milites = milites, centuriae = centuriae, contubernia = contubernia })
		local vacancy = process:fall_in_centuria(record, { id = "o", cwd = "/p" })
		local text = process:orders(legio, vacancy, "Gaius")
		check("optio supplementum reports to the centurio", text:find("You report to Lucius", 1, true) ~= nil, text)
		check("optio supplementum is told to run legio status for the decani", text:find("run legio status", 1, true) ~= nil, text)
		check("optio supplementum's roster names the centurio and the decani", text:find("centurio Lucius", 1, true) ~= nil and text:find("decanus Quintus", 1, true) ~= nil and text:find("decanus Publius", 1, true) ~= nil, text)
	end)

	test("a decanus supplementum with no optio reports to the centurio", function()
		local people = { c = { display_name = function() return "Lucius" end } }
		local centuriae = {
			get = function(_, id)
				return id == "k" and { id = "k", centurio = "c" } or nil
			end,
		}
		local milites = {
			find = function(_, id)
				return people[id]
			end,
		}
		local process = HandoverProcess.new({ milites = milites, centuriae = centuriae })
		local unit = unit_stub({ miles = "d1", name = "Quintus" }, "")
		unit.centuria = "k"
		local text = process:orders(legio, { role = "decanus", unit = unit, mandatum = "m" }, "Publius")
		check("decanus supplementum reports to the centurio", text:find("You report to Lucius", 1, true) ~= nil, text)
	end)

	test("when the centurio falls with no optio, the roster doesn't name the fallen centurio", function()
		local people = { c = { display_name = function() return "Lucius" end } }
		local quintus = contubernium({ miles = "d1", name = "Quintus" }, { { miles = "d1", name = "Quintus", role = "decanus" } })
		quintus.label = function()
			return "contubernium Quintus"
		end
		quintus.roster = function()
			return "decanus Quintus"
		end
		local decani = { k1 = quintus }
		local record = {
			id = "k",
			title = "the api",
			centurio = "c",
			optio = nil,
			contubernia = { "k1" },
			fall = function(_, id)
				return id == "c" and { post = "centurio" } or nil
			end,
		}
		local centuriae = {
			update_existing = function(_, _, fn)
				return fn(record)
			end,
		}
		local contubernia = {
			get = function(_, id)
				return decani[id]
			end,
		}
		local milites = {
			find = function(_, id)
				return people[id]
			end,
		}
		local process = HandoverProcess.new({ milites = milites, centuriae = centuriae, contubernia = contubernia })
		local vacancy = process:fall_in_centuria(record, { id = "c", cwd = "/p" })
		check("the roster doesn't name the dead centurio", not vacancy.brief.roster:find("Lucius", 1, true), vacancy.brief.roster)
		check("the decani are still listed", vacancy.brief.roster:find("decanus Quintus", 1, true) ~= nil, vacancy.brief.roster)
	end)
end

local legio_mapper = require("workspace.legio.presentation.mappers.legio_view_mapper")
local miles_mapper = require("workspace.legio.presentation.mappers.miles_view_mapper")
local LegioEntryViewModel = require("workspace.legio.presentation.view_models.legio_entry_view_model")
local LegionThreadViewModel = require("workspace.legio.presentation.view_models.legion_thread_view_model")

return function(t)
	local test, check = t.test, t.check

	local standings = {
		hastatus = { rank = "hastatus", level = 1, next = "princeps", done = 1, needed = 3, unit = "mandata" },
		princeps = { rank = "princeps", level = 2, next = "triarius", done = 5, needed = 10, unit = "mandata" },
		triarius = { rank = "triarius", level = 3 },
	}

	local function post(name, role, rank, state)
		return { miles_id = name:lower(), name = name, post = role, rank = rank, standing = standings[rank], state = state, tone = state == "working" and "busy" or "off", running = state ~= "starting" }
	end

	local legio = {
		id = "x",
		name = "Legio X Rapax",
		munus = "implement",
		roles = { "faber", "probator", "censor" },
		deployed = true,
		expeditio = "agentd sdk",
		ranks = {
			{ rank = "hastatus", level = 1, mandata = 0 },
			{ rank = "princeps", level = 2, mandata = 3 },
			{ rank = "triarius", level = 3, mandata = 10, expeditiones = 3 },
		},
		cohors = {
			kind = "cohors",
			id = "c1",
			label = ".config",
			leader = post("Titus", "primus pilus", "triarius", "working"),
			milites = {},
			units = {
				{
					kind = "centuria",
					id = "ce1",
					label = "agentd sdk",
					leader = post("Marcus", "centurio", "triarius", "working"),
					second = post("Gaius", "optio", "princeps", "idle"),
					milites = {},
					units = {
						{
							kind = "contubernium",
							id = "co1",
							label = "split the api",
							leader = post("Lucius", "decanus", "princeps", "working"),
							milites = { post("Quintus", "faber", "hastatus", "working"), post("Aulus", "probator", "hastatus", "starting") },
							units = {},
						},
					},
				},
			},
		},
	}

	test("a legio shows as a card with its munus and deployment", function()
		local entries = legio_mapper.to_legio_entries({ legio, { id = "iv", name = "Legio IV Obsidionalis", munus = "test and break", roles = { "probator", "censor" }, deployed = false } })
		check("one entry per legio", #entries == 2 and LegioEntryViewModel.is(entries[1]))
		check("the card names the legio, its munus and roles", entries[1].card[1] == "Legio X Rapax" and entries[1].card[2] == "implement · faber, probator, censor")
		check("a deployed legio says where", entries[1].card[3] == "deployed on agentd sdk" and entries[1].kind == "busy")
		check("an idle legio is in reserve", entries[2].card[3] == "in reserve" and entries[2].kind == "off")
	end)

	test("entering a legio shows cohors, centuria and contubernium nested", function()
		local thread = legio_mapper.to_legion_thread(legio)
		local lines = { unpack(thread.items, 2) }
		check("a thread view model", LegionThreadViewModel.is(thread))
		local legend = thread.items[1]
		check("the thread opens with the ranks, lowest first, and what each takes", legend.card[1] == "ranks" and legend.card[2] == "▴ hastatus  ▴▴ princeps (3 mandata)  ▴▴▴ triarius (10 mandata or 3 expeditiones)", legend.card[2])
		local function text(line)
			if type(line) == "string" then
				return line
			end
			local out = ""
			for _, seg in ipairs(line.segments) do
				out = out .. seg[1]
			end
			return out
		end
		local function tone(line, n)
			return line.segments[n][2]
		end
		check("cohors, centuria, contubernium, then its milites, each nested one step further", #lines == 5 and lines[1].indent == "" and lines[2].indent == "  " and lines[3].indent == "    " and lines[4].indent == "      ")
		check("units get a thin bar and milites a thinner one", lines[1].bar == "▎" and lines[4].bar == "▏")
		check("the leader sits on top of what he leads", text(lines[1].card[1]) == "★ primus pilus Titus ▴▴▴" and tone(lines[1].card[1], 1) == "busy" and text(lines[1].card[2]) == "cohors · .config · 5 milites", { text(lines[1].card[1]), text(lines[1].card[2]) })
		check("the unit kind stands out", tone(lines[2].card[2], 1) == "ok")
		check("a centuria shows its centurio first and its optio below", text(lines[2].card[1]) == "★ centurio Marcus ▴▴▴" and text(lines[2].card[2]) == "centuria · agentd sdk · 3 milites" and text(lines[2].card[3]) == "☆ optio Gaius ▴▴", { text(lines[2].card[1]), text(lines[2].card[3]) })
		check("a contubernium shows its decanus first", text(lines[3].card[1]) == "★ decanus Lucius ▴▴" and text(lines[3].card[2]) == "contubernium · split the api · 2 milites" and lines[3].card[3] == "")
		check("each miles shows his rank beside his name, his post and his state", lines[4].card[1] == "Quintus ▴ hastatus · 1/3 to princeps" and lines[4].card[2] == "faber" and lines[4].miles_id == "quintus", lines[4].card)
		check("a miles still starting shows it", lines[5].card[3] == "starting")
		check("a unit without its leader yet says so", text(legio_mapper.to_legion_thread({ id = "v", ranks = {}, cohors = { kind = "cohors", id = "c", label = "x", milites = {}, units = {} } }).items[2].card[1]) == "★ primus pilus none yet")
		check("the thread finds a line by id", thread:index_of(lines[3].id) == 4)
		check("Enter on a legio lands on its cohors", thread:latest_turn() == thread.items[2])
		check("a legio in reserve has nothing inside", #legio_mapper.to_legion_thread({ id = "ix", name = "Legio IX Speculatrix" }).items == 0)
	end)

	test("the deploy picker says which legio is on a campaign", function()
		local picks = legio_mapper.to_deploy_picks({ legio, { id = "iv", name = "Legio IV Obsidionalis", munus = "test and break", deployed = false } })
		check("a deployed legio is tagged on campaign with where", picks[1].tag == "on campaign" and picks[1].description == "implement · on agentd sdk" and picks[1].deployed)
		check("a legio in reserve is tagged in reserve", picks[2].tag == "in reserve" and picks[2].description == "test and break" and not picks[2].deployed)
	end)

	test("in the miles list a legio's leaders come before the milites they lead", function()
		local function row(id, role, label, position)
			return miles_mapper.to_miles_row({ id = id, name = id, root = "/p", state = "idle", running = true, legio = "x", role = role }, id, label, position)
		end
		local rows = { row("q", "faber", "split", 2), row("l", "decanus", "split", 1), row("g", "optio"), row("m", "centurio"), row("free", nil) }
		rows[5] = miles_mapper.to_miles_row({ id = "free", name = "free", root = "/p", state = "idle", running = true }, "free")
		table.sort(rows, function(a, b)
			return a.sort_name < b.sort_name
		end)
		local order = vim.tbl_map(function(r)
			return r.id
		end, rows)
		check("centurio, optio, then the decanus and his milites, then the rest", table.concat(order, " ") == "m g l q free", order)
		local first = miles_mapper.to_card_lines(rows[1])[1]
		check("leaders are marked and drawn in the leader colour", first.segments[1][1] == "★ m" and first.segments[1][2] == "lead" and miles_mapper.to_card_lines(rows[2])[1].segments[1][1] == "☆ g")
		check("milites below a decanus are nested with a thin bar", rows[3].indent == "  " and rows[4].indent == "    " and rows[4].bar == "▏")
		check("only leaders show unread", miles_mapper.to_miles_row({ id = "s", name = "s", root = "/p", state = "idle", running = true, legio = "x", role = "faber", unread = true }).unread == nil and miles_mapper.to_miles_row({ id = "c", name = "c", root = "/p", state = "idle", running = true, legio = "x", role = "centurio", unread = true }).unread == true)
		check("a miles outside a legio keeps the plain card", rows[5].indent == nil and rows[5].bar == nil and rows[5].mark == nil)
	end)

	test("a miles card shows his rank and role", function()
		local row = miles_mapper.to_miles_row({ id = "m1", name = "Quintus", root = "/p", state = "working", busy = true, running = true, legio = "x", rank = "princeps", standing = standings.princeps, role = "faber" })
		local lines = miles_mapper.to_card_lines(row)
		check("the role is on the place line", lines[2]:find("· faber", 1, true) ~= nil, lines[2])
		check("the rank gets its own row: chevrons and progress", lines[4].segments[1][1] == "▴▴ princeps" and lines[4].segments[1][2] == "busy" and lines[4].segments[2][1] == " · 5/10 to triarius", lines[4])
		local plain = miles_mapper.to_card_lines(miles_mapper.to_miles_row({ id = "m2", name = "Gaius", root = "/p", state = "idle", running = true }))
		check("a miles outside a legio shows neither", not plain[2]:find("·", 1, true) or not plain[2]:find("hastatus", 1, true))
	end)
	test("legion sidebar: a cohors card names the codebase bare, with no cohors prefix", function()
		local dto_mapper = require("workspace.legio.application.mappers.legio_dto_mapper")
		local Cohors = require("workspace.legio.domain.cohors")
		local none = function()
			return nil
		end
		local unit = dto_mapper.to_cohors_unit(Cohors.form("/Users/talaerts/.config", 1), nil, none)
		check("the cohors label is the bare codebase name, with no 'cohors' prefix", unit.label == ".config", unit.label)
	end)
end

local Provider = require("workspace.shared.providers").current()
local function raw(moment, fields)
	return Provider.raw(moment, fields)
end
local function event(moment, fields)
	return Provider.session_event(Provider.raw(moment, fields))
end
local LegioProcess = require("workspace.legio.application.legio_process")
local HandoverProcess = require("workspace.legio.application.handover_process")
local HandOverCommand = require("workspace.legio.application.commands.hand_over_command")
local LegioDto = require("workspace.legio.application.dto.legio_dto")
local DeployLegioCommand = require("workspace.legio.application.commands.deploy_legio_command")
local Cohors = require("workspace.legio.domain.cohors")

local filesystem = "workspace.legio.infrastructure.outbound.filesystem."

return function(t)
	local test, check = t.test, t.check

	local function mandatum(id, title, state)
		return { id = id, title = title, text = "# " .. title .. "\n\nDo " .. title .. ".", state = state or "open" }
	end

	local function setup(o)
		o = o or {}
		local store = t.make_store(vim.fn.tempname())
		local calls = { started = {}, resumed = {}, assigned = {}, sent = {}, released = {} }
		local next_id, next_random = 0, 0
		local expeditiones = o.expeditiones
			or {
				e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = { mandatum("m1", "split the api"), mandatum("m2", "move the bridge"), mandatum("m3", "old one", "done") } },
				e2 = { id = "e2", title = "sidebar", root = "/p", mandata = { mandatum("m4", "show ranks") } },
				e3 = { id = "e3", title = "nothing left", root = "/p", mandata = { mandatum("m5", "gone", "done") } },
			}
		local repos = {
			legiones = require(filesystem .. "legio_repository").new(store),
			cohortes = require(filesystem .. "cohors_repository").new(store),
			centuriae = require(filesystem .. "centuria_repository").new(store),
			contubernia = require(filesystem .. "contubernium_repository").new(store),
			milites = require(filesystem .. "miles_repository").new(store),
		}
		calls.held, calls.stopped, calls.models, calls.logged = {}, {}, {}, {}
		local runner = {
			new_miles_id = function()
				next_id = next_id + 1
				return ("m-%02d"):format(next_id)
			end,
			start = function(_, command, done)
				table.insert(calls.started, command)
				done(not (o.fails and o.fails(command)), "short")
			end,
			resume = function(_, command, done)
				table.insert(calls.resumed, command)
				done(true)
			end,
			hold_text = function(_, id, text)
				table.insert(calls.held, { id = id, text = text })
			end,
			set_model = function(_, command, done)
				table.insert(calls.models, command)
				done(not calls.model_fails)
			end,
			stop = function(_, id, done)
				table.insert(calls.stopped, { id = id, after = #calls.started })
				done(true)
			end,
		}
		local todos = {
			done_command = "todo",
			assign = function(id, miles)
				if o.taken == id then
					return false
				end
				calls.assigned[id] = miles
				return true
			end,
			send = function(id, miles, as)
				calls.sent[id] = { miles = miles, as = as }
			end,
			release = function(id, miles)
				calls.released[id] = miles
			end,
			text = function(id)
				return "# mandatum " .. id
			end,
			title = function(id)
				return "mandatum " .. id
			end,
		}
		local clock = function()
			return 100
		end
		local service = LegioProcess.new({
			legiones = repos.legiones,
			cohortes = repos.cohortes,
			centuriae = repos.centuriae,
			contubernia = repos.contubernia,
			milites = repos.milites,
			runner = runner,
			git = {
				locate = function()
					return { branch = "main" }
				end,
			},
			todos = todos,
			expeditiones = {
				get = function(id)
					return expeditiones[id]
				end,
				of = function(mandatum_id)
					for _, e in pairs(expeditiones) do
						for _, m in ipairs(e.mandata) do
							if m.id == mandatum_id then
								return e
							end
						end
					end
				end,
			},
			clock = clock,
			random = function(a, b)
				next_random = next_random + 1
				return a + next_random % (b - a + 1)
			end,
		})
		local handover = HandoverProcess.new({
			milites = repos.milites,
			contubernia = repos.contubernia,
			centuriae = repos.centuriae,
			cohortes = repos.cohortes,
			legiones = repos.legiones,
			runner = runner,
			todos = todos,
			clock = clock,
			log = function(entry)
				table.insert(calls.logged, entry)
			end,
		})
		return service, calls, store, handover
	end

	local function by_name(list)
		local out = {}
		for _, l in ipairs(list) do
			out[l.id] = l
		end
		return out
	end

	test("legion: the three legiones are raised once, with empty annales", function()
		local service = setup()
		service:raise_legiones()
		service:raise_legiones()
		local list = service:legiones()
		check("three legiones in standing order", #list == 3 and list[1].name == "Legio X Rapax" and list[2].name == "Legio IV Obsidionalis" and list[3].name == "Legio IX Speculatrix", list)
		check("each is a LegioDto with its munus and roles", LegioDto.is(list[1]) and list[1].munus == "implement" and #list[1].roles == 3 and list[3].roles[1] == "explorator")
		check("annales and mos maiorum start empty", #list[1].annales == 0 and #list[2].mos_maiorum == 0)
		check("a legio in reserve has no cohors", list[1].deployed == false and list[1].cohors == nil and list[1].expeditio == nil)
	end)

	local function started_with(calls, text)
		for _, c in ipairs(calls.started) do
			if c.prompt:find(text, 1, true) then
				return c
			end
		end
		return {}
	end

	local function started_by(calls, id)
		for _, c in ipairs(calls.started) do
			if c.id == id then
				return c
			end
		end
		return {}
	end

	test("legion: deploying on an expeditio musters a centuria with a contubernium per open mandatum", function()
		local service, calls, store = setup()
		service:raise_legiones()
		local result
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function(ok, r)
			result = { ok = ok, r = r }
		end)
		check("it deploys", result.ok and result.r.legio == "Legio X Rapax" and result.r.expeditio == "agentd sdk", result)
		check("primus pilus, centurio, optio and two contubernia of decanus, faber, probator, censor", #calls.started == 11 and result.r.size == 11, #calls.started)
		local models = {}
		for _, c in ipairs(calls.started) do
			models[c.model] = (models[c.model] or 0) + 1
		end
		check("models follow the posts: opus primus pilus, centurio and optio, sonnet decani, haiku the rest", models.opus == 3 and models.sonnet == 2 and models.haiku == 6, models)
		check("every miles starts in the expeditio's root with the default provider and mode", calls.started[1].cwd == "/p" and calls.started[1].provider == Provider.name and calls.started[1].mode == "auto")
		local centurio = started_with(calls, "centurio of Legio X Rapax")
		check("the centurio's orders name the expeditio and tell him to run legio status", centurio.prompt and centurio.prompt:find("split the api", 1, true) and centurio.prompt:find("run legio status", 1, true))
		check("the finished mandatum gets no contubernium", calls.assigned.m3 == nil and calls.assigned.m1 and calls.assigned.m2)
		check("each mandatum goes to its decanus", calls.sent.m1 and calls.sent.m1.miles == calls.assigned.m1 and started_by(calls, calls.assigned.m1).id == calls.assigned.m1)
		check("the decanus's orders say how to mark it done", started_by(calls, calls.assigned.m1).prompt:find("todo done m1", 1, true) ~= nil, started_by(calls, calls.assigned.m1).prompt)

		local legio = by_name(service:legiones())["x-rapax"]
		check("the legio shows the expeditio by title", legio.deployed and legio.expeditio == "agentd sdk")
		local cohors = legio.cohors
		check("cohors > centuria > two contubernia", cohors.kind == "cohors" and cohors.units[1].kind == "centuria" and #cohors.units[1].units == 2)
		local centuria = cohors.units[1]
		check("the centuria names centurio and optio", centuria.leader.post == "centurio" and centuria.second.post == "optio", centuria.leader.name)
		check("the primus pilus leads the cohors, and the centurio leads only his centuria", cohors.leader.post == "primus pilus" and cohors.leader.miles_id ~= centuria.leader.miles_id, cohors.leader)
		local squad = centuria.units[1]
		check("a contubernium has a decanus and three milites with roles", squad.leader.post == "decanus" and #squad.milites == 3 and squad.milites[1].post == "faber" and squad.milites[3].post == "censor")
		check("a new miles is a hastatus", squad.milites[1].rank == "hastatus")

		local miles = require(filesystem .. "miles_repository").new(store):find(calls.assigned.m1)
		check("the miles is enlisted with his roman name and role", miles.legio == "x-rapax" and miles.role == "decanus" and miles.roman_name == squad.leader.name and miles:is_enlisted())
		check("his title says who he is and what he works on", miles.title == squad.leader.name .. " · decanus · split the api", miles.title)
		check("the annales record the deployment", #legio.annales == 1 and legio.annales[1]:find("agentd sdk", 1, true))

		local again
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e2" }), function(ok, why)
			again = { ok = ok, why = why }
		end)
		check("a deployed legio can't deploy again", not again.ok and again.why:find("already", 1, true))
	end)

	local function veteran(store, id, name, mandata, expeditiones)
		require(filesystem .. "miles_repository").new(store):update(id, function(m)
			m.state, m.legio, m.role, m.roman_name = "stopped", "x-rapax", "faber", name
			m.mandata, m.expeditiones = mandata, expeditiones
		end)
	end

	test("legion: deploying resumes the veterans as leaders", function()
		local service, calls, store = setup()
		service:raise_legiones()
		veteran(store, "v-tri", "Servius", { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" }, {})
		veteran(store, "v-pri", "Manius", { "a", "b", "c" }, {})
		veteran(store, "v-has", "Spurius", { "a" }, {})
		local result
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function(ok, r)
			result = { ok = ok, r = r }
		end)
		check("it deploys with the primus pilus, ten milites and the centurio", result.ok and result.r.size == 11, result)
		check("only the triarius and the princeps resume", #calls.resumed == 2 and calls.resumed[1].miles_id == "v-tri" and calls.resumed[2].miles_id == "v-pri", calls.resumed)
		check("the other nine start new, the primus pilus among them", #calls.started == 9)
		local centuria = by_name(service:legiones())["x-rapax"].cohors.units[1]
		check("the triarius is centurio", centuria.leader.miles_id == "v-tri" and centuria.leader.name == "Servius")
		check("the optio is new and the princeps leads a contubernium", centuria.second.miles_id ~= "v-pri" and calls.sent.m1.miles == "v-pri")
		check("the resumed centurio gets his orders", calls.resumed[1].prompt:find("centurio of Legio X Rapax", 1, true) ~= nil)
		local repo = require(filesystem .. "miles_repository").new(store)
		check("the triarius is enlisted as centurio", repo:find("v-tri").role == "centurio" and repo:find("v-tri").title:find("centurio", 1, true))
		check("the hastatus keeps his place in reserve", repo:find("v-has").role == "faber")
		check("no new miles takes a veteran's name", not (calls.started[1].prompt:find("You are Servius,", 1, true) or calls.started[1].prompt:find("You are Manius,", 1, true)))
	end)

	test("legion: a second triarius is optio and principes lead contubernia", function()
		local service, calls, store = setup()
		service:raise_legiones()
		veteran(store, "v-tri", "Servius", {}, { "x", "y", "z" })
		veteran(store, "v-tri2", "Tiberius", {}, { "x", "y", "z" })
		veteran(store, "v-p1", "Manius", { "a", "b", "c" }, {})
		veteran(store, "v-p2", "Titus", { "a", "b", "c" }, {})
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		check("four resume and seven start, the primus pilus among them", #calls.resumed == 4 and #calls.started == 7, { #calls.resumed, #calls.started })
		local posts = {}
		for _, c in ipairs(calls.resumed) do
			posts[c.miles_id] = c.prompt:match("as? (%a+) of Legio") or c.prompt:match(", (%a+) of Legio")
		end
		check("the first triarius is centurio, the second optio, two principes decani", posts["v-tri"] == "centurio" and posts["v-tri2"] == "optio" and posts["v-p1"] == "decanus" and posts["v-p2"] == "decanus", posts)
		check("each decanus holds his mandatum", calls.assigned.m1 and calls.assigned.m2 and calls.sent.m1.miles ~= calls.sent.m2.miles)
	end)

	test("legion: a princeps left after the decani becomes optio", function()
		local service, calls, store = setup()
		service:raise_legiones()
		veteran(store, "v-tri", "Servius", {}, { "x", "y", "z" })
		veteran(store, "v-p1", "Manius", { "a", "b", "c" }, {})
		veteran(store, "v-p2", "Titus", { "a", "b", "c" }, {})
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e2" }), function() end)
		local posts = {}
		for _, c in ipairs(calls.resumed) do
			posts[c.miles_id] = c.prompt:match(", (%a+) of Legio")
		end
		check("triarius centurio, one princeps decanus, the other optio", posts["v-tri"] == "centurio" and posts["v-p1"] == "decanus" and posts["v-p2"] == "optio", posts)
		check("no new miles replaces a veteran; the primus pilus and his three milites start", #calls.resumed == 3 and #calls.started == 4, { #calls.resumed, #calls.started })
	end)

	test("legion: equal ranks are ordered by roman name", function()
		local service, calls, store = setup()
		service:raise_legiones()
		veteran(store, "v-t", "Titus", {}, { "x", "y", "z" })
		veteran(store, "v-s", "Servius", {}, { "x", "y", "z" })
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e2" }), function() end)
		check("Servius leads and Titus is optio", calls.resumed[1].miles_id == "v-s" and calls.resumed[2].miles_id == "v-t", calls.resumed)
	end)

	test("legion: an idle contubernium takes a mandatum added to its expeditio", function()
		local expeditiones = {
			e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = { mandatum("m1", "split the api"), mandatum("m2", "move the bridge") } },
		}
		local service, calls = setup({ expeditiones = expeditiones })
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		expeditiones.e1.mandata[1].assignee, expeditiones.e1.mandata[2].assignee = calls.assigned.m1, calls.assigned.m2
		table.insert(expeditiones.e1.mandata, mandatum("m9", "show ranks"))
		local busy = service:offer_mandatum("m9")
		check("every contubernium busy: the new mandatum waits", busy and busy.waits and not calls.assigned.m9, busy)
		local centurio = by_name(service:legiones())["x-rapax"].cohors.units[1].leader.miles_id
		local told = calls.held[#calls.held]
		check("the centurio is told it waits for a free contubernium", told and told.id == centurio and told.text:find("waits for a free contubernium", 1, true), told)
		expeditiones.e1.mandata[1].state = "done"
		local taken = service:offer_mandatum("m9")
		check("a contubernium whose mandatum is done takes it", taken and taken.taken and calls.assigned.m9 == calls.assigned.m1, taken)
		local order = calls.held[#calls.held]
		check("its decanus gets the order", order.id == calls.assigned.m1 and order.text:find("show ranks", 1, true) and order.text:find("todo done m9", 1, true), order)
		check("a finished earlier mandatum is said to be finished", order.text:find("last mandatum is finished", 1, true) and not order.text:find("stays yours", 1, true), order)
		check("the mandatum is sent to him", calls.sent.m9 and calls.sent.m9.miles == calls.assigned.m1)
	end)

	test("legion: a contubernium that is built and reviewed stands by and takes waiting mandata", function()
		local expeditiones = {
			e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = { mandatum("m1", "split the api"), mandatum("m2", "move the bridge") } },
		}
		local service, calls = setup({ expeditiones = expeditiones })
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		expeditiones.e1.mandata[1].assignee, expeditiones.e1.mandata[2].assignee = calls.assigned.m1, calls.assigned.m2
		table.insert(expeditiones.e1.mandata, mandatum("m9", "show ranks"))
		service:offer_mandatum("m9")
		local ok = service:stand_by(calls.assigned.m1)
		check("the decanus stands the contubernium by", ok == true)
		check("it takes the waiting mandatum although m1 isn't marked done", calls.assigned.m9 == calls.assigned.m1, calls.assigned)
		check("his order says the earlier mandatum stays his to mark done", calls.held[#calls.held].text:find("stays yours", 1, true) ~= nil, calls.held[#calls.held])
		table.insert(expeditiones.e1.mandata, mandatum("m10", "another"))
		local second = service:offer_mandatum("m10")
		check("a contubernium that took one is not handed a second", second and second.waits and not calls.assigned.m10, second)
		local _, why = service:stand_by("nobody")
		check("a miles outside any contubernium can't stand by", why ~= nil)
	end)

	test("legion: a legio of only hastati starts new milites", function()
		local service, calls, store = setup()
		service:raise_legiones()
		veteran(store, "v-has", "Spurius", { "a" }, {})
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		check("nobody resumes and eleven start, the primus pilus among them", #calls.resumed == 0 and #calls.started == 11)
	end)

	test("legion: a second legio in the same codebase joins the cohors", function()
		local service = setup()
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		local result
		service:deploy(DeployLegioCommand.new({ legio_id = "iv-obsidionalis", expeditio_id = "e2" }), function(ok, r)
			result = { ok = ok, r = r }
		end)
		local list = by_name(service:legiones())
		local first, second = list["x-rapax"].cohors, list["iv-obsidionalis"].cohors
		check("it deploys with a decanus, probator and censor", result.ok and result.r.size == 5, result)
		check("both report to one cohors led by its primus pilus", first.id == second.id and second.leader.post == "primus pilus" and second.leader.miles_id == first.leader.miles_id)
		check("each legio sees its own centuria", second.units[1].label == "centuria sidebar" and first.units[1].label == "centuria agentd sdk")
		local names = {}
		for _, unit in ipairs({ first.units[1], second.units[1] }) do
			names[unit.leader.name] = (names[unit.leader.name] or 0) + 1
		end
		check("roman names are unique within a legio: each centurio keeps his own name", names.Gaius == 1 and names.Marcus == 1, names)
	end)

	test("legion: deploy refuses when it can't muster", function()
		local service, calls = setup({ taken = "m2" })
		service:raise_legiones()
		local outcomes = {}
		local function try(legio, expeditio)
			service:deploy(DeployLegioCommand.new({ legio_id = legio, expeditio_id = expeditio }), function(ok, why)
				table.insert(outcomes, { ok = ok, why = why })
			end)
		end
		try("x-rapax", "e3")
		try("x-rapax", "nope")
		try("nope", "e1")
		try("x-rapax", "e1")
		check("an expeditio without open mandata", not outcomes[1].ok and outcomes[1].why:find("no open mandata", 1, true))
		check("an unknown expeditio or legio", not outcomes[2].ok and not outcomes[3].ok)
		check("a mandatum sent elsewhere releases the ones already assigned", not outcomes[4].ok and calls.released.m1 == calls.assigned.m1 and #calls.started == 0)
		check("and the legio stays in reserve", by_name(service:legiones())["x-rapax"].deployed == false)
	end)

	test("legion: a miles rises in rank with finished mandata and expeditiones", function()
		local Miles = require("workspace.legio.domain.miles")
		local miles = Miles:new({ id = "m" })
		check("a new miles is a hastatus", miles:rank() == "hastatus")
		miles:finish_mandatum("a")
		miles:finish_mandatum("b")
		local added, rank = miles:finish_mandatum("c")
		check("3 mandata make a princeps", added and rank == "princeps" and miles:rank() == "princeps")
		check("the same mandatum counts once", not miles:finish_mandatum("c") and #miles.mandata == 3)
		for i = 4, 10 do
			miles:finish_mandatum("m" .. i)
		end
		check("10 mandata make a triarius", miles:rank() == "triarius")
		local veteran = Miles:new({ id = "v" })
		for i = 1, 3 do
			veteran:finish_expeditio("e" .. i)
		end
		check("3 expeditiones make a triarius too", veteran:rank() == "triarius")
		local dto = require("workspace.legio.application.mappers.miles_dto_mapper").to_miles_dto(Miles:new({ id = "p", state = "idle", root = "/p", legio = "x-rapax", mandata = { "a", "b", "c" } }), 1)
		local view_mapper = require("workspace.legio.presentation.mappers.miles_view_mapper")
		local lines = view_mapper.to_card_lines(view_mapper.to_miles_row(dto))
		check("his card says princeps with two chevrons and how far triarius is", lines[4].segments[1][1] == "▴▴ princeps" and lines[4].segments[2][1] == " · 3/10 to triarius", lines)
		local scout = Miles.standing_of(4, 2)
		check("progress follows whichever path is closer: 2 of 3 expeditiones beats 4 of 10 mandata", scout.unit == "expeditiones" and scout.done == 2 and scout.needed == 3)
		check("a triarius has no next rank", Miles.standing_of(10, 0).next == nil and Miles.standing_of(10, 0).level == 3)
	end)

	test("legion: finished mandata are credited to their contubernium, and a finished expeditio discharges the legio", function()
		local expeditiones = {
			e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = { mandatum("m1", "split the api"), mandatum("m2", "move the bridge") } },
		}
		local service, calls, store = setup({ expeditiones = expeditiones })
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		local milites = require(filesystem .. "miles_repository").new(store)
		local decanus = calls.assigned.m1
		local squad = require(filesystem .. "contubernium_repository").new(store):all()
		local faber
		for _, c in ipairs(squad) do
			if c.todo == "m1" then
				faber = c.members[2].miles
			end
		end
		expeditiones.e1.mandata[1].state, expeditiones.e1.mandata[1].assignee = "done", decanus
		service:credit_finished()
		service:credit_finished()
		check("the decanus and his milites get the mandatum once", #milites:find(decanus).mandata == 1 and #milites:find(faber).mandata == 1)
		check("the other contubernium gets nothing", #(milites:find(calls.assigned.m2).mandata or {}) == 0)
		check("the legio stays deployed while a mandatum is open", by_name(service:legiones())["x-rapax"].deployed)

		check("nobody is stood down while a mandatum is open", #calls.stopped == 0)
		expeditiones.e1.mandata[2].state, expeditiones.e1.mandata[2].assignee = "done", calls.assigned.m2
		local stood_down = false
		service:credit_finished(calls.assigned.m2, function()
			stood_down = true
		end)
		local centurio = require(filesystem .. "centuria_repository").new(store):all()[1].centurio
		local legio = by_name(service:legiones())["x-rapax"]
		check("the whole centuria is credited with the expeditio", #milites:find(centurio).expeditiones == 1 and #milites:find(faber).expeditiones == 1)
		check("the legio is discharged back to reserve", not legio.deployed)
		check("the annales record the end and the missio", legio.annales[#legio.annales - 1]:find("finished agentd sdk", 1, true) and legio.annales[#legio.annales] == "missio: 11 milites stood down", legio.annales)
		check("every miles of the legio is stopped, the primus pilus included", stood_down and #calls.stopped == 11, calls.stopped)
		check("the decanus who marked it done is stopped last, since the command runs in his session", calls.stopped[11].id == calls.assigned.m2 and calls.stopped[1].id ~= calls.assigned.m2)
		service:credit_finished()
		check("a finished legio isn't stood down twice", #calls.stopped == 11)
	end)

	local function deployed()
		local service, calls, store, handover = setup()
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e2" }), function() end)
		local milites = require(filesystem .. "miles_repository").new(store)
		local contubernia = require(filesystem .. "contubernium_repository").new(store)
		local runtimes = require(filesystem .. "miles_process_repository").new(store)
		local function context(id, used)
			runtimes:update(id, function(r)
				return r:observe({ event = "context", used = used, window = 100 }, 1)
			end)
		end
		local squad = contubernia:all()[1]
		local centuria = require(filesystem .. "centuria_repository").new(store):all()[1]
		local ids = { centurio = centuria.centurio, optio = centuria.optio }
		for _, m in ipairs(squad.members) do
			ids[m.role] = m.miles
		end
		return { service = service, calls = calls, store = store, handover = handover, milites = milites, contubernia = contubernia, context = context, ids = ids }
	end

	local function hand_over(l, id, text)
		local result
		l.handover:hand_over(HandOverCommand.new({ miles_id = id, traditio = text }), function(ok, r)
			result = { ok = ok, r = r }
		end)
		return result
	end

	test("legion: the centurio's account and the milites' ranks go into the annales when the legio is discharged", function()
		local expeditiones = {
			e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = { mandatum("m1", "split the api") } },
		}
		local service, calls, store = setup({ expeditiones = expeditiones })
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		local centurio = require(filesystem .. "centuria_repository").new(store):all()[1].centurio
		local decanus = calls.assigned.m1
		require(filesystem .. "miles_repository").new(store):update_existing(decanus, function(m)
			m.mandata = { "old1", "old2" }
		end)
		local RecordAccountCommand = require("workspace.legio.application.commands.record_account_command")
		check("a decanus can't write the account", service:record_account(RecordAccountCommand.new({ from = decanus, text = "mine" })) == nil)
		check("the centurio's prompt tells him how", started_by(calls, centurio).prompt:find("legio annales", 1, true) ~= nil)
		check("the decanus's prompt doesn't", started_by(calls, decanus).prompt:find("legio annales", 1, true) == nil)
		local told = #calls.started > 0
		for _, started in ipairs(calls.started) do
			told = told and started.prompt:find("legio lesson", 1, true) ~= nil
		end
		check("every deployed miles is told how to record a lesson", told)
		check("the centurio writes the account", service:record_account(RecordAccountCommand.new({ from = centurio, text = "api split, bridge moved" })))
		check("a later account replaces it", service:record_account(RecordAccountCommand.new({ from = centurio, text = "api split in two commits" })))
		expeditiones.e1.mandata[1].state, expeditiones.e1.mandata[1].assignee = "done", decanus
		service:credit_finished(decanus)
		local annales = by_name(service:legiones())["x-rapax"].annales
		local text = table.concat(annales, "\n")
		check("the annales hold the centurio's account", text:find("account: api split in two commits", 1, true) ~= nil, annales)
		check("the account is credited to its author", text:find(require(filesystem .. "miles_repository").new(store):find(centurio).roman_name .. "'s account", 1, true) ~= nil, annales)
		local late, why = service:record_account(RecordAccountCommand.new({ from = centurio, text = "too late" }))
		check("an account after the discharge is refused", late == nil and why ~= nil, why)
		check("the annales hold who rose in rank", text:find("became princeps", 1, true) ~= nil, annales)
	end)

	test("legion: a lesson goes into the mos maiorum and lands in the first order of every new miles and supplementum", function()
		local l = deployed()
		local RecordLessonCommand = require("workspace.legio.application.commands.record_lesson_command")
		check("a lesson is added", l.service:record_lesson(RecordLessonCommand.new({ from = l.ids.faber, text = "run the suite before reporting" })))
		local _, again = l.service:record_lesson(RecordLessonCommand.new({ from = l.ids.faber, text = "run the suite before reporting" }))
		check("the same lesson isn't added twice", again == false)
		check("a stranger can't add one", l.service:record_lesson(RecordLessonCommand.new({ from = "stranger", text = "x" })) == nil)
		local mos = by_name(l.service:legiones())["x-rapax"].mos_maiorum
		check("the mos maiorum holds it once", #mos == 1, mos)
		hand_over(l, l.ids.probator, "tests half written")
		local supplementum = l.calls.started[#l.calls.started]
		check("the supplementum's first order lists it", supplementum.prompt:find("Mos maiorum", 1, true) and supplementum.prompt:find("run the suite before reporting", 1, true), supplementum.prompt)
	end)

	test("legion: a lesson given with a traditio goes into the mos maiorum", function()
		local l = deployed()
		local result
		l.handover:hand_over(HandOverCommand.new({ miles_id = l.ids.censor, traditio = "review half done", lesson = "read the diff before the tests" }), function(ok, r)
			result = { ok = ok, r = r }
		end)
		local mos = by_name(l.service:legiones())["x-rapax"].mos_maiorum
		check("the lesson is in the mos maiorum", result.ok and #mos == 1 and tostring(mos[1].text or mos[1]):find("read the diff", 1, true), mos)
		check("his supplementum is told it", l.calls.started[#l.calls.started].prompt:find("read the diff before the tests", 1, true) ~= nil)
	end)

	test("legion: at 90% context a miles with a post is told to write his traditio, once", function()
		local l = deployed()
		l.context(l.ids.probator, 95)
		l.context(l.ids.censor, 50)
		local block = l.handover:check_stop(event("stop", { session_id = l.ids.probator }))
		check("the stop is blocked with the traditio order", block and block.decision == "block" and block.reason:find("traditio", 1, true) and block.reason:find("95%", 1, true), block)
		check("he is handing over", l.milites:find(l.ids.probator).state == "handing_over")
		check("he isn't asked twice", l.handover:check_stop(event("stop", { session_id = l.ids.probator })) == nil)
		check("a miles at 50% just stops", l.handover:check_stop(event("stop", { session_id = l.ids.censor })) == nil)
		check("a stop hook that already blocked isn't blocked again", l.handover:check_stop(event("stop", { session_id = l.ids.censor, stop_hook_active = true })) == nil)
		check("a miles outside a legio is left alone", l.handover:check_stop(event("stop", { session_id = "stranger" })) == nil)
	end)

	test("legion: a fallen miles is replaced by a supplementum who gets his traditio first", function()
		local l = deployed()
		local result = hand_over(l, l.ids.probator, "tests half written on feat/x")
		local fallen = l.milites:find(l.ids.probator)
		check("he is fallen with his traditio kept", result.ok and fallen.state == "fallen" and fallen.traditio.text == "tests half written on feat/x", result)
		local supplementum = l.calls.started[#l.calls.started]
		check("a supplementum starts on haiku as probator", supplementum.model == "haiku" and result.r.role == "probator" and result.r.supplementum ~= nil)
		check("his first order is the traditio", supplementum.prompt:find("^You are a supplementum") and supplementum.prompt:find("tests half written on feat/x", 1, true) and supplementum.prompt:find("probator of Legio X Rapax", 1, true))
		local squad = l.contubernia:all()[1]
		local roles = {}
		for _, m in ipairs(squad.members) do
			roles[m.role] = m.miles
		end
		check("he takes the fallen's place in the contubernium", roles.probator == supplementum.id and not squad:has(l.ids.probator))
		local joined = l.milites:find(supplementum.id)
		check("he is an enlisted hastatus", joined.legio == "x-rapax" and joined.role == "probator" and joined:rank() == "hastatus")
		check("the fallen's session is stopped last", l.calls.stopped[1].id == l.ids.probator and l.calls.stopped[1].after == #l.calls.started)
		local legio = by_name(l.service:legiones())["x-rapax"]
		check("the annales say who fell and who joined", legio.annales[#legio.annales]:find("fell", 1, true) and legio.annales[#legio.annales]:find("joined as probator", 1, true), legio.annales)
	end)

	test("legion: when a decanus falls the most senior miles leads, and the supplementum takes his role", function()
		local l = deployed()
		l.milites:update(l.ids.censor, function(m)
			m.mandata = { "a", "b", "c" }
		end)
		local result = hand_over(l, l.ids.decanus, "the split is agreed")
		local squad = l.contubernia:all()[1]
		check("the princeps censor is decanus now", squad:decanus().miles == l.ids.censor and l.milites:find(l.ids.censor).role == "decanus", squad.members)
		check("he is told, with the traditio", l.calls.held[1].id == l.ids.censor and l.calls.held[1].text:find("the split is agreed", 1, true))
		check("the supplementum becomes censor", result.r.role == "censor" and result.r.successor ~= nil)
	end)

	test("legion: when the centurio falls his optio steps up and leads the cohors", function()
		local l = deployed()
		local pilus = by_name(l.service:legiones())["x-rapax"].cohors.leader.miles_id
		local result = hand_over(l, l.ids.centurio, "expeditio half done")
		local legio = by_name(l.service:legiones())["x-rapax"]
		local centuria = legio.cohors.units[1]
		check("the optio is centurio", centuria.leader.miles_id == l.ids.optio and l.milites:find(l.ids.optio).role == "centurio")
		check("the supplementum is the new optio on opus", result.r.role == "optio" and centuria.second.miles_id == l.calls.started[#l.calls.started].id and l.calls.started[#l.calls.started].model == "opus")
		check("the primus pilus still leads the cohors when a centurio falls", legio.cohors.leader.miles_id == pilus and legio.cohors.leader.post == "primus pilus")
	end)

	test("legion: a miles without a post can't hand over, and an enlisted miles keeps his record when his session ends", function()
		local l = deployed()
		check("no post, no handover", not hand_over(l, "stranger", "x").ok)
		local events = require("workspace.composition_root").build(l.store).miles_session_events
		local SessionEventCommand = require("workspace.legio.application.commands.session_event_command")
		events:apply(SessionEventCommand.new({ payload = event("end", { session_id = l.ids.faber, cwd = "/p" }), background = true }))
		local faber = l.milites:find(l.ids.faber)
		check("his record stays, stopped", faber and faber.state == "stopped" and faber.role == "faber")
		check("he stays in his contubernium", l.contubernia:all()[1]:has(l.ids.faber))
	end)

	test("legion: reports go up the chain of command and orders go down", function()
		local l = deployed()
		local Send = require("workspace.legio.application.commands.send_legio_message_command")
		local names = l.service:report(Send.new({ from = l.ids.faber, text = "the api compiles" }))
		local decanus = l.milites:find(l.ids.decanus).roman_name
		check("a miles reports to his decanus", names and names[1] == decanus and l.calls.held[1].id == l.ids.decanus and l.calls.held[1].text:find("(faber) reports: the api compiles", 1, true), l.calls.held)
		l.service:report(Send.new({ from = l.ids.decanus, text = "half done" }))
		check("a decanus reports to his optio", l.calls.held[2].id == l.ids.optio)
		l.service:report(Send.new({ from = l.ids.optio, text = "all quiet" }))
		check("an optio reports to his centurio", l.calls.held[3].id == l.ids.centurio)
		local pilus = by_name(l.service:legiones())["x-rapax"].cohors.leader.miles_id
		local to_pilus = l.service:report(Send.new({ from = l.ids.centurio, text = "x" }))
		check("a centurio reports to his primus pilus", to_pilus and to_pilus[1] == l.milites:find(pilus).roman_name and l.calls.held[#l.calls.held].id == pilus, l.calls.held)
		local _, why = l.service:report(Send.new({ from = pilus, text = "x" }))
		check("the primus pilus reports to the commander in his reply", why and why:find("commander", 1, true), why)

		local sent = l.service:order(Send.new({ from = l.ids.decanus, to = "all", text = "rebase onto main" }))
		check("a decanus orders all his milites", #sent == 3 and l.calls.held[#l.calls.held].text:find("^Order from"), sent)
		local one = l.service:order(Send.new({ from = l.ids.centurio, to = decanus, text = "hurry" }))
		check("a centurio orders one decanus by name", #one == 1 and l.calls.held[#l.calls.held].id == l.ids.decanus)
		local _, nobody = l.service:order(Send.new({ from = l.ids.faber, to = "all", text = "x" }))
		check("a faber commands no one", nobody == "you command no one")
		local _, stranger = l.service:order(Send.new({ from = "stranger", to = "all", text = "x" }))
		check("a stranger holds no post", stranger:find("no post", 1, true))
	end)

	test("legion: when no miles starts, the legio goes back to reserve", function()
		local service, calls, store = setup({
			fails = function()
				return true
			end,
		})
		service:raise_legiones()
		local result
		service:deploy(DeployLegioCommand.new({ legio_id = "ix-speculatrix", expeditio_id = "e2" }), function(ok, why)
			result = { ok = ok, why = why }
		end)
		local legio = by_name(service:legiones())["ix-speculatrix"]
		check("deploy fails", not result.ok and result.why:find("started", 1, true), result)
		check("the decanus's mandatum is released", calls.released.m4 ~= nil)
		check("the legio is back in reserve with no cohors", not legio.deployed and legio.cohors == nil)
		check("no miles is enlisted", #require(filesystem .. "miles_repository").new(store):plain_all() == 0)
		check("no contubernium is left behind", #require(filesystem .. "contubernium_repository").new(store):all() == 0)
	end)

	local function primus_starts(l)
		local out = {}
		for _, c in ipairs(l.calls.started) do
			if c.prompt:find("^You are [^,]+, primus pilus of Legio") then
				table.insert(out, c)
			end
		end
		return out
	end

	local function started_as(l, id)
		for _, c in ipairs(l.calls.started) do
			if c.id == id then
				return c
			end
		end
	end

	local function cohors_at(l, root)
		return require(filesystem .. "cohors_repository").new(l.store):get(Cohors.key(root))
	end

	local function second_legio(l, expeditio)
		l.service:deploy(DeployLegioCommand.new({ legio_id = l.service:legiones()[2].id, expeditio_id = expeditio }), function() end)
	end

	test("legion: deploying where no cohors exists starts a primus pilus on opus who leads the centuriae", function()
		local l = deployed()
		local pilus = primus_starts(l)
		check("one primus pilus starts for the new cohors", #pilus == 1, #l.calls.started)
		local p = pilus[1] or {}
		check("he runs on opus in the codebase", p.model == "opus" and p.cwd == "/p", p)
		check("he is not the centurio", p.id ~= nil and p.id ~= l.ids.centurio)
		check("his orders say he leads the centuriae", p.prompt and p.prompt:find("lead", 1, true) and p.prompt:find("centuriae", 1, true), p.prompt)
		local cohors = cohors_at(l, "/p")
		check("the cohors records him as primus pilus", cohors ~= nil and p.id ~= nil and cohors.primus_pilus == p.id, cohors)
		local record = p.id and l.milites:find(p.id)
		local name = record and record.roman_name
		local centurio = started_as(l, l.ids.centurio) or {}
		check("the centurio's orders name him as superior", name ~= nil and centurio.prompt and centurio.prompt:find("You report to " .. name, 1, true) ~= nil, centurio.prompt)
	end)

	test("legion: a second deploy in the same cohors starts no other primus pilus", function()
		local l = deployed()
		local pilus = primus_starts(l)[1] or {}
		second_legio(l, "e1")
		check("still one primus pilus after the second deploy", #primus_starts(l) == 1, #primus_starts(l))
		local cohors = cohors_at(l, "/p")
		check("the cohors keeps the same primus pilus", cohors ~= nil and pilus.id ~= nil and cohors.primus_pilus == pilus.id, cohors)
	end)

	test("legion: when the primus pilus falls, the most senior centurio of the cohors becomes primus pilus", function()
		local l = deployed()
		second_legio(l, "e1")
		local pilus = primus_starts(l)[1]
		check("there is a primus pilus to fall", pilus ~= nil)
		if not pilus then
			return
		end
		local other
		for _, c in ipairs(l.calls.started) do
			if c.model == "opus" and c.id ~= pilus.id and c.id ~= l.ids.centurio and c.prompt:find("centurio of", 1, true) then
				other = c.id
			end
		end
		check("the second centuria has its own centurio", other ~= nil)
		if not other then
			return
		end
		l.milites:update(other, function(m)
			m.mandata = { "a", "b", "c" }
		end)
		local senior = l.milites:find(other):seniority() > l.milites:find(l.ids.centurio):seniority()
		check("the second centurio is more senior than the first", senior)
		local optio_before
		for _, c in ipairs(require(filesystem .. "centuria_repository").new(l.store):all()) do
			if c.centurio == other then
				optio_before = c.optio
			end
		end
		local result = hand_over(l, pilus.id, "cohors half done")
		check("the primus pilus can hand over", result and result.ok, result)
		local cohors = cohors_at(l, "/p")
		check("the most senior centurio is the new primus pilus", cohors ~= nil and cohors.primus_pilus == other, cohors)
		local supplementum = l.calls.started[#l.calls.started] or {}
		check("the new optio reports to the promoted centurio", optio_before ~= nil and supplementum.prompt:find("You report to " .. l.milites:find(optio_before).roman_name, 1, true) ~= nil, supplementum.prompt)
		local told = l.calls.held[#l.calls.held] or {}
		check("he is told, with the traditio", told.id == other and told.text and told.text:find("cohors half done", 1, true) ~= nil, l.calls.held)
	end)

	test("legion: with no centurio left in the cohors, a supplementum becomes primus pilus on opus", function()
		local l = deployed()
		local pilus = primus_starts(l)[1]
		check("there is a primus pilus to fall", pilus ~= nil)
		if not pilus then
			return
		end
		require(filesystem .. "cohors_repository").new(l.store):update_existing(Cohors.key("/p"), function(c)
			c.centuriae = {}
			return true
		end)
		local result = hand_over(l, pilus.id, "no one left to lead")
		check("the primus pilus can hand over", result and result.ok, result)
		local cohors = cohors_at(l, "/p")
		local supplementum = l.calls.started[#l.calls.started] or {}
		check("the supplementum starts on opus", supplementum.model == "opus" and supplementum.cwd == "/p", supplementum)
		check("the supplementum is the new primus pilus", cohors ~= nil and supplementum.id ~= nil and cohors.primus_pilus == supplementum.id and supplementum.id ~= pilus.id, cohors)
	end)
	test("legion: a primus pilus runs on while a second legio in his cohors is deployed, and is stood down with the last legio", function()
		local expeditiones = {
			e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = { mandatum("m1", "split the api") } },
			e2 = { id = "e2", title = "sidebar", root = "/p", mandata = { mandatum("m4", "show ranks") } },
		}
		local service, calls, store = setup({ expeditiones = expeditiones })
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		service:deploy(DeployLegioCommand.new({ legio_id = "iv-obsidionalis", expeditio_id = "e2" }), function() end)
		local list = by_name(service:legiones())
		local pilus = list["x-rapax"].cohors.leader.miles_id
		local function stopped(id)
			for _, s in ipairs(calls.stopped) do
				if s.id == id then
					return true
				end
			end
			return false
		end
		local function cohors()
			return require(filesystem .. "cohors_repository").new(store):get(Cohors.key("/p"))
		end
		check("both legiones share one primus pilus", pilus ~= nil and list["iv-obsidionalis"].cohors.leader.miles_id == pilus)

		local first_decanus = calls.assigned.m1
		expeditiones.e1.mandata[1].state, expeditiones.e1.mandata[1].assignee = "done", first_decanus
		service:credit_finished(first_decanus)
		check("the first legio is discharged", not by_name(service:legiones())["x-rapax"].deployed)
		check("the primus pilus is not stood down while the second legio is deployed", not stopped(pilus), calls.stopped)
		check("the cohors keeps him", cohors() ~= nil and cohors().primus_pilus == pilus)

		local second_decanus = calls.assigned.m4
		expeditiones.e2.mandata[1].state, expeditiones.e2.mandata[1].assignee = "done", second_decanus
		service:credit_finished(second_decanus)
		check("the second legio is discharged", not by_name(service:legiones())["iv-obsidionalis"].deployed)
		check("the primus pilus is stood down with the last legio", stopped(pilus), calls.stopped)
		check("the cohors has no primus pilus once the last legio is gone", cohors() ~= nil and cohors().primus_pilus == nil, cohors())
	end)
	test("legion: when the primus pilus falls, a centurio of a discharged legio is passed over for a deployed one", function()
		local expeditiones = {
			e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = { mandatum("m1", "split the api") } },
			e2 = { id = "e2", title = "sidebar", root = "/p", mandata = { mandatum("m4", "show ranks") } },
		}
		local service, calls, store, handover = setup({ expeditiones = expeditiones })
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		service:deploy(DeployLegioCommand.new({ legio_id = "iv-obsidionalis", expeditio_id = "e2" }), function() end)
		local list = by_name(service:legiones())
		local pilus = list["x-rapax"].cohors.leader.miles_id
		local centuriae = require(filesystem .. "centuria_repository").new(store):all()
		local senior, deployed_centurio
		for _, c in ipairs(centuriae) do
			if c.legio == "x-rapax" then
				senior = c.centurio
			elseif c.legio == "iv-obsidionalis" then
				deployed_centurio = c.centurio
			end
		end
		check("both legiones have a centurio in the cohors", senior ~= nil and deployed_centurio ~= nil and pilus ~= nil)
		require(filesystem .. "miles_repository").new(store):update_existing(senior, function(m)
			m.mandata = { "a", "b", "c" }
		end)

		local decanus = calls.assigned.m1
		expeditiones.e1.mandata[1].state, expeditiones.e1.mandata[1].assignee = "done", decanus
		service:credit_finished(decanus)
		check("the senior centurio's legio is discharged", not by_name(service:legiones())["x-rapax"].deployed)

		local result = hand_over({ handover = handover }, pilus, "cohors half done")
		check("the primus pilus can hand over", result and result.ok, result)
		local cohors = require(filesystem .. "cohors_repository").new(store):get(Cohors.key("/p"))
		check("the still-deployed centurio is the new primus pilus, not the discharged one", cohors ~= nil and cohors.primus_pilus == deployed_centurio and cohors.primus_pilus ~= senior, cohors)
	end)
	local function model_of(calls, id)
		local model
		for _, c in ipairs(calls.models) do
			if c.miles_id == id then
				model = c.model
			end
		end
		return model
	end

	test("legion: an optio promoted to centurio when the centurio falls gets the centurio's model, opus", function()
		local l = deployed()
		hand_over(l, l.ids.centurio, "expeditio half done")
		check("the optio is centurio on opus", l.milites:find(l.ids.optio).role == "centurio" and model_of(l.calls, l.ids.optio) == "opus", l.calls.models)
	end)

	test("legion: a centurio promoted to primus pilus gets opus", function()
		local l = deployed()
		l.service:deploy(DeployLegioCommand.new({ legio_id = l.service:legiones()[2].id, expeditio_id = "e1" }), function() end)
		local pilus = primus_starts(l)[1]
		check("there is a primus pilus to fall", pilus ~= nil)
		if not pilus then
			return
		end
		local other
		for _, c in ipairs(l.calls.started) do
			if c.model == "opus" and c.id ~= pilus.id and c.id ~= l.ids.centurio and c.prompt:find("centurio of", 1, true) then
				other = c.id
			end
		end
		check("the second centuria has its own centurio", other ~= nil)
		if not other then
			return
		end
		l.milites:update(other, function(m)
			m.mandata = { "a", "b", "c" }
		end)
		hand_over(l, pilus.id, "cohors half done")
		check("the most senior centurio is primus pilus on opus", l.milites:find(other).role == "primus pilus" and model_of(l.calls, other) == "opus", l.calls.models)
	end)

	test("legion: a decanus promoted in a contubernium gets sonnet", function()
		local l = deployed()
		l.milites:update(l.ids.censor, function(m)
			m.mandata = { "a", "b", "c" }
		end)
		hand_over(l, l.ids.decanus, "the split is agreed")
		check("the censor is decanus on sonnet", l.milites:find(l.ids.censor).role == "decanus" and model_of(l.calls, l.ids.censor) == "sonnet", l.calls.models)
	end)
	test("legion: when a primus pilus falls, the optio of the promoted centurio's centuria becomes centurio on opus", function()
		local l = deployed()
		l.service:deploy(DeployLegioCommand.new({ legio_id = l.service:legiones()[2].id, expeditio_id = "e1" }), function() end)
		local pilus = primus_starts(l)[1]
		check("there is a primus pilus to fall", pilus ~= nil)
		if not pilus then
			return
		end
		local other
		for _, c in ipairs(l.calls.started) do
			if c.model == "opus" and c.id ~= pilus.id and c.id ~= l.ids.centurio and c.prompt:find("centurio of", 1, true) then
				other = c.id
			end
		end
		if not other then
			check("the second centuria has its own centurio", false)
			return
		end
		l.milites:update(other, function(m)
			m.mandata = { "a", "b", "c" }
		end)
		local optio
		for _, c in ipairs(require(filesystem .. "centuria_repository").new(l.store):all()) do
			if c.centurio == other then
				optio = c.optio
			end
		end
		check("the promoted centurio has an optio", optio ~= nil)
		hand_over(l, pilus.id, "cohors half done")
		check("the optio is the new centurio of that centuria, on opus", optio ~= nil and l.milites:find(optio).role == "centurio" and model_of(l.calls, optio) == "opus", l.calls.models)
	end)

	test("legion: when the model can't be switched the promotion still completes, and the log says so", function()
		local l = deployed()
		l.calls.model_fails = true
		local result = hand_over(l, l.ids.centurio, "expeditio half done")
		check("the fall completes and the optio is centurio", result and result.ok and l.milites:find(l.ids.optio).role == "centurio", result)
		local logged = false
		for _, entry in ipairs(l.calls.logged) do
			if entry.event == "model not switched" and entry.miles == l.ids.optio then
				logged = true
			end
		end
		check("the log says the model was not switched", logged, l.calls.logged)
	end)

	test("legion: a contubernium is idle only when stood by or its mandatum is done, and remembers what it held", function()
		local Contubernium = require("workspace.legio.domain.contubernium")
		local c = Contubernium:new({ id = "t1", todo = "m1", members = {} })
		check("busy with an open mandatum", not c:is_idle("open"))
		check("idle once its mandatum is done", c:is_idle("done"))
		check("standing by makes it idle", c:stand_by(5) == true and c:is_idle("open"))
		c:stand_by(9)
		check("standing by again keeps the first time", c.stood_by == 5)
		c:take("m2")
		check("taking a mandatum ends the stand-by and makes it busy", c.todo == "m2" and c.stood_by == nil and not c:is_idle("open"))
		check("the mandatum it held before is remembered", c:held("m1") and c:held("m2") and not c:held("m3"))
		local fresh = Contubernium:new({ id = "t2", members = {} })
		fresh:take("m5")
		check("a first mandatum leaves no earlier ones", #fresh.earlier == 0 and fresh.todo == "m5")
	end)

	test("legion: a mandatum that is unknown, done, assigned or in a legio not deployed is not offered", function()
		local expeditiones = {
			e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = { mandatum("m1", "split the api"), mandatum("m2", "move the bridge") } },
			e2 = { id = "e2", title = "sidebar", root = "/p", mandata = { mandatum("m20", "not deployed") } },
		}
		local service, calls = setup({ expeditiones = expeditiones })
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		expeditiones.e1.mandata[1].assignee, expeditiones.e1.mandata[2].assignee = calls.assigned.m1, calls.assigned.m2
		table.insert(expeditiones.e1.mandata, mandatum("m8", "old one", "done"))
		table.insert(expeditiones.e1.mandata, mandatum("m9", "taken already"))
		expeditiones.e1.mandata[4].assignee = "someone-else"
		check("an unknown mandatum is not offered", service:offer_mandatum("nope") == nil and not calls.assigned.nope)
		check("a done mandatum is not offered", service:offer_mandatum("m8") == nil and not calls.assigned.m8)
		check("an already assigned mandatum is not offered", service:offer_mandatum("m9") == nil and not calls.assigned.m9)
		check("a mandatum of an expeditio no legio runs is not offered", service:offer_mandatum("m20") == nil and not calls.assigned.m20)
	end)

	test("legion: two stood-by contubernia each take a different waiting mandatum", function()
		local expeditiones = {
			e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = { mandatum("m1", "split the api"), mandatum("m2", "move the bridge") } },
		}
		local service, calls = setup({ expeditiones = expeditiones })
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		expeditiones.e1.mandata[1].assignee, expeditiones.e1.mandata[2].assignee = calls.assigned.m1, calls.assigned.m2
		local d1, d2 = calls.assigned.m1, calls.assigned.m2
		table.insert(expeditiones.e1.mandata, mandatum("m9", "show ranks"))
		table.insert(expeditiones.e1.mandata, mandatum("m10", "another"))
		service:offer_mandatum("m9")
		service:offer_mandatum("m10")
		service:stand_by(d1)
		expeditiones.e1.mandata[3].assignee = calls.assigned.m9
		service:stand_by(d2)
		expeditiones.e1.mandata[4].assignee = calls.assigned.m10
		check("each takes one", calls.assigned.m9 == d1 and calls.assigned.m10 == d2, { calls.assigned.m9, calls.assigned.m10, d1, d2 })
		check("and they are not the same decanus", calls.assigned.m9 ~= calls.assigned.m10)
	end)

	test("legion: a contubernium that stands by with nothing waiting takes the next mandatum offered", function()
		local expeditiones = {
			e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = { mandatum("m1", "split the api"), mandatum("m2", "move the bridge") } },
		}
		local service, calls = setup({ expeditiones = expeditiones })
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		expeditiones.e1.mandata[1].assignee, expeditiones.e1.mandata[2].assignee = calls.assigned.m1, calls.assigned.m2
		local ok = service:stand_by(calls.assigned.m1)
		check("standing by with nothing waiting is fine", ok == true and calls.assigned.m9 == nil)
		table.insert(expeditiones.e1.mandata, mandatum("m9", "show ranks"))
		local offered = service:offer_mandatum("m9")
		check("the next mandatum goes to the stood-by decanus", offered and offered.taken and calls.assigned.m9 == calls.assigned.m1, offered)
	end)

	test("legion: a miles outside any contubernium gets a reason, and a faber can't stand a contubernium by", function()
		local expeditiones = {
			e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = { mandatum("m1", "split the api"), mandatum("m2", "move the bridge") } },
		}
		local service, calls = setup({ expeditiones = expeditiones })
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		local ok, why = service:stand_by("nobody")
		check("a miles outside any contubernium is told why", ok == nil and why == "you are not in a contubernium", why)
		local faber
		for _, c in ipairs(calls.started) do
			if c.prompt:find("faber of Legio X Rapax", 1, true) and not faber then
				faber = c.id
			end
		end
		local faber_ok, faber_why = service:stand_by(faber)
		check("only a decanus stands a contubernium by", faber_ok == nil and faber_why ~= nil, faber_ok)
	end)

	test("legion: contubernium ready only works for a decanus, and only when stood by", function()
		local cli = require("workspace.legio.infrastructure.inbound.contubernium_cli")
		local Contubernium = require("workspace.legio.domain.contubernium")
		local nvim = require("workspace.shared.adapters.nvim")
		local composition_root = require("workspace.composition_root")
		local provider = require("workspace.shared.providers").current()
		local saved = { session = provider.current_session, store = nvim.new_store, logger = nvim.logger, build = composition_root.build }
		local decanus = Contubernium:new({ id = "t1", members = { { name = "Servius", miles = "d1", role = "decanus" }, { name = "Tiberius", miles = "f1", role = "faber" } } })
		local stood
		local function run(session, outcome)
			provider.current_session = function()
				return session
			end
			nvim.new_store = function()
				return {}
			end
			nvim.logger = function()
				return function() end
			end
			composition_root.build = function()
				return {
					contubernium_membership = {
						contubernium_of = function(_, miles)
							return miles == "d1" and decanus or miles == "f1" and decanus or nil
						end,
					},
					legio_process = {
						stand_by = function(_, miles)
							if miles ~= "d1" then
								return nil, "only the decanus can stand the contubernium by"
							end
							stood = miles
							return outcome
						end,
					},
				}
			end
			stood = nil
			local out = io.tmpfile()
			local saved_out = io.output()
			io.output(out)
			local code = cli.run({ "ready" })
			io.output(saved_out)
			out:seek("set")
			local text = out:read("*a")
			out:close()
			return code, text
		end
		local ok, err = pcall(function()
			local code, text = run("d1", true)
			check("the decanus stands the contubernium by", code == 0 and stood == "d1" and text:find("standing by", 1, true) ~= nil, { code, stood, text })
			code = run("f1", true)
			check("a faber is refused and nothing is stood by", code == 1 and stood == nil, { code, stood })
			code = run("nobody", true)
			check("a session outside a contubernium is refused", code == 1 and stood == nil, { code, stood })
			code = run("d1", false)
			check("when the service refuses, the command fails", code == 1 and stood == "d1", { code, stood })
		end)
		provider.current_session, nvim.new_store, nvim.logger, composition_root.build = saved.session, saved.store, saved.logger, saved.build
		check("the ready command runs", ok, err)
	end)

	test("legion: the decanus's orders tell him to run contubernium ready, and only him", function()
		local Legio = require("workspace.legio.domain.legio")
		local legio = Legio.raise(Legio.standing[1], 1)
		local function orders(post)
			return legio:orders({ name = "Servius", post = post, mandatum = "# split the api", unit = "contubernium otter", roster = "r", superior = "Gaius", subordinates = {} })
		end
		local decanus = orders("decanus")
		check("the decanus is told to run ready once the censor has reviewed", decanus:find("censor has reviewed", 1, true) and decanus:find("contubernium ready", 1, true), decanus)
		check("and that it counts as idle before he marks the mandatum done", decanus:find("before you mark this one done", 1, true) ~= nil)
		check("a faber is not told to stand the contubernium by", not orders("faber"):find("contubernium ready", 1, true))
		check("nor a centurio", not orders("centurio"):find("contubernium ready", 1, true))
	end)

	test("legion: standing by never takes a mandatum nobody offered, and take records a hand-given one", function()
		local expeditiones = {
			e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = { mandatum("m1", "split the api"), mandatum("m2", "move the bridge") } },
		}
		local service, calls, store = setup({ expeditiones = expeditiones })
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		expeditiones.e1.mandata[1].assignee, expeditiones.e1.mandata[2].assignee = calls.assigned.m1, calls.assigned.m2
		local d1, d2 = calls.assigned.m1, calls.assigned.m2
		table.insert(expeditiones.e1.mandata, mandatum("m7", "given by hand"))
		service:stand_by(d1)
		check("an open mandatum nobody offered is not handed out", calls.assigned.m7 == nil, calls.assigned)
		local ok = service:take_mandatum(d2, "m7")
		check("a decanus records a hand-given mandatum", ok == true)
		local contubernia = require(filesystem .. "contubernium_repository").new(store)
		local second = contubernia:of(d2)
		check("it is his contubernium's current one, the old one earlier", second.todo == "m7" and second:held("m2") and second.stood_by == nil, second.todo)
		service:stand_by(d1)
		check("a recorded mandatum is never offered to another", calls.assigned.m7 == nil)
		table.insert(expeditiones.e1.mandata, mandatum("m8", "finished", "done"))
		expeditiones.e1.mandata[1].state = "done"
		check("an offer still skips what a contubernium holds", service:offer_mandatum("m7") == nil)
		local _, why = service:take_mandatum(d1, "m7")
		check("another contubernium can't take it", why and why:find("held by", 1, true), why)
		local _, foreign = service:take_mandatum(d1, "nope")
		check("a mandatum of no running expeditio can't be taken", foreign and foreign:find("no mandatum of your expeditio", 1, true), foreign)
		local _, finished = service:take_mandatum(d1, "m8")
		check("a done mandatum can't be taken", finished and finished:find("not open", 1, true), finished)
		local _, outside = service:take_mandatum("nobody", "m7")
		check("a miles outside any contubernium can't take", outside ~= nil)
		local faber
		for _, m in ipairs(second.members) do
			if m.role == "faber" then
				faber = m.miles
			end
		end
		local _, notdecanus = service:take_mandatum(faber, "m7")
		check("only a decanus takes", notdecanus and notdecanus:find("decanus", 1, true), notdecanus)
	end)
	local function legacy_stopped_centurio(store, id)
		require(filesystem .. "miles_repository").new(store):update(id, function(m)
			m.legio, m.role, m.state, m.roman_name, m.cwd = "x-rapax", "centurio", "stopped", "Lucius", "/p"
		end)
	end

	local function led_by(store, leader)
		require(filesystem .. "cohors_repository").new(store):update(Cohors.key("/p"), function(c)
			c.root = "/p"
			c.primus_pilus = leader
			return true
		end)
	end

	local function stored_with_legacy_key(store, leader)
		store:update_record("cohortes", Cohors.key("/p"), function()
			return { id = Cohors.key("/p"), root = "/p", pilus_prior = leader, centuriae = {}, created = 1 }
		end)
	end

	local function cohors_on(store)
		return require(filesystem .. "cohors_repository").new(store):get(Cohors.key("/p"))
	end

	test("legion: a cohors led by a stopped legacy centurio still starts a real primus pilus on opus", function()
		local service, calls, store = setup()
		service:raise_legiones()
		legacy_stopped_centurio(store, "legacy")
		led_by(store, "legacy")
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		local pilus = primus_starts({ calls = calls })
		check("one primus pilus starts on opus", #pilus == 1 and pilus[1].model == "opus", #calls.started)
		local cohors = cohors_on(store)
		check("the cohors's primus pilus is the new one, not the stopped centurio", pilus[1] ~= nil and cohors ~= nil and cohors.primus_pilus == pilus[1].id and cohors.primus_pilus ~= "legacy", cohors)
	end)

	test("legion: a cohors whose primus pilus has no miles record still starts a real primus pilus on opus", function()
		local service, calls, store = setup()
		service:raise_legiones()
		led_by(store, "ghost")
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		local pilus = primus_starts({ calls = calls })
		check("one primus pilus starts on opus", #pilus == 1 and pilus[1].model == "opus", #calls.started)
		local cohors = cohors_on(store)
		check("the cohors's primus pilus is the new one, not the missing record", pilus[1] ~= nil and cohors ~= nil and cohors.primus_pilus == pilus[1].id and cohors.primus_pilus ~= "ghost", cohors)
	end)

	test("legion: a cohors already led by a running primus pilus starts no second one", function()
		local service, calls, store = setup()
		service:raise_legiones()
		require(filesystem .. "miles_repository").new(store):update("running", function(m)
			m.legio, m.role, m.state, m.roman_name, m.cwd = "x-rapax", "primus pilus", "working", "Titus", "/p"
		end)
		led_by(store, "running")
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		check("no primus pilus starts", #primus_starts({ calls = calls }) == 0, #calls.started)
		local cohors = cohors_on(store)
		check("the cohors keeps the running primus pilus", cohors ~= nil and cohors.primus_pilus == "running", cohors)
	end)

	test("legion: a stopped legacy centurio is not a primus pilus: he reports like a centurio and his fall doesn't go to the cohors", function()
		local service, calls, store, handover = setup()
		service:raise_legiones()
		legacy_stopped_centurio(store, "legacy")
		led_by(store, "legacy")
		local Send = require("workspace.legio.application.commands.send_legio_message_command")
		local held_before = #calls.held
		local names, why = service:report(Send.new({ from = "legacy", text = "x" }))
		check("his report reaches no one", names == nil, names)
		check("it is refused as having no post, not sent to the stale leader or the commander", why == "you hold no post in a legio", why)
		check("nobody receives it", #calls.held == held_before, calls.held)
		local result = hand_over({ handover = handover }, "legacy", "x")
		check("a stopped legacy centurio holds no post, so he can't hand over", result ~= nil and not result.ok, result)
		check("no supplementum starts for him", #calls.started == 0, #calls.started)
	end)

	test("legion: discharging the last legio of a cohors with a legacy leader keeps the stopped legacy miles out of it and clears the stale field", function()
		local expeditiones = {
			e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = { mandatum("m1", "split the api") } },
		}
		local service, calls, store = setup({ expeditiones = expeditiones })
		service:raise_legiones()
		legacy_stopped_centurio(store, "legacy")
		led_by(store, "legacy")
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		local decanus = calls.assigned.m1
		expeditiones.e1.mandata[1].state, expeditiones.e1.mandata[1].assignee = "done", decanus
		service:credit_finished(decanus)
		local stood_down = false
		for _, s in ipairs(calls.stopped) do
			if s.id == "legacy" then
				stood_down = true
			end
		end
		check("the legacy miles isn't stood down as primus pilus", not stood_down, calls.stopped)
		local cohors = cohors_on(store)
		check("the stale primus pilus field is cleared", cohors ~= nil and cohors.primus_pilus == nil, cohors)
	end)
	local function miles_with(store, id, role, state)
		require(filesystem .. "miles_repository").new(store):update(id, function(m)
			m.legio, m.role, m.state, m.roman_name, m.cwd = "x-rapax", role, state, "Titus", "/p"
		end)
	end

	test("legion: a running centurio in the primus pilus's place is stale too, so a new primus pilus starts", function()
		local service, calls, store = setup()
		service:raise_legiones()
		miles_with(store, "live-centurio", "centurio", "working")
		led_by(store, "live-centurio")
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		local pilus = primus_starts({ calls = calls })
		check("one primus pilus starts on opus", #pilus == 1 and pilus[1].model == "opus", #calls.started)
		local cohors = cohors_on(store)
		check("the cohors's primus pilus is the new one", pilus[1] ~= nil and cohors ~= nil and cohors.primus_pilus == pilus[1].id, cohors)
	end)

	test("legion: a stopped primus pilus is still the cohors's primus pilus, so a new deploy doesn't replace him", function()
		local service, calls, store = setup()
		service:raise_legiones()
		miles_with(store, "fallen-pilus", "primus pilus", "stopped")
		led_by(store, "fallen-pilus")
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		check("no primus pilus starts", #primus_starts({ calls = calls }) == 0, #calls.started)
		local cohors = cohors_on(store)
		check("the cohors keeps the stopped primus pilus until he falls", cohors ~= nil and cohors.primus_pilus == "fallen-pilus", cohors)
	end)

	test("legion: with no valid primus pilus, the legio shows its centuria directly, not a cohors card", function()
		local service, calls, store = setup()
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		legacy_stopped_centurio(store, "legacy")
		led_by(store, "legacy")
		local legio = by_name(service:legiones())["x-rapax"]
		check("the legio's unit is the centuria, with no cohors card around it", legio.cohors ~= nil and legio.cohors.kind == "centuria", legio.cohors and legio.cohors.kind)
	end)
	test("legion: a live centurio in a cohors with a stale leader reports to the commander", function()
		local l = deployed()
		led_by(l.store, "legacy")
		local Send = require("workspace.legio.application.commands.send_legio_message_command")
		local held_before = #l.calls.held
		local names, why = l.service:report(Send.new({ from = l.ids.centurio, text = "x" }))
		check("he reports to the commander, with no superior to deliver to", names == nil and why ~= nil and why:find("commander", 1, true) ~= nil, { names, why })
		check("nobody receives it", #l.calls.held == held_before, l.calls.held)
	end)
	local function primus_start(calls)
		for _, c in ipairs(calls.started) do
			if c.prompt:find("^You are [^,]+, primus pilus of Legio") then
				return c
			end
		end
		return {}
	end


	test("legion: the first deploy in a cohors starts a primus pilus on opus, second in command after the commander", function()
		local l = deployed()
		local primus = primus_start(l.calls)
		check("a primus pilus starts on opus", primus.model == "opus", primus)
		check("his orders say he is second in command, under the commander", primus.prompt ~= nil and primus.prompt:find("second in command", 1, true) ~= nil and primus.prompt:find("commander", 1, true) ~= nil, primus.prompt)
	end)

	test("legion: a centurio reports to the primus pilus, and the primus pilus reports to the commander", function()
		local l = deployed()
		local primus = by_name(l.service:legiones())["x-rapax"].cohors.leader.miles_id
		local Send = require("workspace.legio.application.commands.send_legio_message_command")
		local names = l.service:report(Send.new({ from = l.ids.centurio, text = "x" }))
		check("the centurio's report goes to the primus pilus, not the commander", names ~= nil and names[1] == l.milites:find(primus).roman_name and l.calls.held[#l.calls.held].id == primus, l.calls.held)
		local _, why = l.service:report(Send.new({ from = primus, text = "x" }))
		check("the primus pilus reports to the commander", why ~= nil and why:find("commander", 1, true) ~= nil, why)
	end)

	test("legion: when the primus pilus falls, the most senior centurio becomes primus pilus", function()
		local l = deployed()
		l.service:deploy(DeployLegioCommand.new({ legio_id = l.service:legiones()[2].id, expeditio_id = "e1" }), function() end)
		local pilus = primus_start(l.calls)
		check("there is a primus pilus to fall", pilus.id ~= nil)
		if not pilus.id then
			return
		end
		local other
		for _, c in ipairs(l.calls.started) do
			if c.model == "opus" and c.id ~= pilus.id and c.id ~= l.ids.centurio and c.prompt:find("centurio of", 1, true) then
				other = c.id
			end
		end
		check("the second centuria has its own centurio", other ~= nil)
		if not other then
			return
		end
		l.milites:update(other, function(m)
			m.mandata = { "a", "b", "c" }
		end)
		hand_over(l, pilus.id, "cohors half done")
		check("the most senior centurio is the primus pilus", cohors_on(l.store).primus_pilus == other and l.milites:find(other).role == "primus pilus", cohors_on(l.store))
	end)

	test("legion: a stored cohors with the legacy pilus_prior key and a pilus prior miles still has a valid primus pilus", function()
		local service, calls, store = setup()
		service:raise_legiones()
		miles_with(store, "legacy-pilus", "pilus prior", "working")
		stored_with_legacy_key(store, "legacy-pilus")
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		check("no new primus pilus starts for him", #primus_starts({ calls = calls }) == 0, #calls.started)
		local leader = by_name(service:legiones())["x-rapax"].cohors.leader
		check("the legacy record's miles leads the cohors", leader ~= nil and leader.miles_id == "legacy-pilus", leader)
		check("and he is the primus pilus now", leader ~= nil and leader.post == "primus pilus", leader)
	end)
	test("legion: a cohors remembers that its commander commits, and reads it back from the repository", function()
		local _, _, store = setup()
		require(filesystem .. "cohors_repository").new(store):update(Cohors.key("/p"), function(c)
			c.root = "/p"
			c.commander_commits = true
			return true
		end)
		check("the commander's commit mode is read back as true", cohors_on(store):committed_by_commander() == true)
	end)

	test("legion: a legacy cohors record without the commit field reads as not committed by the commander", function()
		local _, _, store = setup()
		store:update_record("cohortes", Cohors.key("/p"), function()
			return { id = Cohors.key("/p"), root = "/p", centuriae = {}, created = 1 }
		end)
		check("a record without the field reads false", cohors_on(store):committed_by_commander() == false)
	end)
end

local LegioProcess = require("workspace.legio.application.legio_process")
local HandoverProcess = require("workspace.legio.application.handover_process")
local HandOverCommand = require("workspace.legio.application.commands.hand_over_command")
local DeployLegioCommand = require("workspace.legio.application.commands.deploy_legio_command")
local SendCommand = require("workspace.legio.application.commands.send_legio_message_command")

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

	local function deployed()
		local service, calls, store, handover = setup()
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e2" }), function() end)
		local milites = require(filesystem .. "miles_repository").new(store)
		local contubernia = require(filesystem .. "contubernium_repository").new(store)
		local centuria = require(filesystem .. "centuria_repository").new(store):all()[1]
		local ids = { centurio = centuria.centurio, optio = centuria.optio }
		for _, m in ipairs(contubernia:all()[1].members) do
			ids[m.role] = m.miles
		end
		return { service = service, calls = calls, store = store, handover = handover, milites = milites, ids = ids }
	end

	local function hand_over(l, id, text)
		local result
		l.handover:hand_over(HandOverCommand.new({ miles_id = id, traditio = text }), function(ok, r)
			result = { ok = ok, r = r }
		end)
		return result
	end

	local function held_for(l, id)
		local out = {}
		for _, h in ipairs(l.calls.held) do
			if h.id == id then
				table.insert(out, h.text)
			end
		end
		return out
	end

	local function contains(list, text)
		for _, s in ipairs(list) do
			if s:find(text, 1, true) then
				return true
			end
		end
		return false
	end

	local function centuria_on(store)
		return require(filesystem .. "centuria_repository").new(store):all()[1]
	end

	test("split: a decanus's routine report goes to the optio", function()
		local l = deployed()
		local names = l.service:report(SendCommand.new({ from = l.ids.decanus, text = "half done" }))
		check("the routine report reaches the optio", names ~= nil and names[1] == l.milites:find(l.ids.optio).roman_name and l.calls.held[#l.calls.held].id == l.ids.optio, l.calls.held)
	end)

	test("split: a decision, blocker or done report goes to the centurio, and the optio gets a copy", function()
		for _, kind in ipairs({ "decision", "blocker", "done" }) do
			local l = deployed()
			l.service:report(SendCommand.new({ from = l.ids.decanus, text = kind .. " for the bridge", kind = kind }))
			check(kind .. " reaches the centurio", contains(held_for(l, l.ids.centurio), kind .. " for the bridge"), l.calls.held)
			check(kind .. " is copied to the optio", contains(held_for(l, l.ids.optio), kind .. " for the bridge"), l.calls.held)
		end
	end)

	test("split: when the centurio orders a decanus, the optio gets a copy and the centuria records the decision", function()
		local l = deployed()
		local decanus = l.milites:find(l.ids.decanus).roman_name
		local sent = l.service:order(SendCommand.new({ from = l.ids.centurio, to = decanus, text = "use the bridge module" }))
		check("the decanus gets the order", sent ~= nil and #sent == 1, sent)
		check("the optio gets a copy", contains(held_for(l, l.ids.optio), "use the bridge module"), l.calls.held)
		local decisions = centuria_on(l.store).decisions or {}
		check("the centuria records the decision", #decisions == 1 and tostring(decisions[1].text or decisions[1]):find("use the bridge module", 1, true) ~= nil, decisions)
	end)

	test("split: a centuria stored without a decisions log reads as an empty one", function()
		local l = deployed()
		l.store:update_record("centuriae", centuria_on(l.store).id, function(record)
			local out = {}
			for k, v in pairs(record) do
				if k ~= "decisions" then
					out[k] = v
				end
			end
			return out
		end)
		local decisions = centuria_on(l.store).decisions
		check("the decisions log reads as an empty table", type(decisions) == "table" and #decisions == 0, decisions)
	end)

	test("split: a centurio's order to the optio himself is delivered once", function()
		local l = deployed()
		local optio = l.milites:find(l.ids.optio).roman_name
		local before = #held_for(l, l.ids.optio)
		local sent = l.service:order(SendCommand.new({ from = l.ids.centurio, to = optio, text = "take the bridge" }))
		check("the optio gets the order once", sent ~= nil and #sent == 1 and #held_for(l, l.ids.optio) == before + 1, l.calls.held)
	end)

	test("split: when the centurio falls, the optio's note carries the mandatum text and the decisions log", function()
		local l = deployed()
		local decanus = l.milites:find(l.ids.decanus).roman_name
		l.service:order(SendCommand.new({ from = l.ids.centurio, to = decanus, text = "use the bridge module" }))
		local repo = require(filesystem .. "contubernium_repository").new(l.store)
		local squad = repo:all()[1]
		squad:submit_plan("PLAN-ALPHA split the api first", 100)
		repo:save(squad)
		hand_over(l, l.ids.centurio, "expeditio half done")
		local notes = held_for(l, l.ids.optio)
		local note = notes[#notes] or ""
		local todo = require(filesystem .. "contubernium_repository").new(l.store):all()[1].todo
		check("the note carries the mandatum text the todos port returns", note:find("# mandatum " .. todo, 1, true) ~= nil, note)
		check("the note carries the decisions log", note:find("use the bridge module", 1, true) ~= nil, note)
		check("the note carries the submitted plan text", note:find("PLAN-ALPHA split the api first", 1, true) ~= nil, note)
	end)

	test("split: a contubernium with no submitted plan adds no plan text to the optio's note", function()
		local l = deployed()
		hand_over(l, l.ids.centurio, "expeditio half done")
		local notes = held_for(l, l.ids.optio)
		local note = notes[#notes] or ""
		check("no plan text appears in the note", note:find("PLAN-ALPHA", 1, true) == nil, note)
	end)

	test("split: an optio's report still goes to the centurio, and a centurio's to the primus pilus", function()
		local l = deployed()
		l.service:report(SendCommand.new({ from = l.ids.optio, text = "all quiet" }))
		check("the optio reports to the centurio", l.calls.held[#l.calls.held].id == l.ids.centurio, l.calls.held)
		local primus = by_name(l.service:legiones())["x-rapax"].cohors.leader.miles_id
		l.service:report(SendCommand.new({ from = l.ids.centurio, text = "x" }))
		check("the centurio reports to the primus pilus", l.calls.held[#l.calls.held].id == primus, l.calls.held)
	end)
	local function centuria_led_by(store, centurio)
		for _, c in ipairs(require(filesystem .. "centuria_repository").new(store):all()) do
			if c.centurio == centurio then
				return c
			end
		end
	end

	local function squad_of(store, centuria_id)
		for _, c in ipairs(require(filesystem .. "contubernium_repository").new(store):all()) do
			if c.centuria == centuria_id then
				return c
			end
		end
	end

	test("split: when the primus pilus falls, the optio of the promoted centurio's centuria gets his centuria's mandatum, plan and decisions in his note", function()
		local l = deployed()
		l.service:deploy(DeployLegioCommand.new({ legio_id = "iv-obsidionalis", expeditio_id = "e1" }), function() end)
		local primus = by_name(l.service:legiones())["x-rapax"].cohors.leader.miles_id
		local other
		for _, c in ipairs(require(filesystem .. "centuria_repository").new(l.store):all()) do
			if c.legio == "iv-obsidionalis" then
				other = c.centurio
			end
		end
		check("the second centuria has its own centurio", other ~= nil)
		if not other then
			return
		end
		l.milites:update(other, function(m)
			m.mandata = { "a", "b", "c" }
		end)
		local centuria = centuria_led_by(l.store, other)
		local optio = centuria.optio
		local squad = squad_of(l.store, centuria.id)
		local decanus = nil
		for _, m in ipairs(squad.members) do
			if m.role == "decanus" then
				decanus = m.miles
			end
		end
		l.service:order(SendCommand.new({ from = other, to = l.milites:find(decanus).roman_name, text = "BETA decision" }))
		local repo = require(filesystem .. "contubernium_repository").new(l.store)
		local stored = repo:get(squad.id)
		stored:submit_plan("PLAN-BETA split the api first", 100)
		repo:save(stored)
		hand_over(l, primus, "cohors half done")
		local notes = held_for(l, optio)
		local note = notes[#notes] or ""
		local after = require(filesystem .. "centuria_repository").new(l.store):get(centuria.id)
		check("the optio is the centurio of that centuria", after ~= nil and after.centurio == optio, after)
		check("the note carries his centuria's mandatum text", note:find("# mandatum " .. squad.todo, 1, true) ~= nil, note)
		check("the note carries his centuria's plan text", note:find("PLAN-BETA split the api first", 1, true) ~= nil, note)
		check("the note carries his centuria's decisions log", note:find("BETA decision", 1, true) ~= nil, note)
	end)

	test("split: a report with an unknown kind is refused and nothing is delivered", function()
		local l = deployed()
		local before = #l.calls.held
		local names, why = l.service:report(SendCommand.new({ from = l.ids.decanus, text = "x", kind = "decison" }))
		check("it is refused with the kinds allowed", names == nil and why == "kind must be decision, blocker or done", why)
		check("nothing is delivered", #l.calls.held == before, l.calls.held)
	end)
	local function prompt_of(l, id)
		for _, c in ipairs(l.calls.started) do
			if c.id == id then
				return c.prompt or ""
			end
		end
		return ""
	end

	test("split: the decanus's orders say how to send decision, blocker and done reports, and that routine reports go to the optio", function()
		local l = deployed()
		local prompt = prompt_of(l, l.ids.decanus)
		check("the decanus is told to send decision, blocker and done with the kind flag", prompt:find("legio report --kind decision|blocker|done", 1, true) ~= nil, prompt)
		check("routine reports go to the optio", prompt:find("Routine reports go to your optio", 1, true) ~= nil, prompt)
	end)

	test("split: the optio's orders say he runs the centuria day to day and takes over", function()
		local l = deployed()
		local prompt = prompt_of(l, l.ids.optio)
		check("he runs the centuria day to day", prompt:find("You run the centuria day to day", 1, true) ~= nil, prompt)
	end)

	test("split: the centurio's orders say the optio is copied on his orders", function()
		local l = deployed()
		local prompt = prompt_of(l, l.ids.centurio)
		check("the centurio is told the optio is copied on his orders", prompt:find("he is copied on it", 1, true) ~= nil, prompt)
	end)
	test("split: a bare --kind with no value is refused and nothing is delivered", function()
		local l = deployed()
		local before = #l.calls.held
		local names, why = l.service:report(SendCommand.new({ from = l.ids.decanus, text = "x", kind = "" }))
		check("it is refused: kind must be decision, blocker or done", names == nil and why == "kind must be decision, blocker or done", why)
		check("nothing is delivered", #l.calls.held == before, l.calls.held)
	end)
	test("split: the CLI parser reads a bare --kind as an empty kind and a valued --kind as its kind and message", function()
		local cli = require("workspace.legio.infrastructure.inbound.mappers.legio_cli_mapper")
		local bare = cli.to_report_command("decanus", { "report", "--kind" })
		check("a bare --kind yields kind ''", bare.kind == "", bare)
		local valued = cli.to_report_command("decanus", { "report", "--kind", "decision", "bridge is blocked" })
		check("--kind decision yields kind 'decision'", valued.kind == "decision", valued)
		check("and the message is kept", valued.text == "bridge is blocked", valued)
	end)
end

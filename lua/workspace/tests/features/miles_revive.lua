-- Mandatum 5319: a stopped miles with waiting orders is revived; after two failed tries his orders are handed over.
-- Written against legio_process.lua (revivable, revive_waiting, hand_over_stalled) and miles_runner.lua (revive).
local LegioProcess = require("workspace.legio.application.legio_process")
local HandoverProcess = require("workspace.legio.application.handover_process")
local Miles = require("workspace.legio.domain.miles")
local Contubernium = require("workspace.legio.domain.contubernium")

local filesystem = "workspace.legio.infrastructure.outbound.filesystem."
local GAP = 600

local function setup(make_store, o)
	o = o or {}
	local store = make_store(vim.fn.tempname())
	local repos = {
		legiones = require(filesystem .. "legio_repository").new(store),
		cohortes = require(filesystem .. "cohors_repository").new(store),
		centuriae = require(filesystem .. "centuria_repository").new(store),
		contubernia = require(filesystem .. "contubernium_repository").new(store),
		milites = require(filesystem .. "miles_repository").new(store),
	}
	local calls = { revived = {}, started = {}, held = {}, logged = {}, stops = {} }
	local now = 1000
	local next_id = 0
	local clock = function()
		return now
	end
	-- a deployed legio, linked to a centuria, which holds the contubernium that holds Titus
	local Centuria = require("workspace.legio.domain.centuria")
	local centuria = Centuria.make({ id = "c1", legio = "x", contubernia = { "t1" }, centurio = "marcus", optio = "gaius" })
	local Legio = require("workspace.legio.domain.legio")
	local deployed = Legio.raise(Legio.standing[1], 1)
	deployed.expeditio, deployed.centuria = "agentd sdk", "c1"
	centuria.legio = deployed.id
	local legiones = {
		get = function()
			return deployed
		end,
		all = function()
			return { deployed }
		end,
		update_existing = function(_, id, fn)
			if id == deployed.id then
				fn(deployed)
			end
			return deployed
		end,
	}
	local centuriae = {
		get = function(_, id)
			return id == "c1" and centuria or nil
		end,
		update = function(_, id, fn)
			if id == "c1" then
				fn(centuria)
			end
			return centuria
		end,
		update_existing = function(_, id, fn)
			if id == "c1" then
				fn(centuria)
			end
			return centuria
		end,
	}
	-- servius leads the contubernium, so he is titus's superior
	local contubernium = Contubernium.make("t1", "todo1", "/p", "main", { "servius", "titus" }, 1, "pluvialis")
	contubernium.members[1].role, contubernium.members[2].role = "decanus", "faber"
	repos.contubernia:save(contubernium)
	if o.context_fraction then
		local all = repos.milites.all
		repos.milites.all = function(self_)
			local list = all(self_)
			for _, m in ipairs(list) do
				m.runtime = { context_fraction = function() return o.context_fraction end }
			end
			return list
		end
	end
	local runner = {
		revive = function(_, miles, done)
			local texts = {}
			for _, m in ipairs(miles:held()) do
				table.insert(texts, m.text)
			end
			table.insert(calls.revived, { id = miles.id, texts = texts, at = now })
			local ok = not (o.resume_fails and o.resume_fails(miles))
			done(ok, ok and nil or "the resume failed")
		end,
		start = function(_, command, done)
			table.insert(calls.started, command)
			done(true, "short")
		end,
		hold_text = function(_, id, text)
			table.insert(calls.held, { id = id, text = text })
			repos.milites:update_existing(id, function(m)
				m:hold(text, now)
				return m
			end)
		end,
		set_model = function(_, command, done)
			done(true)
		end,
		stop = function(_, id, done, reason)
			table.insert(calls.stops, { id = id, reason = reason })
			done(true)
		end,
		take_held = function(_, id, pick)
			return pick(repos.milites:get(id))
		end,
		new_miles_id = function()
			next_id = next_id + 1
			return ("s-%02d"):format(next_id)
		end,
	}
	local todos = {
		done_command = "todo",
		assign = function()
			return true
		end,
		send = function() end,
		release = function() end,
		text = function()
			return "# mandatum"
		end,
		title = function()
			return "mandatum"
		end,
	}
	local service = LegioProcess.new({
		legiones = legiones,
		cohortes = repos.cohortes,
		centuriae = centuriae,
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
			get = function() return nil end,
			of = function() return nil end,
		},
		clock = clock,
		log = function(entry)
			table.insert(calls.logged, entry)
		end,
		random = function(a)
			return a
		end,
	})
	local handover = HandoverProcess.new({
		milites = repos.milites,
		contubernia = repos.contubernia,
		centuriae = centuriae,
		cohortes = repos.cohortes,
		legiones = legiones,
		runner = runner,
		todos = todos,
		clock = clock,
		log = function(entry)
			table.insert(calls.logged, entry)
		end,
	})
	-- the composition hands LegioProcess a port whose hand_over calls the handover process
	service.handover = {
		hand_over = function(command, done)
			return handover:hand_over(command, done)
		end,
	}
	local function stopped(id, texts, state, reason)
		local outbox = {}
		for i, text in ipairs(texts) do
			table.insert(outbox, { id = id .. "-" .. i, text = text, at = now })
		end
		-- the store hands the record to fn and persists the model it is left with
		repos.milites:update(id, function(m)
			m.name, m.roman_name, m.legio, m.role, m.root = id, id:sub(1, 1):upper() .. id:sub(2), "x", "faber", "/p"
			m.outbox = outbox
			if state == "working" then
				m.state = "working"
			else
				m:apply("end", now)
				if reason then
					m:stop_on_purpose(reason, now)
				end
			end
		end)
	end
	local function advance(seconds)
		now = now + seconds
	end
	return { service = service, calls = calls, repos = repos, stopped = stopped, advance = advance }
end

local function logged(calls, event)
	for _, entry in ipairs(calls.logged) do
		if entry.event == event then
			return entry
		end
	end
end

return function(t)
	local test, check = t.test, t.check

	test("a stopped miles with held orders is revived once, with his held text", function()
		local fx = setup(t.make_store)
		fx.stopped("titus", { "rewrite the parser" })
		fx.service:revive_waiting()
		check("he is revived once", #fx.calls.revived == 1, fx.calls.revived)
		check("he is revived with his id", fx.calls.revived[1] and fx.calls.revived[1].id == "titus", fx.calls.revived)
		check("his held order is what the revive carries", fx.calls.revived[1] and vim.inspect(fx.calls.revived[1].texts) == vim.inspect({ "rewrite the parser" }), fx.calls.revived)
	end)

	test("an order arriving for a stopped miles revives him once, carrying that order", function()
		local fx = setup(t.make_store)
		fx.stopped("titus", {})
		fx.service:deliver({ { miles = "titus", name = "Titus" } }, "split the parser")
		check("delivery revives him once", #fx.calls.revived == 1, fx.calls.revived)
		check("the new order is what the revive carries", fx.calls.revived[1] and vim.inspect(fx.calls.revived[1].texts) == vim.inspect({ "split the parser" }), fx.calls.revived)
	end)

	test("a successful revive is logged as revived, with no replacement", function()
		local fx = setup(t.make_store)
		fx.stopped("titus", { "rewrite the parser" })
		fx.service:revive_waiting()
		local revived = logged(fx.calls, "revived")
		check("the revive is logged as revived, resumed", revived ~= nil and revived.reason == "resumed", fx.calls.logged)
		check("no replacement follows a successful revive", logged(fx.calls, "replaced") == nil, fx.calls.logged)
	end)

	test("a first failed resume is retried later, not replaced at once", function()
		local fx = setup(t.make_store, { resume_fails = function() return true end })
		fx.stopped("titus", { "rewrite the parser" })
		fx.service:revive_waiting()
		local retry = logged(fx.calls, "revive_retry")
		check("the failure is logged as a retry, attempt 1", retry ~= nil and retry.attempt == 1, fx.calls.logged)
		check("no replacement after the first failure", logged(fx.calls, "replaced") == nil, fx.calls.logged)
		check("no supplementum after the first failure", #fx.calls.started == 0, fx.calls.started)
	end)

	test("after one failed revive, no second try happens within the ten-minute gap", function()
		local fx = setup(t.make_store, { resume_fails = function() return true end })
		fx.stopped("titus", { "rewrite the parser" })
		fx.service:revive_waiting()
		fx.advance(60)
		fx.service:revive_waiting()
		check("no second try inside the gap", #fx.calls.revived == 1, #fx.calls.revived)
	end)

	test("the second failed resume, after the gap, replaces him: his orders go to a supplementum, and his superior is told", function()
		local fx = setup(t.make_store, { resume_fails = function() return true end })
		fx.stopped("titus", { "rewrite the parser" })
		fx.service:revive_waiting()
		fx.advance(GAP)
		fx.service:revive_waiting()
		check("the second try is made after the gap", #fx.calls.revived == 2, #fx.calls.revived)
		local replaced = logged(fx.calls, "replaced")
		check("the replacement is logged as attempts_exhausted", replaced ~= nil and replaced.reason == "attempts_exhausted", fx.calls.logged)
		local supplementum = fx.calls.started[#fx.calls.started] or {}
		check("a supplementum is started", #fx.calls.started == 1, fx.calls.started)
		check("his waiting order is in the supplementum's first order", (supplementum.prompt or ""):find("rewrite the parser", 1, true) ~= nil, supplementum.prompt)
		check("the traditio says it stopped again after resuming", (supplementum.prompt or ""):find("it stopped again after resuming", 1, true) ~= nil, supplementum.prompt)
	end)

	test("a context-full miles is replaced at once, with no revive: his superior is told", function()
		local fx = setup(t.make_store, { context_fraction = 0.95 })
		fx.stopped("titus", { "rewrite the parser" })
		fx.service:revive_waiting()
		check("no revive for a context-full miles", #fx.calls.revived == 0, fx.calls.revived)
		local replaced = logged(fx.calls, "replaced")
		check("the replacement is logged as context_full", replaced ~= nil and replaced.reason == "context_full", fx.calls.logged)
		check("a supplementum is started", #fx.calls.started == 1, fx.calls.started)
		local told = false
		for _, h in ipairs(fx.calls.held) do
			if h.id == "servius" and h.text and h.text:find("Titus", 1, true) then
				told = true
			end
		end
		check("his superior, the decanus, is told in a held text", told, fx.calls.held)
	end)

	test("a running miles is left alone", function()
		local fx = setup(t.make_store)
		fx.stopped("titus", { "rewrite the parser" }, "working")
		fx.service:revive_waiting()
		check("no revive for a running miles", #fx.calls.revived == 0, fx.calls.revived)
		check("no replacement for a running miles", logged(fx.calls, "replaced") == nil, fx.calls.logged)
	end)

	-- stop reasons: a deliberate stop is never revived and never receives an order

	test("a miles stopped on purpose is not revived, even with held orders", function()
		local fx = setup(t.make_store)
		fx.stopped("titus", { "rewrite the parser" }, "stopped", "ended_by_commander")
		fx.service:revive_waiting()
		check("no revive for a miles stopped on purpose", #fx.calls.revived == 0, fx.calls.revived)
		check("no replacement for a miles stopped on purpose", logged(fx.calls, "replaced") == nil, fx.calls.logged)
	end)

	test("an order to a miles stopped on purpose is not held, and he is named stood down", function()
		local fx = setup(t.make_store)
		fx.stopped("titus", {}, "stopped", "stood_down")
		local names, stood_down = fx.service:deliver({ { miles = "titus", name = "Titus" } }, "split the parser")
		check("nothing is delivered to him", vim.inspect(names) == vim.inspect({}), names)
		check("he is the stood-down name, the second return", vim.inspect(stood_down) == vim.inspect({ "Titus" }), stood_down)
		check("no text is held for him", #fx.calls.held == 0, fx.calls.held)
		check("no revive for him either", #fx.calls.revived == 0, fx.calls.revived)
	end)

	test("a delivered order keeps its first return, the names delivered", function()
		local fx = setup(t.make_store)
		fx.stopped("cassius", {}, "stopped", nil)
		fx.stopped("titus", {}, "stopped", "stood_down")
		local names, stood_down = fx.service:deliver({ { miles = "cassius", name = "Cassius" }, { miles = "titus", name = "Titus" } }, "split the parser")
		check("the names delivered are Cassius", vim.inspect(names) == vim.inspect({ "Cassius" }), names)
		check("the stood-down names are Titus", vim.inspect(stood_down) == vim.inspect({ "Titus" }), stood_down)
		check("only Cassius gets the text", #fx.calls.held == 1 and fx.calls.held[1].id == "cassius", fx.calls.held)
	end)

	test("the CLI line for a stood-down miles is literal", function()
		local mapper = require("workspace.legio.infrastructure.inbound.mappers.legio_cli_mapper")
		check("one stood-down name reads 'was'", mapper.to_stood_down_line({ "Titus" }) == "Titus was stood down; your order was not delivered\n", mapper.to_stood_down_line({ "Titus" }))
		check("two stood-down names read 'were'", mapper.to_stood_down_line({ "Titus", "Cassius" }) == "Titus, Cassius were stood down; your order was not delivered\n", mapper.to_stood_down_line({ "Titus", "Cassius" }))
	end)

	test("the stop reason is kept on the miles and survives a store round trip", function()
		local Miles = require("workspace.legio.domain.miles")
		local mapper = require("workspace.legio.infrastructure.outbound.filesystem.miles_record_mapper")
		local m = Miles:new({ id = "titus", state = "stopped", legio = "x" })
		m:stop_on_purpose("auxilium_done", 7)
		check("a deliberate stop is recorded", m:was_stopped_on_purpose() and m.stopped_by.reason == "auxilium_done", m.stopped_by)
		local back = mapper.to_domain(mapper.to_record(m))
		check("the reason survives a round trip", back.stopped_by ~= nil and back.stopped_by.reason == "auxilium_done", back.stopped_by)
		m:clear_stop()
		check("clearing removes it", not m:was_stopped_on_purpose() and m.stopped_by == nil, m.stopped_by)
	end)
	test("MilesRunner:stop writes the given reason on the stored miles", function()
		local MilesRunner = require("workspace.legio.application.miles_runner")
		local fx = setup(t.make_store)
		fx.stopped("titus", {}, "working")
		local runner = MilesRunner.new({
			milites = fx.repos.milites,
			contubernia = fx.repos.contubernia,
			agentd = { call = function(_, _, cb) cb(true) end },
			cli = { stop = function(_, done) done(true) end },
			attach = { close = function() end },
			notify = { warn = function() end },
			trace = { info = function() end },
			clock = function() return 5 end,
		})
		local stopped_ok
		runner:stop("titus", function(ok)
			stopped_ok = ok
		end, "stood_down")
		local titus = fx.repos.milites:get("titus")
		check("the stop completes", stopped_ok ~= false, stopped_ok)
		check("the stored miles carries the stood_down reason", titus ~= nil and titus.stopped_by ~= nil and titus.stopped_by.reason == "stood_down", titus and titus.stopped_by)
	end)

	-- clearing the stop reason: only a resume that succeeds clears it

	local function real_runner(fx, agent_ok)
		local MilesRunner = require("workspace.legio.application.miles_runner")
		return MilesRunner.new({
			milites = fx.repos.milites,
			contubernia = fx.repos.contubernia,
			agentd = {
				call = function(_, cb)
					cb(agent_ok, { code = "plan" })
				end,
			},
			cli = {
				provider = "cli",
				label = "cli",
				launch_args = function() return {} end,
				start = function(_, _, _, done)
					done(agent_ok)
				end,
				stop = function(_, done) done(true) end,
			},
			attach = { close = function() end },
			notify = { warn = function() end, info = function() end, error = function() end },
			trace = { info = function() end, warn = function() end, error = function() end },
			folder_exists = function() return true end,
			report = function() end,
			clock = function() return 5 end,
		})
	end

	test("a manual resume that succeeds clears the stop reason", function()
		local fx = setup(t.make_store)
		fx.stopped("titus", {}, "stopped", "ended_by_commander")
		local runner = real_runner(fx, true)
		local ok_seen
		runner:resume({ miles_id = "titus", cwd = "/p", prompt = "go on" }, function(ok)
			ok_seen = ok
		end)
		check("the resume succeeds", ok_seen == true, ok_seen)
		check("the stop reason is gone after the resume", fx.repos.milites:get("titus").stopped_by == nil, fx.repos.milites:get("titus").stopped_by)
	end)

	test("a manual resume that fails keeps the stop reason", function()
		local fx = setup(t.make_store)
		fx.stopped("titus", {}, "stopped", "ended_by_commander")
		local runner = real_runner(fx, false)
		runner:resume({ miles_id = "titus", cwd = "/p", prompt = "go on" }, function() end)
		local titus = fx.repos.milites:get("titus")
		check("the stop reason is kept after a failed resume", titus.stopped_by ~= nil and titus.stopped_by.reason == "ended_by_commander", titus.stopped_by)
	end)

	test("a commander's send to a stopped miles that resumes clears the stop reason", function()
		local fx = setup(t.make_store)
		fx.stopped("titus", {}, "stopped", "ended_by_commander")
		local runner = real_runner(fx, true)
		runner:send(fx.repos.milites:get("titus"), "split it now", function() end)
		check("the stop reason is gone after the send resumes him", fx.repos.milites:get("titus").stopped_by == nil, fx.repos.milites:get("titus").stopped_by)
	end)

	test("stand_down stops each miles with the stood_down reason", function()
		local fx = setup(t.make_store)
		fx.stopped("titus", {}, "working")
		fx.service:stand_down({ "titus" }, function() end)
		check("the stop is written with stood_down", fx.calls.stops[1] ~= nil and fx.calls.stops[1].reason == "stood_down", fx.calls.stops)
	end)

	-- where each stop reason is written, through its flow

	local function auxilium(fx, id, caller, due)
		fx.repos.milites:update(id, function(m)
			m.name, m.roman_name, m.legio, m.root = id, id, "x", "/p"
			m.caller, m.due = caller, due
			m.state = "working"
		end)
	end

	test("a relaunch with a resume id that the runner does not clear keeps the stop reason on a revive", function()
		local MilesRunner = require("workspace.legio.application.miles_runner")
		local fx = setup(t.make_store)
		fx.stopped("titus", { "rewrite the parser" }, "stopped", "ended_by_commander")
		local runner = MilesRunner.new({
			milites = fx.repos.milites,
			contubernia = fx.repos.contubernia,
			agentd = { call = function(_, cb) cb(true, { code = "plan" }) end },
			cli = { provider = "cli", label = "cli", launch_args = function() return {} end, start = function(_, _, _, done) done(true) end, stop = function(_, done) done(true) end },
			attach = { close = function() end },
			notify = { warn = function() end, info = function() end, error = function() end },
			trace = { info = function() end, warn = function() end, error = function() end },
			folder_exists = function() return true end,
			report = function() end,
			clock = function() return 5 end,
		})
		local revived, why
		runner:revive(fx.repos.milites:get("titus"), function(ok, reason)
			revived, why = ok, reason
		end)
		check("the revive refuses a miles stopped on purpose", revived == false and why == "stood down on purpose", { revived, why })
		check("a revive never clears the stop reason", fx.repos.milites:get("titus").stopped_by ~= nil and fx.repos.milites:get("titus").stopped_by.reason == "ended_by_commander", fx.repos.milites:get("titus").stopped_by)
	end)

	test("an auxilium that reports is stopped with auxilium_done", function()
		local fx = setup(t.make_store)
		fx.stopped("titus", {}, "working")
		auxilium(fx, "aux1", "titus", nil)
		fx.service:report({ from = "aux1", text = "the parser is done" })
		check("the auxilium is stopped with auxilium_done", fx.calls.stops[1] ~= nil and fx.calls.stops[1].id == "aux1" and fx.calls.stops[1].reason == "auxilium_done", fx.calls.stops)
	end)

	test("an auxilium overdue is stopped with auxilium_lapsed", function()
		local fx = setup(t.make_store)
		fx.stopped("titus", {}, "working")
		auxilium(fx, "aux1", "titus", 900)
		fx.advance(1000)
		fx.service:lapse_auxilia()
		check("the overdue auxilium is stopped with auxilium_lapsed", fx.calls.stops[1] ~= nil and fx.calls.stops[1].id == "aux1" and fx.calls.stops[1].reason == "auxilium_lapsed", fx.calls.stops)
	end)

	test("the sidebar's end session passes ended_by_commander to the runner", function()
		local miles_panel = require("workspace.legio.presentation.nvim.miles_panel")
		local action
		for _, a in ipairs(require("workspace.workbench.presentation.nvim.board").actions) do
			if a[3] == "resume or end a miles" then
				action = a
			end
		end
		check("the resume-or-end action exists", action ~= nil)
		if not action then
			return
		end
		local stops = {}
		local runner = {
			stop = function(_, id, done, reason)
				table.insert(stops, { id = id, reason = reason })
			end,
		}
		-- the panel reads the app table it loaded with, which a harness may have swapped: point every app the action reaches at our runner
		local tables = {}
		local function find_apps(fn, depth)
			if depth > 3 then
				return
			end
			for i = 1, 80 do
				local name, value = debug.getupvalue(fn, i)
				if not name then
					break
				end
				if name == "app" and type(value) == "table" then
					table.insert(tables, value)
				elseif type(value) == "function" then
					find_apps(value, depth + 1)
				end
			end
		end
		find_apps(action[2], 0)
		local saved = {}
		for _, t in ipairs(tables) do
			saved[t] = t.services
			t.services = function()
				return { miles_runner = runner }
			end
		end
		local ok, err = pcall(action[2], { component = miles_panel, id = "titus", miles_id = "titus", name = "Titus", toggle = "end", running = true }, { confirm = function() return true end })
		for t, v in pairs(saved) do
			t.services = v
		end
		check("the end runs without error", ok, err)
		check("the sidebar stops him with ended_by_commander", stops[1] ~= nil and stops[1].id == "titus" and stops[1].reason == "ended_by_commander", stops)
	end)

	test("an auxilium reporting to a caller stood down on purpose delivers nothing, names him stood down, and still stops with auxilium_done", function()
		local fx = setup(t.make_store)
		fx.stopped("titus", {}, "stopped", "stood_down")
		auxilium(fx, "aux1", "titus", nil)
		local names, stood_down = fx.service:report({ from = "aux1", text = "the parser is done" })
		check("nothing is delivered to the caller", vim.inspect(names) == vim.inspect({}), names)
		check("the stood-down caller is the second return", vim.inspect(stood_down) == vim.inspect({ "Titus" }), stood_down)
		check("no text is held for the stood-down caller", #fx.calls.held == 0, fx.calls.held)
		check("the auxilium is stopped with auxilium_done", fx.calls.stops[1] ~= nil and fx.calls.stops[1].id == "aux1" and fx.calls.stops[1].reason == "auxilium_done", fx.calls.stops)
	end)
end

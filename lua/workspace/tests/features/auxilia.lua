local Miles = require("workspace.legio.domain.miles")
local LegioProcess = require("workspace.legio.application.legio_process")
local MilesRepository = require("workspace.legio.infrastructure.outbound.filesystem.miles_repository")
local miles_record_mapper = require("workspace.legio.infrastructure.outbound.filesystem.miles_record_mapper")

return function(t)
	local test, check = t.test, t.check

	local function setup(o)
		local store = t.make_store(vim.fn.tempname())
		local milites = MilesRepository.new(store)
		store:update(Miles, "s1", function(a)
			a.legio, a.role, a.state, a.cwd, a.root = "x-rapax", "decanus", "working", "/p", "/p"
		end)
		store:update(Miles, "s2", function(a)
			a.state, a.cwd, a.root = "working", "/p", "/p"
		end)
		local calls = { started = {}, held = {}, stopped = {} }
		local next_id = 0
		local runner = {
			new_miles_id = function()
				next_id = next_id + 1
				return ("aux-%02d"):format(next_id)
			end,
			start = function(_, command, done)
				table.insert(calls.started, command)
				done(not (o and o.fails), "short")
			end,
			hold_text = function(_, id, text)
				table.insert(calls.held, { id = id, text = text })
			end,
			stop = function(_, id, done)
				table.insert(calls.stopped, id)
				milites:update(id, function(a)
					a:apply("end", 100)
				end)
				if done then
					done(not (o and o.stop_fails))
				end
			end,
		}
		local service = LegioProcess.new({
			legiones = require("workspace.legio.infrastructure.outbound.filesystem.legio_repository").new(store),
			cohortes = require("workspace.legio.infrastructure.outbound.filesystem.cohors_repository").new(store),
			centuriae = require("workspace.legio.infrastructure.outbound.filesystem.centuria_repository").new(store),
			contubernia = require("workspace.legio.infrastructure.outbound.filesystem.contubernium_repository").new(store),
			milites = milites,
			runner = runner,
			git = { locate = function() return { branch = "main" } end },
			todos = { done_command = "todo" },
			expeditiones = { get = function() return nil end },
			clock = function() return 100 end,
			random = math.random,
		})
		return service, calls, milites
	end

	local function call(service, from, job)
		local got = {}
		service:call_auxilium({ from = from, job = job }, function(ok, result)
			got.ok, got.result = ok, result
		end)
		return got
	end

	test("an auxilium starts with its job and is marked with the miles who called it", function()
		local service, calls, milites = setup()
		local got = call(service, "s1", "list the failing tests")
		check("calling in works", got.ok == true, got.result)
		check("it returns the auxilium's name", got.result == "auxilium aux-01", got.result)
		local command = calls.started[1]
		check("the helper is started with its id", command ~= nil and command.id == "aux-01")
		check("its prompt holds the job", command and command.prompt:find("list the failing tests", 1, true) ~= nil)
		check("its prompt says to report with legio report", command and command.prompt:find("legio report", 1, true) ~= nil)
		local aux = milites:find("aux-01")
		check("it is marked with its caller", aux ~= nil and aux.caller == "s1" and aux:is_auxilium())
		check("it is titled with its name", aux ~= nil and aux.title == "auxilium aux-01", aux and aux.title)
		check("it has no legio or role", aux ~= nil and aux.legio == nil and aux.role == nil)
	end)

	test("an auxilium that fails to start leaves no caller mark", function()
		local service, calls, milites = setup({ fails = true })
		local got = call(service, "s1", "count the migrations")
		check("the failed start is reported", got.ok == false and got.result == "the auxilium didn't start", got.result)
		check("it was attempted", #calls.started == 1)
		local aux = milites:find("aux-01")
		check("no caller mark is left", aux == nil or aux.caller == nil, aux and aux.caller)
	end)

	test("the report of an auxilium reaches its caller and stops it", function()
		local service, calls = setup()
		call(service, "s1", "count the migrations")
		local names = service:report({ from = "aux-01", text = "there are 12" })
		check("the report is delivered", names ~= nil and names[1] ~= nil, names)
		local held = calls.held[1]
		check("the caller receives the report", held ~= nil and held.id == "s1" and held.text:find("there are 12", 1, true) ~= nil, held)
		check("the auxilium is stopped after reporting", calls.stopped[#calls.stopped] == "aux-01", calls.stopped)
		check("the report starts with the auxilium's name", held ~= nil and held.text:sub(1, #"auxilium aux-01 reports: ") == "auxilium aux-01 reports: ", held and held.text)
		check("the report holds no legio order hint", held ~= nil and held.text:find("legio order", 1, true) == nil, held and held.text)
	end)

	test("an auxilium earns no rank when its work is credited", function()
		local service, _, milites = setup()
		call(service, "s1", "count the migrations")
		service:report({ from = "aux-01", text = "done" })
		service:credit_finished("s1", function() end)
		local aux = milites:find("aux-01")
		check("no mandata are credited to it", aux ~= nil and #(aux.mandata or {}) == 0)
		check("no expeditiones are credited to it", aux ~= nil and #(aux.expeditiones or {}) == 0)
		check("it stays at the base rank", aux ~= nil and aux:rank() == Miles.standing_of(0, 0).rank)
	end)

	test("a miles outside a legio can't call in an auxilium", function()
		local service, calls = setup()
		local got = call(service, "s2", "anything")
		check("the refusal names the legio rule", got.ok == false and got.result == "only a miles in a legio can call in an auxilium", got.result)
		check("nothing starts", #calls.started == 0)
	end)

	test("an auxilium can't call in another", function()
		local service, calls = setup()
		call(service, "s1", "first job")
		local nested = call(service, "aux-01", "second job")
		check("the refusal names the auxilium rule", nested.ok == false and nested.result == "an auxilium cannot call auxilia", nested.result)
		check("only the first auxilium starts", #calls.started == 1)
	end)

	test("a blank job is refused with its own message", function()
		local service, calls = setup()
		local got = call(service, "s1", "   ")
		check("the refusal names the job", got.ok == false and got.result == "an auxilium needs a job", got.result)
		check("a blank job starts nothing", #calls.started == 0)
	end)

	test("the miles record keeps the caller of an auxilium", function()
		local aux = Miles:new({ id = "aux-01", caller = "s1", title = "auxilium of ash" })
		local back = miles_record_mapper.to_domain(miles_record_mapper.to_record(aux))
		check("the caller survives the round trip", back.caller == "s1", back.caller)
		check("an auxilium is still an auxilium after the round trip", back:is_auxilium())
	end)

	local lapse_text = "auxilium aux-01 gave no report within 15 minutes and was stopped"

	test("an auxilium's deadline is set when it is called in", function()
		local service, _, milites = setup()
		call(service, "s1", "count the migrations")
		local aux = milites:find("aux-01")
		check("the deadline is the call plus the limit", aux ~= nil and aux.due == 100 + Miles.auxilium_limit, aux and aux.due)
	end)

	test("nothing lapses before the deadline", function()
		local service, calls, milites = setup()
		call(service, "s1", "count the migrations")
		service.clock = function()
			return 100 + Miles.auxilium_limit - 1
		end
		service:lapse_auxilia()
		check("the auxilium is not stopped", #calls.stopped == 0, calls.stopped)
		check("the caller is not told", #calls.held == 0, calls.held)
		check("it keeps its deadline", milites:find("aux-01").due == 100 + Miles.auxilium_limit)
	end)

	test("an overdue auxilium is stopped and its caller told exactly once", function()
		local service, calls, milites = setup()
		call(service, "s1", "count the migrations")
		service.clock = function()
			return 100 + Miles.auxilium_limit
		end
		service:lapse_auxilia()
		check("the overdue auxilium is stopped", calls.stopped[1] == "aux-01", calls.stopped)
		check("the caller is told", calls.held[1] ~= nil and calls.held[1].id == "s1" and calls.held[1].text == lapse_text, calls.held[1])
		service:lapse_auxilia()
		check("running it again tells no one twice", #calls.held == 1, #calls.held)
		check("and stops nothing twice", #calls.stopped == 1, calls.stopped)
		check("the deadline is cleared", milites:find("aux-01").due == nil)
	end)

	test("an auxilium that reported in time and a normal miles are never lapsed", function()
		local service, calls, milites = setup()
		call(service, "s1", "count the migrations")
		service:report({ from = "aux-01", text = "done" })
		check("reporting clears the deadline", milites:find("aux-01").due == nil)
		service.clock = function()
			return 100 + Miles.auxilium_limit * 10
		end
		service:lapse_auxilia()
		local lapsed = false
		for _, h in ipairs(calls.held) do
			if h.text == lapse_text then
				lapsed = true
			end
		end
		check("no timeout message follows the report", not lapsed, calls.held)
		check("the reported auxilium is not stopped again", #calls.stopped == 1, calls.stopped)
		check("a normal miles is never stopped", milites:find("s2").state == "working" and calls.stopped[2] == nil, calls.stopped)
	end)

	test("the deadline survives the miles record", function()
		local aux = Miles:new({ id = "aux-01", caller = "s1", due = 1000 })
		local back = miles_record_mapper.to_domain(miles_record_mapper.to_record(aux))
		check("the due time round-trips", back.due == 1000, back.due)
	end)

	test("an auxilium that can't be stopped says so to its caller", function()
		local service, calls = setup({ stop_fails = true })
		call(service, "s1", "count the migrations")
		service.clock = function()
			return 100 + Miles.auxilium_limit
		end
		service:lapse_auxilia()
		local told
		for _, h in ipairs(calls.held) do
			if h.id == "s1" and h.text:find("could not be stopped", 1, true) then
				told = h
			end
		end
		check("the caller is told it could not be stopped", told ~= nil and told.text:find("aux-01", 1, true) ~= nil, calls.held)
	end)

	test("a report from an auxilium that already lapsed is refused", function()
		local service, calls = setup()
		call(service, "s1", "count the migrations")
		service.clock = function()
			return 100 + Miles.auxilium_limit
		end
		service:lapse_auxilia()
		local before = #calls.held
		local names, err = service:report({ from = "aux-01", text = "too late" })
		check("the late report is refused", names == nil and err ~= nil, { names = names, err = err })
		check("the caller hears nothing more", #calls.held == before, calls.held)
	end)

	test("a lapse with the caller gone creates no record and sends nothing", function()
		local service, calls, milites = setup()
		local runner_started = call(service, "s1", "count the migrations")
		check("the auxilium was called in", runner_started.ok == true, runner_started.result)
		milites:update_existing("aux-01", function(a)
			a.caller = "s9"
		end)
		service.clock = function()
			return 100 + Miles.auxilium_limit
		end
		service:lapse_auxilia()
		check("no record is created for the missing caller", milites:find("s9") == nil)
		local sent = false
		for _, h in ipairs(calls.held) do
			if h.id == "s9" then
				sent = true
			end
		end
		check("nothing is sent to the missing caller", not sent, calls.held)
	end)
end

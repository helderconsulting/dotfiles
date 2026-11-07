local Miles = require("workspace.legio.domain.miles")
local LegioProcess = require("workspace.legio.application.legio_process")
local DeployLegioCommand = require("workspace.legio.application.commands.deploy_legio_command")
local MilesStatusDto = require("workspace.legio.application.dto.miles_status_dto")
local legio_cli_mapper = require("workspace.legio.infrastructure.inbound.mappers.legio_cli_mapper")
local HandoverProcess = require("workspace.legio.application.handover_process")
local HandOverCommand = require("workspace.legio.application.commands.hand_over_command")

local filesystem = "workspace.legio.infrastructure.outbound.filesystem."

return function(t)
	local test, check = t.test, t.check

	local function mandatum(id, title)
		return { id = id, title = title, text = "# " .. title .. "\n\nDo " .. title .. ".", state = "open" }
	end

	local function setup()
		local store = t.make_store(vim.fn.tempname())
		local calls = { started = {}, assigned = {} }
		local next_id, next_random = 0, 0
		local expeditiones = {
			e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = { mandatum("m1", "split the api"), mandatum("m2", "move the bridge") } },
		}
		local repos = {
			legiones = require(filesystem .. "legio_repository").new(store),
			cohortes = require(filesystem .. "cohors_repository").new(store),
			centuriae = require(filesystem .. "centuria_repository").new(store),
			contubernia = require(filesystem .. "contubernium_repository").new(store),
			milites = require(filesystem .. "miles_repository").new(store),
		}
		local runner = {
			new_miles_id = function()
				next_id = next_id + 1
				return ("m-%02d"):format(next_id)
			end,
			start = function(_, command, done)
				table.insert(calls.started, command)
				done(true, "short")
			end,
			hold_text = function() end,
			stop = function(_, _, done)
				done(true)
			end,
		}
		local todos = {
			done_command = "todo",
			assign = function(id, miles)
				calls.assigned[id] = miles
				return true
			end,
			send = function() end,
			release = function() end,
			text = function(id)
				return "# mandatum " .. id
			end,
		}
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
			},
			clock = function()
				return 100
			end,
			random = function(a, b)
				next_random = next_random + 1
				return a + next_random % (b - a + 1)
			end,
		})
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		return service, calls, repos.milites
	end

	test("a working miles with a running tool shows what he is doing and how quiet he is", function()
		local miles = Miles:new({ id = "abcdef1234", state = "working", doing = { label = "Bash · run tests", at = 90, running = true }, updated = 90 })
		local pulse = miles:pulse(100)
		check("the pulse names the tool he is running", pulse.doing == "Bash · run tests" and pulse.running == true, pulse)
		check("the pulse counts the seconds since his last activity", pulse.quiet == 10, pulse.quiet)
		check("the pulse has no orders waiting", pulse.waiting == 0, pulse.waiting)
	end)

	test("a miles with two orders held shows two waiting", function()
		local miles = Miles:new({ id = "abcdef1235", state = "working", updated = 90 })
		miles:hold("first", 90)
		miles:hold("second", 91)
		check("the pulse counts the held orders", miles:pulse(100).waiting == 2, miles:pulse(100).waiting)
	end)

	test("an idle miles has nothing waiting", function()
		local miles = Miles:new({ id = "abcdef1236", state = "idle", updated = 90 })
		local pulse = miles:pulse(100)
		check("no orders waiting", pulse.waiting == 0, pulse.waiting)
		check("no tool is running", pulse.doing == nil and pulse.running == false, pulse)
	end)

	test("status lists the milites under the caller as MilesStatusDto", function()
		local service, calls, milites = setup()
		local centurio
		for _, c in ipairs(calls.started) do
			if c.prompt:find("centurio of Legio X Rapax", 1, true) then
				centurio = c.id
			end
		end
		local out, why = service:status(centurio)
		check("the centurio gets a list", out ~= nil and why == nil, why)
		check("every entry is a MilesStatusDto", out and #out > 0 and MilesStatusDto.is(out[1]), out)
		local decanus = calls.assigned.m1
		local name = service:name_of(decanus)
		local found
		for _, s in ipairs(out or {}) do
			if s.name == name then
				found = s
			end
		end
		check("the decanus of the first contubernium is listed", found ~= nil, { name = name, out = out })
		milites:update(decanus, function(m)
			m.state = "working"
			m.doing = { label = "Bash · run tests", at = 90, running = true }
			m.updated = 90
			m:hold("first", 90)
			m:hold("second", 91)
		end)
		local after = service:status(centurio)
		local row
		for _, s in ipairs(after or {}) do
			if s.name == name then
				row = s
			end
		end
		check("his row shows his tool, quiet time and two waiting orders", row and row.doing == "Bash · run tests" and row.quiet == 10 and row.waiting == 2 and row.state == "working", row)
	end)

	test("someone with no post gets nothing and a reason", function()
		local service = setup()
		local out, why = service:status("nobody")
		check("no list", out == nil)
		check("the reason says he holds no post", why == "you hold no post in a legio", why)
	end)

	test("the cli shows each state, what he is doing, last activity, waiting orders", function()
		local text = legio_cli_mapper.to_status_lines({
			MilesStatusDto.new({ name = "Quintus", post = "faber", state = "working", doing = "Bash · run tests", running = true, quiet = 42, waiting = 2 }),
		})
		check("the line has the state", text:find("working", 1, true) ~= nil, text)
		check("the line has what he is doing", text:find("Bash · run tests", 1, true) ~= nil, text)
		check("the line has the time since his last activity", text:find("last activity 42s ago", 1, true) ~= nil, text)
		check("the line has the waiting orders", text:find("2 orders waiting", 1, true) ~= nil, text)
	end)

	test("the cli says so when no miles are under you", function()
		check("an empty status says no milites", legio_cli_mapper.to_status_lines({}) == "no milites under you\n")
	end)

	local function fallen_setup()
		local store = t.make_store(vim.fn.tempname())
		local calls = { started = {}, assigned = {}, held = {} }
		local next_id, next_random = 0, 0
		local expeditiones = {
			e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = { mandatum("m1", "split the api"), mandatum("m2", "move the bridge") } },
		}
		local repos = {
			legiones = require(filesystem .. "legio_repository").new(store),
			cohortes = require(filesystem .. "cohors_repository").new(store),
			centuriae = require(filesystem .. "centuria_repository").new(store),
			contubernia = require(filesystem .. "contubernium_repository").new(store),
			milites = require(filesystem .. "miles_repository").new(store),
		}
		local runner = {
			new_miles_id = function()
				next_id = next_id + 1
				return ("m-%02d"):format(next_id)
			end,
			start = function(_, command, done)
				table.insert(calls.started, command)
				done(true, "short")
			end,
			hold_text = function(_, id, text)
				table.insert(calls.held, { id = id, text = text })
			end,
			set_model = function(_, _, done)
				done(true)
			end,
			stop = function(_, _, done)
				done(true)
			end,
		}
		local todos = {
			done_command = "todo",
			assign = function(id, miles)
				calls.assigned[id] = miles
				return true
			end,
			send = function() end,
			release = function() end,
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
			log = function() end,
		})
		service:raise_legiones()
		service:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function() end)
		return { service = service, calls = calls, handover = handover, store = store }
	end

	local function started_with_text(calls, text)
		for _, c in ipairs(calls.started) do
			if c.prompt:find(text, 1, true) then
				return c
			end
		end
	end


	test("a decanus falls: the highest-ranked member becomes decanus, the supplementum takes the vacated post, and the centurio's status lists both and not the fallen miles", function()
		local s = fallen_setup()
		local centurio = started_with_text(s.calls, "centurio of Legio X Rapax").id
		local fallen = s.calls.assigned.m1
		local fallen_name = s.service:name_of(fallen)
		local result
		s.handover:hand_over(HandOverCommand.new({ miles_id = fallen, traditio = "split half done" }), function(ok, r)
			result = { ok = ok, r = r }
		end)
		check("the decanus falls and a supplementum starts", result and result.ok and result.r and result.r.supplementum ~= nil, result)
		local promoted = result and result.r and result.r.successor
		local vacated = result and result.r and result.r.role
		check("the highest-ranked member is promoted to decanus", promoted ~= nil and promoted ~= fallen_name, result)
		local supplementum = s.calls.started[#s.calls.started]
		local supplementum_name = s.service:name_of(supplementum.id)
		local promoted_id
		for _, m in ipairs(require(filesystem .. "miles_repository").new(s.store):plain_all()) do
			if m.roman_name == promoted then
				promoted_id = m.id
			end
		end
		check("the promoted member is found among the milites", promoted_id ~= nil, promoted)
		local out = s.service:status(centurio)
		local promoted_as_decanus, fallen_listed = false, false
		for _, row in ipairs(out or {}) do
			if row.post == "decanus" and row.name == promoted then
				promoted_as_decanus = true
			end
			if row.name == fallen_name then
				fallen_listed = true
			end
		end
		check("the centurio's status lists the promoted member as decanus", promoted_as_decanus, out)
		check("the fallen miles is not listed by the centurio", not fallen_listed, out)
		local under = promoted_id and s.service:status(promoted_id) or {}
		local supplementum_in_vacated = false
		for _, row in ipairs(under) do
			if row.post == vacated and row.name == supplementum_name then
				supplementum_in_vacated = true
			end
		end
		check("the supplementum holds the vacated post under the new decanus", supplementum_in_vacated, { vacated = vacated, under = under })
	end)

	test("when a decanus falls, his superior's notice names who took which post", function()
		local s = fallen_setup()
		local optio = started_with_text(s.calls, "You are the centurio's second").id
		local fallen = s.calls.assigned.m1
		local result
		s.handover:hand_over(HandOverCommand.new({ miles_id = fallen, traditio = "split half done" }), function(ok, r)
			result = { ok = ok, r = r }
		end)
		local promoted = result and result.r and result.r.successor
		local vacated = result and result.r and result.r.role
		local supplementum = s.calls.started[#s.calls.started]
		local supplementum_name = s.service:name_of(supplementum.id)
		local notice
		for _, h in ipairs(s.calls.held) do
			if h.id == optio then
				notice = h
			end
		end
		check("the optio, the decanus's superior, is told in a notice", notice ~= nil, s.calls.held)
		check("the notice names the promoted member as decanus", notice and promoted and notice.text:find(promoted, 1, true) and notice.text:find("decanus", 1, true) ~= nil, notice)
		check("the notice names the supplementum in the vacated post", notice and vacated and notice.text:find(supplementum_name, 1, true) and notice.text:find(vacated, 1, true) ~= nil, { vacated = vacated, notice = notice })
	end)

	test("the centurio's status lists the supplementum under the decanus post after a fall, and the fallen decanus is gone from his rows", function()
		local s = fallen_setup()
		local centurio = started_with_text(s.calls, "centurio of Legio X Rapax").id
		local before = s.service:status(centurio)
		check("before the fall, the decanus is listed", #(before or {}) > 0, before)
		local fallen = s.calls.assigned.m1
		s.handover:hand_over(HandOverCommand.new({ miles_id = fallen, traditio = "split half done" }), function() end)
		local after = s.service:status(centurio)
		local decanus_rows = 0
		for _, row in ipairs(after or {}) do
			if row.post == "decanus" then
				decanus_rows = decanus_rows + 1
			end
		end
		check("two decani are still listed after the supplementum fills", decanus_rows == 2, after)
	end)
end

-- DRAFT (mandatum 8a45): legio status shows every level below the caller. Written against the shape Publius describes
-- (depth and stopped on MilesStatusDto, chain_of_command.below, LegioProcess:status walking the tree, cli status lines).
-- Field names and CLI literals are to be re-checked against his code once he reports.
local LegioProcess = require("workspace.legio.application.legio_process")
local DeployLegioCommand = require("workspace.legio.application.commands.deploy_legio_command")
local MilesStatusDto = require("workspace.legio.application.dto.miles_status_dto")
local legio_cli_mapper = require("workspace.legio.infrastructure.inbound.mappers.legio_cli_mapper")

local filesystem = "workspace.legio.infrastructure.outbound.filesystem."

return function(t)
	local test, check = t.test, t.check

	local function mandatum(id, title)
		return { id = id, title = title, text = "# " .. title .. "\n\nDo " .. title .. ".", state = "open" }
	end

	-- the same deployment as legio_status.lua: one centuria, two contuberniums, each with a decanus and milites
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

	local function by_prompt(calls, post)
		for _, c in ipairs(calls.started) do
			if c.prompt:find(post .. " of Legio X Rapax", 1, true) then
				return c.id
			end
		end
	end

	local function rows_at(list, depth)
		local out = {}
		for _, s in ipairs(list or {}) do
			if s.depth == depth then
				table.insert(out, s)
			end
		end
		return out
	end

	test("a centurio's status lists every decanus at the top, and under each, his faber, probator and censor", function()
		local service, calls = setup()
		local centurio = by_prompt(calls, "centurio")
		local out, why = service:status(centurio)
		check("the centurio gets a list", out ~= nil and why == nil, why)
		check("every entry is a MilesStatusDto", out and #out > 0 and MilesStatusDto.is(out[1]), out)
		local decani = {}
		for _, s in ipairs(out or {}) do
			if s.post == "decanus" then
				table.insert(decani, s)
			end
		end
		local milites = rows_at(out, 1)
		check("the optio sits at the top, and two decani sit there too", #decani == 2 and rows_at(out, 0)[1].post == "optio", out)
		check("each decanus has post, state, last activity and orders waiting", decani[1] and decani[1].post == "decanus" and decani[1].state ~= nil and decani[1].quiet ~= nil and decani[1].waiting ~= nil, decani[1])
		local posts = {}
		for _, s in ipairs(milites) do
			table.insert(posts, s.post)
		end
		table.sort(posts)
		check("each decanus has his faber, probator and censor one level down", #milites == 6 and table.concat(posts, ",") == "censor,censor,faber,faber,probator,probator", posts)
	end)

	test("a miles two levels down who has stopped is marked stopped", function()
		local service, calls, milites = setup()
		local centurio = by_prompt(calls, "centurio")
		local member = rows_at(service:status(centurio), 1)[1]
		check("there is a member to stop", member ~= nil)
		if not member then
			return
		end
		local id
		for _, m in ipairs(milites:all()) do
			if (m.roman_name or m:display_name()) == member.name then
				id = m.id
			end
		end
		milites:update(id, function(m)
			m.state = "stopped"
		end)
		local found
		for _, s in ipairs(service:status(centurio) or {}) do
			if s.name == member.name then
				found = s
			end
		end
		check("the stopped miles is marked stopped", found ~= nil and found.stopped == true and found.state == "stopped", found)
	end)

	test("a decanus sees only his own milites", function()
		local service, calls = setup()
		local decanus = calls.assigned.m1
		local out = service:status(decanus)
		check("the decanus gets a list", out ~= nil, out)
		local other = service:name_of(calls.assigned.m2)
		local seen_other = false
		for _, s in ipairs(out or {}) do
			check("every row under a decanus sits at depth 0, his own level", s.depth == 0, s)
			if s.name == other then
				seen_other = true
			end
		end
		check("the other decanus is not in his list", not seen_other, out)
	end)

	test("an optio sees the same tree as the centurio", function()
		local service, calls = setup()
		local centurio = by_prompt(calls, "centurio")
		local optio = by_prompt(calls, "optio")
		local names_c, names_o = {}, {}
		for _, s in ipairs(service:status(centurio) or {}) do
			table.insert(names_c, s.name)
		end
		for _, s in ipairs(service:status(optio) or {}) do
			table.insert(names_o, s.name)
		end
		-- the centurio's view lists the optio as his second; the optio's own view is the same tree without his own row
		local without_optio = {}
		for _, name in ipairs(names_c) do
			if name ~= service:name_of(optio) then
				table.insert(without_optio, name)
			end
		end
		check("the optio's tree is the centurio's tree, without his own row", vim.inspect(names_o) == vim.inspect(without_optio), { names_c, names_o })
	end)

	test("the cli prints each level indented two spaces per depth, with the stopped mark only when the state is not stopped", function()
		local mapper = require("workspace.legio.infrastructure.inbound.mappers.legio_cli_mapper")
		local lines = mapper.to_status_lines({
			{ name = "Servius", post = "decanus", state = "working", depth = 0, waiting = 0, stopped = false },
			{ name = "Titus", post = "faber", state = "stopped", depth = 1, waiting = 1, stopped = true },
			{ name = "Gaius", post = "faber", state = "idle", depth = 2, waiting = 0, stopped = true },
		})
		local got = vim.split(lines, "\n", { plain = true })
		check("a decanus line is not indented", got[1] == "Servius (decanus): working · 0 orders waiting", got[1])
		check("a faber one level down is indented two spaces, and his state is stopped with no second stopped mark", got[2] == "  Titus (faber): stopped · 1 order waiting", got[2])
		check("a faber two levels down is indented four spaces and carries the stopped mark", got[3] == "    Gaius (faber): idle · stopped · 0 orders waiting", got[3])
	end)
end

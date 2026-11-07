local paths = require("workspace.shared.state.paths")
local Provider = require("workspace.shared.providers").current()
local function raw(moment, fields)
	return Provider.raw(moment, fields)
end
local function event(moment, fields)
	return Provider.session_event(Provider.raw(moment, fields))
end
local composition_root = require("workspace.composition_root")
local Miles = require("workspace.legio.domain.miles")
local MilesProcess = require("workspace.legio.domain.miles_process")
local AgentdStatus = require("workspace.legio.domain.agentd_status")
local Contubernium = require("workspace.legio.domain.contubernium")
local Usage = require("workspace.legio.domain.usage")
local Legio = require("workspace.legio.domain.legio")
local Cohors = require("workspace.legio.domain.cohors")
local Centuria = require("workspace.legio.domain.centuria")
local Question = require("workspace.conversations.domain.question")
local MilesRunner = require("workspace.legio.application.miles_runner")
local MilesSessionList = require("workspace.legio.domain.miles_session_list")
local dto_mapper = require("workspace.legio.application.mappers.miles_dto_mapper")
local view_mapper = require("workspace.legio.presentation.mappers.miles_view_mapper")
local bridge_mapper = require("workspace.legio.infrastructure.inbound.mappers.agentd_message_mapper")
local contubernium_cli_mapper = require("workspace.legio.infrastructure.inbound.mappers.contubernium_cli_mapper")
local title_cli_mapper = require("workspace.legio.infrastructure.inbound.mappers.title_cli_mapper")

local filesystem = "workspace.legio.infrastructure.outbound.filesystem."
local MilesRepository = require(filesystem .. "miles_repository")
local ContuberniumRepository = require(filesystem .. "contubernium_repository")

local function dto(name)
	return require("workspace.legio.application.dto." .. name)
end

local function command(name)
	return require("workspace.legio.application.commands." .. name)
end

local function view_model(name)
	return require("workspace.legio.presentation.view_models." .. name)
end

local stored = {
	{ kind = "milites", cls = Miles, mapper = "miles_record_mapper" },
	{ kind = "runtimes", cls = MilesProcess, mapper = "miles_process_record_mapper" },
	{ kind = "usage", cls = Usage, mapper = "usage_record_mapper" },
	{ kind = "daemons", cls = AgentdStatus, mapper = "agentd_status_record_mapper" },
	{ kind = "contubernia", cls = Contubernium, mapper = "contubernium_record_mapper" },
	{ kind = "legiones", cls = Legio, mapper = "legio_record_mapper" },
	{ kind = "cohortes", cls = Cohors, mapper = "cohors_record_mapper" },
	{ kind = "centuriae", cls = Centuria, mapper = "centuria_record_mapper" },
}

local samples = {
	milites = {
		{ id = "a1", state = "working", cwd = "/p", root = "/p", branch = "main", title = "t", name = "n", pid = 4, read_at = 1, activity = 2, updated = 3, doing = { label = "Bash: ls", at = 3, running = true }, prompt = { text = "go", at = 1 }, outbox = { { id = "1-1", text = "x", at = 1 } }, sending = { text = "y", at = 2 }, limit = { resets_at = 9, window = "5h" }, host = "agentd", pane = 3, worktree = "w" },
		{ id = "a2" },
	},
	runtimes = { { id = "a1", state = "sdk", provider = Provider.name, model = "m", since = 1, context = { used = 1, window = 2 }, mode = "plan", reason = "r" } },
	usage = { { id = Provider.name, windows = { { name = "5h", used = 0.5 } }, overage = "rejected", extra = true, updated = 1 } },
	daemons = { { id = "agentd", state = "up", since = 1, reason = "x" } },
	contubernia = { { id = "t1", name = "otter", todo = "ab", root = "/p", base = "main", members = { { name = "ash", agent = "a1" } }, created = 1 }, { id = "t2" } },
	legiones = { { id = "x-rapax", name = "Legio X Rapax", munus = "implement", roles = { "faber" }, annales = { { at = 1, text = "deployed on a" } }, mos_maiorum = {}, expeditio = "e1", centuria = "c1", raised = 1 }, { id = "ix" } },
	cohortes = { { id = "%p", root = "/p", pilus_prior = "a1", centuriae = { "c1" }, created = 1 }, { id = "%q" } },
	centuriae = { { id = "c1", legio = "x-rapax", cohors = "%p", expeditio = "e1", title = "a", root = "/p", centurio = "a1", optio = "a2", contubernia = { "t1" }, created = 1 }, { id = "c2" } },
}

local function records_root()
	local dir = vim.env.WORKSPACE_RECORDS or "/tmp/hx-state/workspace"
	if vim.uv.fs_stat(dir) then
		return dir
	end
	return paths.new(vim.env.HOME, vim.env.XDG_STATE_HOME).root
end

local function real_records(kind)
	local out = {}
	for _, file in ipairs(vim.fn.glob(records_root() .. "/" .. kind .. "/*.json", false, true)) do
		local ok, record = pcall(vim.json.decode, table.concat(vim.fn.readfile(file), "\n"), { luanil = { object = true, array = true } })
		if ok and type(record) == "table" then
			table.insert(out, record)
		end
	end
	return out
end

local function fake_ports(store, overrides)
	local calls = { agentd = {}, cli = {}, panes = {}, attach = {}, notes = {}, reports = {} }
	local ports = {
		milites = MilesRepository.new(store),
		contubernia = ContuberniumRepository.new(store),
		agentd = {
			call = function(req, done)
				table.insert(calls.agentd, req)
				local reply = overrides and overrides.agentd and overrides.agentd(req)
				done(reply == nil or reply.ok, reply or { id = req.id or "new-id" })
			end,
			hold = function()
				calls.held = true
			end,
		},
		cli = {
			provider = Provider.name,
			label = "cli",
			models = { "opus" },
			start = function(args, cwd, prompt, done)
				table.insert(calls.cli, { args = args, cwd = cwd, prompt = prompt })
				done(true, "short")
			end,
			stop = function(short, done)
				table.insert(calls.cli, { stop = short })
				if done then
					done(true)
				end
			end,
			launch_args = function(choice, resume)
				return { resume or choice.id or "" }
			end,
		},
		attach = {
			send = function(id, text, done)
				table.insert(calls.attach, { id = id, text = text })
				done(true)
			end,
			keys = function(id, keys, done)
				table.insert(calls.attach, { id = id, keys = keys })
				done(true)
			end,
			close = function() end,
		},
		panes = {
			send_keys = function(pane, text, paste, done)
				table.insert(calls.panes, { pane = pane, text = text, paste = paste })
				done(true)
			end,
		},
		sessions = {
			when_gone = function(_, _, done)
				done(true)
			end,
		},
		report = function(c)
			table.insert(calls.reports, c)
		end,
		notify = {
			info = function(m)
				table.insert(calls.notes, m)
			end,
			warn = function(m)
				table.insert(calls.notes, m)
			end,
			error = function(m)
				table.insert(calls.notes, m)
			end,
		},
		defer = function(fn)
			fn()
		end,
		folder_exists = function(p)
			return p ~= "/gone"
		end,
		trace = require("workspace.shared.lib.log").silent,
		clock = function()
			return 100
		end,
		random = function(a)
			return a
		end,
	}
	return MilesRunner.new(ports), calls
end

local function put_miles(store, id, fields)
	MilesRepository.new(store):update(id, function(a)
		for k, v in pairs(fields) do
			a[k] = v
		end
	end)
end

return function(t)
	local check = t.check

	t.test("legio: every stored record round-trips through its mapper", function()
		for _, s in ipairs(stored) do
			local mapper = require(filesystem .. s.mapper)
			local real = real_records(s.kind)
			local list = vim.list_extend(vim.deepcopy(samples[s.kind]), real)
			local same, unchanged = 0, 0
			for _, record in ipairs(list) do
				local back = mapper.to_record(mapper.to_domain(vim.deepcopy(record)))
				local today = s.cls:new(vim.deepcopy(record)):to_table()
				same = same + (vim.deep_equal(back, today) and 1 or 0)
				unchanged = unchanged + (vim.deep_equal(back, record) and 1 or 0)
				check(s.kind .. " " .. tostring(record.id) .. " maps like Model:to_table()", vim.deep_equal(back, today), { back = back, today = today })
			end
			check(s.kind .. " has real records to check", #real > 0 or vim.env.WORKSPACE_RECORDS == nil, records_root())
			check(s.kind .. " real records come back unchanged", unchanged >= #real, { unchanged = unchanged, real = #real })
			check(s.kind .. " maps to a domain model", getmetatable(mapper.to_domain(samples[s.kind][1])) == s.cls)
		end
	end)

	t.test("legio: repositories keep the store's update rules", function()
		local store = t.make_store(vim.fn.tempname())
		local milites = MilesRepository.new(store)
		local created
		milites:update("x", function(a, fresh)
			created = fresh
			a:apply("start", 1)
		end)
		check("an update makes a missing agent", created and milites:find("x").state == "idle")
		milites:update("x", function(a)
			a.title = "no"
			return false
		end)
		check("false writes nothing", milites:find("x").title == nil)
		milites:update_existing("ghost", function(a)
			a.title = "boo"
		end)
		check("update_existing leaves missing agents alone", milites:find("ghost") == nil)
		milites:update("x", function()
			return "delete"
		end)
		check("delete removes the record", milites:find("x") == nil)
		local contubernia = ContuberniumRepository.new(store)
		contubernia:save(Contubernium.make("t1", "ab", "/p", "main", { "a", "b" }, 1, "otter"))
		check("a contubernium is found by a member", contubernia:of("b") and contubernia:of("b").id == "t1" and contubernia:of("z") == nil)
		check("records stay plain json", store:get_record("contubernia", "t1").members[2].agent == "b")
	end)

	t.test("legio: the roster answers with DTOs", function()
		local store = t.make_store(vim.fn.tempname())
		local services = composition_root.build(store, {
			clock = function()
				return 50
			end,
		})
		put_miles(store, "a", { state = "working", root = "/p/x", title = "alpha", prompt = { text = "go", at = 10 }, updated = 10 })
		put_miles(store, "b", { state = "idle", root = "/p" })
		put_miles(store, "c", { state = "stopped", root = "/p" })
		ContuberniumRepository.new(store):save(Contubernium.make("t1", "ab", "/p", "main", { "a", "b" }, 1, "otter"))
		local roster = services.roster
		local all = roster:all()
		check("all agents come back as MilesDto", #all == 3 and dto("miles_dto").is(all[1]))
		local a = roster:get("a")
		check("an agent DTO carries its status and progress", a.name == "alpha" and a.state == "working" and a.busy and a.progress == "thinking · 40s" and a.channel == "attach", a)
		check("a missing agent is nil", roster:get("zz") == nil and roster:get(nil) == nil)
		local here = roster:running_in("/p")
		check("running agents in a folder, by name", #here == 2 and here[1].name == "alpha" and here[2].name == "p", here)
		local waiting = roster:awaiting_turn("a", function()
			return false
		end)
		check("a prompt the transcript lacks is awaited", dto("awaiting_turn_dto").is(waiting) and waiting.text == "go" and waiting.started)
		check("one it has isn't", roster:awaiting_turn("a", function()
			return true
		end) == nil)
		local contubernia = roster:all_contubernia()
		check("contubernia list their members with titles", #contubernia == 1 and dto("contubernium_dto").is(contubernia[1]) and contubernia[1].label == "contubernium otter" and contubernia[1].members[1].title == "ash · alpha" and contubernia[1].members[2].position == 2, contubernia)
		check("contubernium sizes", roster:contubernium_sizes().min == Contubernium.min and roster:fits_contubernium(2) and not roster:fits_contubernium(1))
		check("no agentd status yet", roster:agentd_status() == nil)
		require(filesystem .. "agentd_status_repository").new(store):update(function(d)
			return d:observe("drop", nil, 1)
		end)
		local status = roster:agentd_status()
		check("agentd health is a DTO", dto("agentd_status_dto").is(status) and status.health == "down" and status.health_tone == "bad")
		check("permission modes", #roster:permission_modes() == #MilesProcess.modes and roster:default_mode() == "auto")
	end)

	t.test("legio: the runner sends, holds and starts through its ports", function()
		local store = t.make_store(vim.fn.tempname())
		local runner, calls = fake_ports(store, {
			agentd = function(req)
				return req.op == "catalog" and { ok = false, error = "down" } or nil
			end,
		})
		put_miles(store, "s", { state = "idle", root = "/p" })
		require(filesystem .. "miles_process_repository").new(store):update("s", function(r)
			return r:observe({ event = "verify" }, 1)
		end)
		local sent
		runner:message(command("message_miles_command").new({ miles_id = "s", text = "hi" }), function(ok)
			sent = ok
		end)
		check("an sdk agent gets the message from agentd", sent and calls.agentd[1].op == "send" and calls.agentd[1].text == "hi")
		check("sending is remembered", MilesRepository.new(store):find("s").sending.text == "hi")
		put_miles(store, "p", { state = "idle", root = "/p", pane = 7 })
		runner:set_model(command("set_model_command").new({ miles_id = "p", model = "opus" }))
		check("a pane agent switches model by typing", calls.panes[1].text == "/model opus" and calls.panes[2].text == "\r")
		check("the switch is reported", calls.reports[#calls.reports].model == "opus" and command("process_report_command").is(calls.reports[#calls.reports]))
		local how
		runner:deliver(command("deliver_message_command").new({ miles_id = "w", cwd = "/p", text = "x" }))
		check("a stopped or unknown agent resumes", calls.agentd[#calls.agentd].resume == "w")
		put_miles(store, "busy", { state = "working", root = "/p" })
		runner:deliver(command("deliver_message_command").new({ miles_id = "busy", text = "later" }), function(_, h)
			how = h
		end)
		check("a busy agent holds it", how == "held" and #MilesRepository.new(store):find("busy"):held() == 1)
		runner:deliver(command("deliver_message_command").new({ cwd = "/p", text = "new", model = "opus" }))
		local start = calls.agentd[#calls.agentd]
		check("no agent starts one", start.op == "start" and start.prompt == "new" and start.model == "opus" and start.resume == nil)
		local failed
		runner:start(command("start_miles_command").new({ cwd = "/gone", prompt = "x" }), function(ok)
			failed = ok == false
		end)
		check("a missing folder doesn't start", failed and calls.notes[#calls.notes]:find("is gone", 1, true))
		local held = MilesRepository.new(store)
		held:update("s", function(a)
			a:hold("queued", 1)
		end)
		runner:release("s")
		check("a released message is sent", calls.agentd[#calls.agentd].text == "queued" and #held:find("s"):held() == 0)
		runner:set_title(command("set_miles_title_command").new({ miles_id = "nobody", title = "x" }))
		check("a retitle leaves unknown agents alone", held:find("nobody") == nil)
		runner:set_title(command("set_miles_title_command").new({ miles_id = "nobody", title = "x", create = true }))
		check("the title command makes one", held:find("nobody").title == "x")
		put_miles(store, "r", { state = "idle", read_at = 1 })
		runner:mark_read(command("mark_read_command").new({ miles_id = "r", at = 99 }))
		check("marking read", held:find("r").read_at == 99)
		check("ids look like session ids", runner:new_miles_id():match("^%x+%-%x+%-4%x+%-%x+%-%x+$") ~= nil)
		local catalog
		runner:catalog("/p", function(c)
			catalog = c
		end)
		check("without agentd the catalog lists the cli models", dto("model_catalog_dto").is(catalog[1]) and catalog[1].models[1].value == "opus")
		check("setup names the provider", dto("miles_setup_dto").is(runner:setup("s")) and runner:setup("s").provider == Provider.name)
		runner:watch_agentd()
		check("it keeps agentd held", calls.held)
	end)

	t.test("legio: session events and questions go through services", function()
		local root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		local store = t.make_store(root)
		local services = composition_root.build(store, { clock = os.time })
		local events = services.miles_session_events
		local reply = events:apply(command("session_event_command").new({ payload = event("start", { session_id = "e1", cwd = root }), background = true, host = "agentd" }))
		check("a hook start answers nothing", reply == nil)
		local a = MilesRepository.new(store):find("e1")
		check("the agent starts hosted", a and a.state == "idle" and a.host == "agentd")
		events:receive_report(bridge_mapper.to_process_report_command({ type = "runtime", id = "e1", provider = Provider.name, event = "verify", unknown = true }))
		check("a report with extra fields still lands", require(filesystem .. "miles_process_repository").new(store):get("e1").state == "sdk")
		local questions = services.miles_questions
		local id = questions:ask(command("ask_question_command").new({ session = "e1", tool = "Bash", input = {}, request = "r9", cwd = root }))
		check("an ask waits", questions:state(id).pending and MilesRepository.new(store):find("e1").state == "waiting")
		check("an unanswered ask has no reply", questions:reply(id) == nil)
		questions:withdraw(command("withdraw_question_command").new({ question_id = id }))
		local answer = questions:reply(id)
		check("a withdrawn ask replies deny and goes away", dto("question_reply_dto").is(answer) and answer.result.behavior == "deny" and questions:state(id) == nil)
		check("no viewer without a workspace", not questions:has_viewer("e1", root))
		local timing = questions:timing()
		check("question timing", timing.show_within == Question.show_within and timing.timeout == Question.timeout)
		events:sessions_running(command("sessions_running_command").new({ sessions = {} }))
		check("agentd losing a session ends it", MilesRepository.new(store):find("e1").state == "stopped")
		events:sessions_running(command("sessions_running_command").new({ sessions = {}, saved = {} }))
		check("and forgets it when not saved", MilesRepository.new(store):find("e1") == nil)
		vim.fn.delete(root, "rf")
	end)

	t.test("legio: syncing with the session files", function()
		local store = t.make_store(vim.fn.tempname())
		local services = composition_root.build(store, { clock = os.time })
		local events = services.miles_session_events
		local entries = { { sessionId = "live", pid = 1, cwd = "/p", status = "busy", name = "live one" } }
		events.sessions = {
			list = function()
				return MilesSessionList.new(entries, function()
					return true
				end)
			end,
		}
		put_miles(store, "gone", { state = "idle", root = "/p" })
		local sync = events:sync_session_files()
		check("sync answers how long to wait, if at all", sync == nil or type(sync) == "number")
		local milites = MilesRepository.new(store)
		check("a running session file adopts an agent", milites:find("live") and milites:find("live").state == "working" and milites:find("live").name == "live one")
		check("an agent without a session file ends", milites:find("gone").state == "stopped")
	end)

	t.test("legio: contubernium membership starts contubernia and passes messages", function()
		local store = t.make_store(vim.fn.tempname())
		local services = composition_root.build(store, { clock = os.time })
		local membership = services.contubernium_membership
		local started, assigned = {}, {}
		membership.runner = {
			start = function(_, c, done)
				table.insert(started, c)
				MilesRepository.new(store):update(c.id, function(a)
					a:apply("start", 1)
				end)
				done(true, c.id)
			end,
		}
		membership.todos = {
			done_command = "todo",
			assign = function(id, miles)
				assigned.assign = { id, miles }
				return true
			end,
			send = function(id, miles)
				assigned.send = { id, miles }
			end,
			release = function() end,
			reassign = function(id, from, to)
				assigned.reassign = { id, from, to }
			end,
		}
		membership.git = {
			locate = function()
				return { branch = "main" }
			end,
		}
		local result
		membership:start_contubernium(view_mapper.to_start_contubernium_command({ id = "ab", text = "# Split it", title = "Split it" }, "/p", 3, { model = "opus" }), function(ok, r)
			result = ok and r
		end)
		check("a contubernium starts every member", result and dto("contubernium_started_dto").is(result) and #started == 3 and started[1].model == "opus" and started[1].prompt:find("# Split it", 1, true))
		check("the lead gets the todo", assigned.assign[2] == started[1].id and assigned.send[2] == result.decanus_id)
		check("members are titled after their name", MilesRepository.new(store):find(started[2].id).title == "birch · Split it")
		local refused
		membership:start_contubernium(view_mapper.to_start_contubernium_command({ id = "ab", title = "x" }, "/p", 1), function(ok, why)
			refused = not ok and why
		end)
		check("a contubernium of one is refused", refused and refused:find("a contubernium has", 1, true))
		local contubernium = membership:contubernium_of(started[2].id)
		check("contubernium_of lists members with their state", dto("contubernium_dto").is(contubernium) and contubernium.members[1].state == "idle" and contubernium.members[1].decanus)
		local line = contubernium_cli_mapper.to_member_line(contubernium.members[2], started[2].id)
		check("the contubernium list line", line == "birch (you)\tidle\t?\n", line)
		local sent = membership:send_message(contubernium_cli_mapper.to_send_command(started[1].id, { "send", "all", "hello" }))
		check("a message reaches everyone else", dto("contubernium_message_sent_dto").is(sent) and #sent.recipients == 2 and contubernium_cli_mapper.to_sent_line(sent) == "sent to birch, cedar\n")
		check("an unknown member gets nothing", membership:send_message(contubernium_cli_mapper.to_send_command(started[1].id, { "send", "nobody", "x" })) == nil)
		membership:remove_miles(started[1].id)
		check("when the lead leaves the todo moves on", assigned.reassign and assigned.reassign[3] == started[2].id)
	end)

	t.test("legio: commands, DTOs and view models are real types", function()
		check("a command refuses unknown fields", not pcall(command("message_miles_command").new, { miles_id = "a", nope = 1 }))
		check("a DTO refuses unknown fields", not pcall(dto("miles_dto").new, { id = "a", nope = 1 }))
		check("a view model refuses unknown fields", not pcall(view_model("session_row_view_model").new, { id = "a", nope = 1 }))
		local miles = Miles:new({ id = "m1", state = "working", root = "/p", worktree = "w", updated = 1 })
		local runtime = MilesProcess.for_miles("m1")
		runtime:observe({ event = "verify", model = Provider.name .. "-opus-5-5", mode = "plan" }, 1)
		runtime:observe({ event = "context", used = 50, window = 100 }, 2)
		local row = view_mapper.to_miles_row(dto_mapper.to_miles_dto(miles:hydrate({ runtime = runtime }), 10), nil, "contubernium otter", 2)
		check("a row is a SessionRowViewModel", view_model("session_row_view_model").is(row) and row.place == "w" and row.sort_name == "contubernium otter 2")
		check("a row targets its miles the way drafts expect", row.target.agent == "m1" and view_mapper.to_deliver_command(row.target, "hi").miles_id == "m1", row.target)
		check("its meter is a MeterViewModel", view_model("meter_view_model").is(row.meter) and row.meter.percent == "50%" and row.meter.label == "opus · plan")
		local lines = view_mapper.to_card_lines(row, { sent = 1, resolved = 0 })
		check("a card shows its place and open comments", lines[2] == "w · contubernium otter" and lines[3]:find("1 open", 1, true))
		local entries = view_mapper.to_model_entries({ dto_mapper.to_model_catalog_dto(Provider.name, { { value = "opus", label = "Opus" } }) }, dto_mapper.to_miles_setup_dto(Provider.name, "opus"))
		check("model entries mark the one in use", view_model("pick_entry_view_model").is(entries[1]) and entries[1].current)
		local modes = view_mapper.to_mode_entries(dto_mapper.to_permission_mode_dtos(MilesProcess.modes), "plan")
		check("mode entries mark the current mode", #modes == #MilesProcess.modes and modes[4].current and not modes[1].current)
		local health = view_mapper.to_agentd_health_view_model(dto_mapper.to_agentd_status_dto(AgentdStatus:new({ id = "agentd", state = "failed" })))
		check("agentd health view model", view_model("agentd_health_view_model").is(health) and health.word == "failed" and health.tone == "bad")
		local sizes = view_mapper.to_contubernium_sizes_view_model(dto_mapper.to_contubernium_sizes_dto(2, 10))
		check("contubernium sizes prompt", sizes.prompt == "how many agents (2-10)? ")
		check("the start contubernium command carries the todo", command("start_contubernium_command").is(view_mapper.to_start_contubernium_command({ id = "t", text = "x", title = "y" }, "/p", 2)))
		check("a draft row", view_mapper.to_draft_row({ cwd = "/p/q", model = "opus" }, "new-p").word == "drafting · starts on send · opus")
		check("title args", title_cli_mapper.to_title({ "a\tb", "c" }) == "a b c" and title_cli_mapper.to_set_title_command("s", "x").create)
		local report = bridge_mapper.to_process_report_command({ type = "usage", provider = Provider.name, windows = {}, extra = true, mystery = 1 })
		check("bridge reports keep only known fields", command("process_report_command").is(report) and report.extra == true)
	end)
end

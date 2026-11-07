local unpack = unpack or table.unpack
local PostGuard = require("workspace.legio.domain.post_guard")
local Provider = require("workspace.shared.providers").current()
local function event(moment, fields)
	return Provider.session_event(Provider.raw(moment, fields))
end
local composition_root = require("workspace.composition_root")
local LegioProcess = require("workspace.legio.application.legio_process")
local filesystem = "workspace.legio.infrastructure.outbound.filesystem."
local MilesRepository = require(filesystem .. "miles_repository")
local ContuberniumRepository = require(filesystem .. "contubernium_repository")

local function command(name)
	return require("workspace.legio.application.commands." .. name)
end

local function deploy(store, o)
	require(filesystem .. "legio_repository").new(store):update("x-rapax", function(l)
		l.name, l.munus, l.roles, l.expeditio, l.centuria = "Legio X Rapax", "implement", { "faber", "probator", "censor" }, "e1", o.centuria
	end)
	require(filesystem .. "centuria_repository").new(store):update(o.centuria, function(c)
		local Cohors = require("workspace.legio.domain.cohors")
		c.legio, c.cohors, c.expeditio, c.root = "x-rapax", Cohors.key("/p"), "e1", "/p"
		c.centurio, c.optio, c.contubernia, c.created = o.centurio, o.optio or "o-deployed", o.contubernia or {}, 1
	end)
end

return function(t)
	local test, check = t.test, t.check

	local all_posts = { "centurio", "optio", "decanus", "faber", "probator", "censor", "explorator" }
	local leaders_and_censor = { "centurio", "optio", "decanus", "censor" }
	local writers = { "Edit", "Write", "NotebookEdit" }
	local git_commands = {
		"git commit -m x",
		"git push",
		"git push origin HEAD",
		"git worktree add ../w b",
		"cd /x && git commit -m x",
		"cd /x && git push",
		"cd /x && git worktree add ../w b",
		"git -C /x commit -m y",
		"git -C /x push",
		"git -C /x worktree add ../w b",
		"cd /x && git -C /x commit -m m",
		"rtk git push",
	}

	test("post guard: odd input never errors", function()
		local inputs = {
			{ n = 0 },
			{ "faber", nil, nil, nil, n = 4 },
			{ nil, true, "Edit", nil, n = 4 },
			{ "faber", false, 42, {}, n = 4 },
			{ "faber", false, "Edit", "not a table", n = 4 },
			{ "faber", false, "Bash", 5, n = 4 },
			{ "faber", false, "Bash", { command = 5 }, n = 4 },
			{ "faber", false, "Bash", { command = "" }, n = 4 },
			{ "faber", false, "Bash", {}, n = 4 },
			{ "faber", false, {}, {}, n = 4 },
		}
		for i, args in ipairs(inputs) do
			local ok, err = pcall(PostGuard.check, unpack(args, 1, args.n))
			check("odd input " .. i .. " doesn't error", ok, err)
		end
	end)

	test("post guard: tools and posts it doesn't govern pass", function()
		local reads_pass, status_pass = true, true
		for _, post in ipairs(all_posts) do
			if PostGuard.check(post, false, "Read", { file_path = "x" }) ~= nil then
				reads_pass = false
			end
			if PostGuard.check(post, false, "Bash", { command = "git status" }) ~= nil or PostGuard.check(post, false, "Bash", { command = "git -C /x log --oneline" }) ~= nil then
				status_pass = false
			end
		end
		check("a read passes for every post", reads_pass)
		check("a plain git status or log passes for every post", status_pass)
		check("a message that only mentions git push passes", PostGuard.check("faber", false, "Bash", { command = 'legio report "do not git push yet"' }) == nil)
	end)

	test("post guard: a faber's edits wait for his decanus's plan to be approved", function()
		for _, tool in ipairs(writers) do
			local reason = PostGuard.check("faber", false, tool, {})
			check("unapproved " .. tool .. " is refused with the plan steps", reason ~= nil and reason:find("plan", 1, true) ~= nil, reason)
			check("approved " .. tool .. " passes", PostGuard.check("faber", true, tool, {}) == nil)
		end
		check("an unapproved faber can still run tests", PostGuard.check("faber", false, "Bash", { command = "nvim --headless -l run.lua" }) == nil)
	end)

	test("post guard: centurio, optio, decanus and censor are refused edits, writes and notebook edits", function()
		for _, post in ipairs(leaders_and_censor) do
			for _, tool in ipairs(writers) do
				for _, approved in ipairs({ true, false }) do
					local reason = PostGuard.check(post, approved, tool, {})
					check(post .. " is refused " .. tool .. " (approved " .. tostring(approved) .. ")", reason ~= nil and reason:find("Blocked", 1, true) ~= nil, reason)
				end
			end
		end
	end)


	test("post guard: git commit, push, worktree add and worktree remove follow the git rights", function()
		local normal, commander = { commander_commits = false }, { commander_commits = true }
		local git_cmds = { "git commit -m x", "git push", "git worktree add ../w b", "git worktree remove ../w" }
		local others = { "centurio", "optio", "censor", "faber", "probator", "auxilium", "explorator", "primus pilus", "nobody" }
		for _, cmd in ipairs(git_cmds) do
			local input = { command = cmd }
			check("decanus may " .. cmd .. " with no rights", PostGuard.check("decanus", true, "Bash", input, "/work/tree", "/work/tree") == nil)
			check("decanus may " .. cmd .. " with commander_commits=false", PostGuard.check("decanus", true, "Bash", input, "/work/tree", "/work/tree", normal) == nil)
			local refused = PostGuard.check("decanus", true, "Bash", input, "/work/tree", "/work/tree", commander)
			check("decanus is refused " .. cmd .. " with commander_commits=true", refused ~= nil and refused:find("Blocked", 1, true) ~= nil, refused)
			for _, post in ipairs(others) do
				for _, rights in ipairs({ false, normal, commander }) do
					local r = PostGuard.check(post, true, "Bash", input, "/work/tree", "/work/tree", rights or nil)
					check(post .. " is refused " .. cmd .. " (rights " .. (rights and tostring(rights.commander_commits) or "none") .. ")", r ~= nil and r:find("Blocked", 1, true) ~= nil, r)
				end
			end
			local nil_post = PostGuard.check(nil, true, "Bash", input, "/work/tree", "/work/tree", normal)
			check("a nil role is refused " .. cmd, nil_post ~= nil and nil_post:find("Blocked", 1, true) ~= nil, nil_post)
		end
	end)

	test("post guard: git status and git log stay allowed for every post under any rights", function()
		local all_posts = { "centurio", "optio", "decanus", "faber", "probator", "censor", "explorator", "auxilium", "primus pilus" }
		for _, post in ipairs(all_posts) do
			for _, rights in ipairs({ nil, { commander_commits = false }, { commander_commits = true } }) do
				check(post .. " may git status", PostGuard.check(post, true, "Bash", { command = "git status" }, "/work/tree", "/work/tree", rights) == nil)
				check(post .. " may git log", PostGuard.check(post, true, "Bash", { command = "git -C /x log --oneline" }, "/work/tree", "/work/tree", rights) == nil)
			end
		end
	end)

	test("post guard: a refused call through events gets a deny with the reason", function()
		local root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		local store = t.make_store(root)
		local services = composition_root.build(store, { clock = os.time })
		local events = services.miles_session_events
		MilesRepository.new(store):update("c1", function(a)
			a.state, a.legio, a.role, a.roman_name = "idle", "x-rapax", "centurio", "Servius"
		end)
		deploy(store, { centuria = "cc1", centurio = "c1" })
		local reply = events:apply(command("session_event_command").new({
			payload = event("before_tool", { session_id = "c1", cwd = root, tool_name = "Edit", tool_input = { file_path = root .. "/a.lua" } }),
			background = true,
			host = "agentd",
		}))
		local out = reply and reply.hookSpecificOutput
		check("the centurio's edit is denied", out and out.permissionDecision == "deny", reply)
		check("the deny carries the reason", out and out.permissionDecisionReason and out.permissionDecisionReason:find("Blocked", 1, true) ~= nil, out)
	end)

	test("post guard: a miles with no plan record is not gated, and an unapproved one is", function()
		local root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		local store = t.make_store(root)
		local services = composition_root.build(store, { clock = os.time })
		local events = services.miles_session_events
		MilesRepository.new(store):update("f1", function(a)
			a.state, a.legio, a.role, a.roman_name = "idle", "x-rapax", "faber", "Tiberius"
		end)
		local function edit(session)
			return events:apply(command("session_event_command").new({
				payload = event("before_tool", { session_id = session, cwd = root, tool_name = "Edit", tool_input = { file_path = root .. "/a.lua" } }),
				background = true,
				host = "agentd",
			}))
		end
		check("a faber with no contubernium and so no plan record is not gated", edit("f1") == nil)
		deploy(store, { centuria = "c9", contubernia = { "t9" }, centurio = "other" })
		ContuberniumRepository.new(store):update("t9", function(c)
			c.todo = "m1"
			c.centuria = "c9"
			c.members = { { name = "Servius", miles = "d2", role = "decanus" }, { name = "Tiberius", miles = "f2", role = "faber" } }
			c.plan_required = true
			c:submit_plan("split the api", 1)
		end)
		MilesRepository.new(store):update("f2", function(a)
			a.state, a.legio, a.role, a.roman_name = "idle", "x-rapax", "faber", "Tiberius"
		end)
		local reply = edit("f2")
		check("a faber whose plan is submitted but not approved is denied", reply and reply.hookSpecificOutput and reply.hookSpecificOutput.permissionDecision == "deny", reply)
	end)

	test("post guard: a guard that throws allows the call and logs session, tool and error", function()
		local root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		local store = t.make_store(root)
		local services = composition_root.build(store, { clock = os.time })
		local events = services.miles_session_events
		local logged = {}
		events.log = function(entry)
			table.insert(logged, entry)
		end
		MilesRepository.new(store):update("c2", function(a)
			a.state, a.legio, a.role, a.roman_name = "idle", "x-rapax", "centurio", "Servius"
		end)
		deploy(store, { centuria = "cc2", centurio = "c2" })
		local real = PostGuard.check
		PostGuard.check = function()
			error("guard exploded")
		end
		local ok, reply = pcall(events.apply, events, command("session_event_command").new({
			payload = event("before_tool", { session_id = "c2", cwd = root, tool_name = "Edit", tool_input = { file_path = root .. "/a.lua" } }),
			background = true,
			host = "agentd",
		}))
		PostGuard.check = real
		check("the call goes through without an error", ok, reply)
		check("and it is not denied", ok and (reply == nil or not (reply.hookSpecificOutput and reply.hookSpecificOutput.permissionDecision == "deny")), reply)
		local found = false
		for _, entry in ipairs(logged) do
			local text = vim.inspect(entry)
			if text:find("guard exploded", 1, true) and text:find("Edit", 1, true) and text:find("c2", 1, true) then
				found = true
			end
		end
		check("the trace names the session, the tool and the error", found, logged)
	end)

	test("post guard: plan_required is set on a deployed contubernium and by taking a mandatum, and old or made records are never gated", function()
		local Contubernium = require("workspace.legio.domain.contubernium")
		local Legio = require("workspace.legio.domain.legio")
		local muster = require("workspace.legio.domain.muster")
		local LegioProcess = require("workspace.legio.application.legio_process")

		local legio = Legio.raise(Legio.standing[1], 1)
		local expeditio = { id = "e1", title = "agentd sdk", root = "/p", mandata = { { id = "m1", title = "split", text = "# split", state = "open" } } }
		local ids = 0
		local plan = muster.plan(legio, expeditio, {
			mandata = expeditio.mandata,
			taken_names = {},
			contubernia = {},
			base = "main",
			at = 1,
			random = function(a)
				return a
			end,
			done_command = "todo",
			new_id = function()
				ids = ids + 1
				return "id" .. ids
			end,
			centuria_id = function()
				return "c1"
			end,
			new_contubernium_id = function()
				return "t1"
			end,
		})
		local deployed = plan.squads[1].contubernium
		check("a deployed contubernium is plan-required", deployed.plan_required == true, deployed.plan_required)
		check("and gated until its plan is approved", deployed:plan_gate_open() == false)
		deployed:submit_plan("split the api", 2)
		deployed:approve_plan("Gaius", 3)
		check("approving the plan opens the gate", deployed:plan_gate_open() == true)

		local made = Contubernium.make("t2", "m2", "/p", "main", { "a", "b" }, 1, "otter")
		check("a contubernium from make is not plan-required", made.plan_required == nil and made:plan_gate_open() == true)
		local old = Contubernium:new({ id = "t3", todo = "m3", members = { { name = "ash", miles = "x", role = "faber" } } })
		check("an old record without the flag is never gated", old.plan_required == nil and old:plan_gate_open() == true)

		local root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		local store = t.make_store(root)
		local repo = require(filesystem .. "contubernium_repository").new(store)
		repo:update("t9", function(c)
			c.todo = "m9"
			c.centuria = "c9"
			c.members = { { name = "Servius", miles = "d1", role = "decanus" }, { name = "Tiberius", miles = "f1", role = "faber" } }
		end)
		local taken_by_hand_out = { hold = {} }
		local process = LegioProcess.new({
			contubernia = repo,
			todos = {
				assign = function()
					return true
				end,
				send = function() end,
				done_command = "todo",
			},
			runner = {
				hold_text = function(_, id, text)
					table.insert(taken_by_hand_out.hold, { id = id, text = text })
				end,
			},
			log = function() end,
		})
		process:hand_out(repo:get("t9"), { id = "m10", text = "# next" }, "done")
		local after_hand_out = repo:get("t9")
		check("after hand_out the contubernium is plan-required and gated", after_hand_out.plan_required == true and after_hand_out:plan_gate_open() == false, after_hand_out.plan_required)

		repo:update("t8", function(c)
			c.todo = "m8"
			c.centuria = "c9"
			c.members = { { name = "Servius", miles = "d8", role = "decanus" } }
		end)
		local expeditiones = {
			of = function()
				return { id = "e9", mandata = { { id = "m11", state = "open" } } }
			end,
		}
		local centuriae = {
			get = function()
				return { id = "c9", expeditio = "e9" }
			end,
			update_existing = function() end,
		}
		local taker = LegioProcess.new({ contubernia = repo, expeditiones = expeditiones, centuriae = centuriae, todos = {}, runner = {}, log = function() end })
		local ok = taker:take_mandatum("d8", "m11")
		check("take_mandatum takes the mandatum", ok == true, ok)
		local after_take = repo:get("t8")
		check("after take_mandatum the contubernium is plan-required and gated", after_take.plan_required == true and after_take:plan_gate_open() == false, after_take.plan_required)
	end)

	test("post guard: an old record without the flag is not gated through events", function()
		local root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		local store = t.make_store(root)
		local services = composition_root.build(store, { clock = os.time })
		local events = services.miles_session_events
		ContuberniumRepository.new(store):update("t7", function(c)
			c.todo = "m7"
			c.members = { { name = "Servius", miles = "d7", role = "decanus" }, { name = "Tiberius", miles = "f7", role = "faber" } }
		end)
		MilesRepository.new(store):update("f7", function(a)
			a.state, a.legio, a.role, a.roman_name = "idle", "x-rapax", "faber", "Tiberius"
		end)
		local reply = events:apply(command("session_event_command").new({
			payload = event("before_tool", { session_id = "f7", cwd = root, tool_name = "Edit", tool_input = { file_path = root .. "/a.lua" } }),
			background = true,
			host = "agentd",
		}))
		check("an old faber record is not gated by a plan", reply == nil, reply)
	end)

	local function plan_setup(o)
		o = o or {}
		local root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		local store = t.make_store(root)
		local names = { s1 = "Servius", t1 = "Titus", d1 = "Tiberius", f1 = "Marcus" }
		local centurio = "s1"
		if o.centurio == false then
			centurio = nil
		end
		local centuria = { id = "c1", optio = o.optio, centurio = centurio }
		function centuria:post_of(id)
			return id == self.optio or id == self.centurio
		end
		local held = {}
		local process = LegioProcess.new({
			contubernia = ContuberniumRepository.new(store),
			centuriae = {
				get = function(_, id)
					return id == "c1" and centuria or nil
				end,
				all = function(_)
					return { centuria }
				end,
			},
			milites = {
				find = function(_, id)
					return names[id] and require("workspace.legio.domain.miles"):new({ id = id, roman_name = names[id] }) or nil
				end,
				all = function()
					return {}
				end,
			},
			runner = {
				hold_text = function(_, id, text)
					table.insert(held, { id = id, text = text })
				end,
			},
			todos = {},
			log = function() end,
			clock = function()
				return 5
			end,
		})
		ContuberniumRepository.new(store):update("t1", function(c)
			c.todo = "m1"
			c.centuria = "c1"
			c.plan_required = true
			c.members = { { name = "Tiberius", miles = "d1", role = "decanus" }, { name = "Marcus", miles = "f1", role = "faber" } }
		end)
		return process, ContuberniumRepository.new(store), held
	end

	test("post guard: a decanus's plan goes to the optio for approval, or to the centurio when there is no optio", function()
		local process, repo, held = plan_setup({ optio = "t1" })
		local ok = process:submit_plan({ from = "d1", text = "split the api into two steps" })
		check("the decanus submits", ok == true, ok)
		check("the plan is stored on the contubernium", repo:get("t1").plan ~= nil and repo:get("t1").plan.text == "split the api into two steps")
		check("it is delivered to the optio alone", #held == 1 and held[1].id == "t1", held)
		check("the delivery holds the plan text and the approve command", held[1] and held[1].text:find("split the api into two steps", 1, true) and held[1].text:find("approve Tiberius", 1, true), held[1])

		local process2, repo2, held2 = plan_setup({ optio = nil })
		local ok2 = process2:submit_plan({ from = "d1", text = "no optio plan" })
		check("with no optio the plan still submits", ok2 == true, ok2)
		check("and goes to the centurio", #held2 == 1 and held2[1].id == "s1", held2)
		check("and the centurio is stored as approver", repo2:get("t1").plan ~= nil)
	end)

	test("post guard: only a decanus submits a plan", function()
		local process, repo, held = plan_setup({ optio = "t1" })
		local ok, why = process:submit_plan({ from = "f1", text = "a faber's plan" })
		check("a faber can't submit", ok == nil and why == "only a decanus submits a plan", why)
		check("nothing is stored or delivered", repo:get("t1").plan == nil and #held == 0)
	end)

	test("post guard: a plan with no optio or centurio to approve it is refused", function()
		local process, repo, held = plan_setup({ optio = nil, centurio = false })
		local ok, why = process:submit_plan({ from = "d1", text = "nobody to approve" })
		check("the submit is refused", ok == nil and why ~= nil and why:find("no optio or centurio", 1, true) ~= nil, why)
		check("nothing is stored or delivered", repo:get("t1").plan == nil and #held == 0)
	end)

	test("post guard: only the optio approves, or the centurio when there is no optio", function()
		local process, repo, held = plan_setup({ optio = "t1" })
		process:submit_plan({ from = "d1", text = "a plan" })
		for i = #held, 1, -1 do
			held[i] = nil
		end
		local ok, why = process:approve_plan({ from = "s1", name = "Tiberius" })
		check("the centurio can't approve while there is an optio", ok == nil and why ~= nil, why)
		local ok2, why2 = process:approve_plan({ from = "f1", name = "Tiberius" })
		check("a faber can't approve", ok2 == nil and why2 ~= nil, why2)
		check("nothing is approved yet", repo:get("t1"):plan_approved() == false)

		local ok3 = process:approve_plan({ from = "t1", name = "Tiberius" })
		check("the optio approves", ok3 == true, ok3)
		check("the plan records the optio as approver", repo:get("t1").plan.approved_by == "Titus", repo:get("t1").plan)
		check("the gate opens", repo:get("t1"):plan_gate_open() == true)
		check("the decanus is told it is approved", #held == 1 and held[1].id == "d1" and held[1].text:find("approved by Titus", 1, true) ~= nil, held)

		local process2, repo2 = plan_setup({ optio = nil })
		process2:submit_plan({ from = "d1", text = "a plan" })
		local ok4 = process2:approve_plan({ from = "s1", name = "Tiberius" })
		check("the centurio approves when there is no optio", ok4 == true and repo2:get("t1").plan.approved_by == "Servius", ok4)
	end)

	test("post guard: approve refuses a decanus with no plan or who is not under the approver", function()
		local process, repo = plan_setup({ optio = "t1" })
		local ok, why = process:approve_plan({ from = "t1", name = "Tiberius" })
		check("no plan to approve", ok == nil and why ~= nil and why:find("has submitted no plan", 1, true) ~= nil, why)
		process:submit_plan({ from = "d1", text = "a plan" })
		local ok2, why2 = process:approve_plan({ from = "t1", name = "Nobody" })
		check("an unknown decanus name is refused", ok2 == nil and why2 ~= nil and why2:find("no contubernium under you", 1, true) ~= nil, why2)
		check("still not approved", repo:get("t1"):plan_approved() == false)
	end)

	test("post guard: harmless mentions of git stay allowed for every post", function()
		local allowed = {
			'echo "git commit -m x"',
			'grep "git push" file',
			"rg commit",
			'legio report "I will git commit later"',
			"git log --grep=push",
			'git log --grep=push "$X"',
			"git status",
			"cat <<'EOF'\ngit commit\nEOF",
		}
		local all_posts = { "centurio", "optio", "decanus", "faber", "probator", "censor", "explorator" }
		for _, post in ipairs(all_posts) do
			for _, cmd in ipairs(allowed) do
				local reason = PostGuard.check(post, true, "Bash", { command = cmd })
				check(post .. " is allowed: " .. cmd, reason == nil, reason)
			end
		end
	end)


	test("post guard: real git commit, push and worktree add stay refused behind flags, wrappers and bash -c in a commander codebase", function()
		local refused = {
			"git --no-pager commit -m x",
			"git -c k=v push",
			"env git push",
			"sudo git push",
			"nohup git commit -m x",
			"bash -c 'git push'",
			'bash -c "git commit -m x"',
			"git -C /x --no-pager push",
			"git worktree add ../w b",
		}
		local all_posts = { "centurio", "optio", "decanus", "faber", "probator", "censor", "explorator", "primus pilus" }
		for _, post in ipairs(all_posts) do
			for _, cmd in ipairs(refused) do
				local reason = PostGuard.check(post, true, "Bash", { command = cmd }, "/work/tree", "/work/tree", { commander_commits = true })
				check(post .. " is refused: " .. cmd, reason ~= nil and reason:find("Blocked", 1, true) ~= nil, reason)
			end
		end
	end)

	test("post guard: a contubernium port without plan_gate_open logs port missing and allows", function()
		local MilesSessionEvents = require("workspace.legio.application.miles_session_events")
		local logged = {}
		local events = MilesSessionEvents.new({
			milites = {
				find = function(_, id)
					return { id = id, legio = "x-rapax", role = "faber" }
				end,
			},
			contubernia = {
				contubernium_of = function()
					return nil
				end,
			},
			log = function(entry)
				table.insert(logged, entry)
			end,
		})
		local reply = events:post_block({ moment = "before_tool", session_id = "f9", tool_name = "Edit", tool_input = { file_path = "a.lua" } })
		check("the call is allowed", reply == nil, reply)
		local found
		for _, entry in ipairs(logged) do
			if entry.event == "port missing" then
				found = entry
			end
		end
		check("it logs port missing with the session and the tool", found ~= nil and found.session == "f9" and found.tool == "Edit", logged)
	end)

	test("post guard: events built from the composition gate through the membership port", function()
		local root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		local store = t.make_store(root)
		local services = composition_root.build(store, { clock = os.time })
		local events = services.miles_session_events
		check("the membership answers plan_gate_open", type(services.contubernium_membership.plan_gate_open) == "function")
		require(filesystem .. "legio_repository").new(store):update("x-rapax", function(l)
			l.name, l.munus, l.roles, l.expeditio, l.centuria = "Legio X Rapax", "implement", { "faber", "probator", "censor" }, "e1", "c5"
		end)
		require(filesystem .. "centuria_repository").new(store):update("c5", function(c)
			c.legio, c.cohors, c.expeditio, c.root, c.centurio, c.optio, c.contubernia, c.created = "x-rapax", "k", "e1", "/p", "cz", "oz", { "t5" }, 1
		end)
		ContuberniumRepository.new(store):update("t5", function(c)
			c.todo = "m5"
			c.centuria = "c5"
			c.members = { { name = "Servius", miles = "d5", role = "decanus" }, { name = "Tiberius", miles = "f5", role = "faber" } }
			c.plan_required = true
			c:submit_plan("split", 1)
		end)
		MilesRepository.new(store):update("f5", function(a)
			a.state, a.legio, a.role, a.roman_name = "idle", "x-rapax", "faber", "Tiberius"
		end)
		local ok, reply = pcall(events.post_block, events, { moment = "before_tool", session_id = "f5", tool_name = "Edit", tool_input = { file_path = "a.lua" } })
		check("post_block does not crash through the composition port", ok, reply)
		check("an unapproved faber in a flagged contubernium is denied", ok and reply and reply.hookSpecificOutput and reply.hookSpecificOutput.permissionDecision == "deny", reply)
	end)
	test("post guard: an in-repo write by a leader is refused", function()
		local leaders = { "centurio", "optio", "decanus", "censor", "primus pilus", "pilus prior", "explorator", "nobody" }
		local refused = {
			{ "echo hi > out.txt", "/work/tree" },
			{ "echo hi >> notes.md", "/work/tree" },
			{ "echo hi > ./src/a.lua", "/work/tree" },
			{ "echo x | tee out.txt", "/work/tree" },
			{ "sed -i 's/a/b/' src/a.lua", "/work/tree" },
			{ "perl -i -pe 's/a/b/' src/a.lua", "/work/tree" },
			{ "echo hi > /work/tree/out.txt", "/work/tree" },
			{ "echo hi > ../tree/out.txt", "/work/tree/sub" },
			{ "echo hi > ../out.txt", "/work/tree/sub" },
		}
		for _, post in ipairs(leaders) do
			for _, case in ipairs(refused) do
				local reason = PostGuard.check(post, true, "Bash", { command = case[1] }, "/work/tree", case[2])
				check(post .. " is refused: " .. case[1] .. " in " .. case[2], reason ~= nil and reason:find("^Blocked") ~= nil and reason:find("Hand it to your faber", 1, true) ~= nil, reason)
			end
		end
	end)

	test("post guard: writes outside the repo, reads and quoted '>' are allowed for every post", function()
		local all_posts = { "centurio", "optio", "decanus", "faber", "probator", "censor", "explorator" }
		local allowed = {
			{ "echo hi > /tmp/x.txt", "/work/tree" },
			{ "echo hi >> /tmp/log.txt", "/work/tree" },
			{ "echo hi > /dev/null", "/work/tree" },
			{ "echo hi > /work/tree2/out", "/work/tree" },
			{ "cmd > /work/other/out.txt", "/work/tree" },
			{ "echo hi > ../../other/x", "/work/tree/sub" },
			{ "echo hi 2>&1", "/work/tree" },
			{ "echo hi >&2", "/work/tree" },
			{ "cat f | grep x | head", "/work/tree" },
			{ 'echo "a > b"', "/work/tree" },
			{ "grep '>' f", "/work/tree" },
			{ "sed 's/a/b/' src/a.lua", "/work/tree" },
			{ "cat src/a.lua | sed 's/a/b/'", "/work/tree" },
			{ "git status", "/work/tree" },
		}
		for _, post in ipairs(all_posts) do
			for _, case in ipairs(allowed) do
				local reason = PostGuard.check(post, true, "Bash", { command = case[1] }, "/work/tree", case[2])
				check(post .. " is allowed: " .. case[1] .. " in " .. case[2], reason == nil, reason)
			end
		end
	end)

	test("post guard: faber and probator are not affected by the Bash write rule", function()
		for _, post in ipairs({ "faber", "probator" }) do
			for _, command in ipairs({ "echo hi > out.txt", "echo x | tee out.txt", "sed -i 's/a/b/' src/a.lua", "perl -i -pe 's/a/b/' src/a.lua" }) do
				local reason = PostGuard.check(post, true, "Bash", { command = command }, "/work/tree", "/work/tree")
				check(post .. " is not refused: " .. command, reason == nil, reason)
			end
		end
	end)

	test("post guard: a git word after a real separator is refused in a commander codebase, a quoted one is not", function()
		local all_posts = { "centurio", "optio", "decanus", "faber", "probator", "censor", "explorator" }
		for _, post in ipairs(all_posts) do
			local reason = PostGuard.check(post, true, "Bash", { command = 'echo "hi"; git commit -m x' }, "/work/tree", "/work/tree", { commander_commits = true })
			check(post .. " is refused after a real semicolon", reason ~= nil and reason:find("Blocked", 1, true) ~= nil, reason)
			check(post .. " is allowed for a semicolon inside quotes", PostGuard.check(post, true, "Bash", { command = 'echo "a; git commit"' }, "/work/tree", "/work/tree") == nil)
			check(post .. " is allowed for && inside quotes", PostGuard.check(post, true, "Bash", { command = 'echo "a && git push"' }, "/work/tree", "/work/tree") == nil)
		end
	end)

	test("post guard: MultiEdit is refused for leaders and censor, and gated for a faber until approved", function()
		for _, post in ipairs({ "centurio", "optio", "decanus", "censor" }) do
			for _, approved in ipairs({ true, false }) do
				local reason = PostGuard.check(post, approved, "MultiEdit", { file_path = "a.lua", edits = {} })
				check(post .. " is refused MultiEdit (approved " .. tostring(approved) .. ")", reason ~= nil and reason:find("Blocked", 1, true) ~= nil, reason)
			end
		end
		local gated = PostGuard.check("faber", false, "MultiEdit", { file_path = "a.lua", edits = {} })
		check("an unapproved faber is gated on MultiEdit with the plan steps", gated ~= nil and gated:find("plan", 1, true) ~= nil, gated)
		check("an approved faber may MultiEdit", PostGuard.check("faber", true, "MultiEdit", { file_path = "a.lua", edits = {} }) == nil)
	end)

	test("known limits: not caught by design", function()
		check("known limit: $(git commit -m x) is not refused", PostGuard.check("faber", true, "Bash", { command = "echo $(git commit -m x)" }) == nil)
		check("known limit: a backtick git push is not refused", PostGuard.check("faber", true, "Bash", { command = "echo `git push`" }) == nil)
		check("known limit: a (git commit) subshell is not refused", PostGuard.check("faber", true, "Bash", { command = "(git commit -m x)" }) == nil)
		check("known limit: bash -c with an expansion words() can't parse is not refused", PostGuard.check("faber", true, "Bash", { command = 'bash -c "git push $HOME"' }) == nil)
		check("known limit: bash -c with ANSI-C quoting is not refused", PostGuard.check("faber", true, "Bash", { command = "bash -c $'git push'" }) == nil)
		check("known limit: python writing a file is not refused", PostGuard.check("centurio", true, "Bash", { command = "python3 -c \"open('a','w').write('x')\"" }) == nil)
		check("known limit: git inside eval is not refused", PostGuard.check("faber", true, "Bash", { command = 'eval "git commit -m x"' }) == nil)
	end)
	test("post guard: only faber, probator and auxilium may edit; every other post is refused", function()
		local refused_posts = { "centurio", "optio", "decanus", "censor", "primus pilus", "pilus prior", "explorator", "nobody" }
		local tools = { "Edit", "Write", "NotebookEdit", "MultiEdit" }
		for _, post in ipairs(refused_posts) do
			for _, tool in ipairs(tools) do
				for _, gate in ipairs({ true, false }) do
					local reason = PostGuard.check(post, gate, tool, { file_path = "a.lua" })
					check(post .. " is refused " .. tool .. " (gate " .. tostring(gate) .. ")", reason ~= nil and reason:find("Blocked", 1, true) ~= nil, reason)
				end
			end
		end
		for _, post in ipairs({ "probator", "auxilium" }) do
			for _, tool in ipairs(tools) do
				for _, gate in ipairs({ true, false }) do
					check(post .. " may " .. tool .. " (gate " .. tostring(gate) .. ")", PostGuard.check(post, gate, tool, { file_path = "a.lua" }) == nil)
				end
			end
		end
		for _, tool in ipairs(tools) do
			check("faber may " .. tool .. " once approved", PostGuard.check("faber", true, tool, { file_path = "a.lua" }) == nil)
			local gated = PostGuard.check("faber", false, tool, { file_path = "a.lua" })
			check("faber is gated on " .. tool .. " until approved", gated ~= nil and gated:find("plan", 1, true) ~= nil, gated)
		end
	end)

	test("post guard: a nil role is refused with a reason that names the role, without crashing", function()
		local ok, reason = pcall(PostGuard.check, nil, false, "Edit", { file_path = "a.lua" })
		check("a nil role doesn't crash", ok, reason)
		check("a nil role is refused and the reason names the role", ok and type(reason) == "string" and reason:find("nil", 1, true) ~= nil, reason)
		local ok2, reason2 = pcall(PostGuard.check, nil, true, "MultiEdit", {})
		check("a nil role's MultiEdit doesn't crash and is refused", ok2 and type(reason2) == "string" and reason2:find("Blocked", 1, true) ~= nil, reason2)
	end)

	test("post guard: a miles without a legio is untouched by the write rules", function()
		local MilesSessionEvents = require("workspace.legio.application.miles_session_events")
		local logged = {}
		local events = MilesSessionEvents.new({
			milites = {
				find = function(_, id)
					return { id = id, legio = nil, role = "centurio" }
				end,
			},
			legiones = { all = function() return {} end },
			contubernia = { plan_gate_open = function() return true end },
			centuriae = { all = function() return {} end, get = function() return nil end },
			cohortes = { all = function() return {} end, get = function() return nil end },
			contubernia_records = { of = function() return nil end },
			log = function(entry)
				table.insert(logged, entry)
			end,
		})
		local reply = events:post_block({ moment = "before_tool", session_id = "x1", tool_name = "Edit", tool_input = { file_path = "a.lua" }, cwd = "/work/tree" })
		check("a miles without a legio is not blocked", reply == nil, reply)
		check("and nothing is logged for it", #logged == 0, logged)
	end)

	test("post guard: a git commit glued to a separator with no space is refused for every post in a commander codebase", function()
		local all_posts = { "centurio", "optio", "decanus", "faber", "probator", "censor", "explorator", "primus pilus", "auxilium" }
		local commander = { commander_commits = true }
		for _, post in ipairs(all_posts) do
			local reason = PostGuard.check(post, true, "Bash", { command = ";git commit -m x" }, "/work/tree", "/work/tree", commander)
			check(post .. " is refused ;git commit with no space", reason ~= nil and reason:find("Blocked", 1, true) ~= nil, reason)
			local chained = PostGuard.check(post, true, "Bash", { command = "true&&git commit -m x" }, "/work/tree", "/work/tree", commander)
			check(post .. " is refused true&&git commit", chained ~= nil and chained:find("Blocked", 1, true) ~= nil, chained)
		end
	end)

	test("post guard: heredoc writes into the repo are refused for leaders, heredoc bodies and writes outside are not", function()
		local root, cwd = "/work/tree", "/work/tree"
		local refused = {
			"cat > /work/tree/notes.md <<EOF\nhello\nEOF",
			"cat >> notes.md <<'EOF'\nhello\nEOF",
		}
		for _, command in ipairs(refused) do
			local reason = PostGuard.check("centurio", true, "Bash", { command = command }, root, cwd)
			check("centurio is refused a heredoc write: " .. command:gsub("\n", " "), reason ~= nil and reason:find("^Blocked") ~= nil and reason:find("Hand it to your faber", 1, true) ~= nil, reason)
		end
		local allowed = {
			"cat <<'EOF'\nsed -i s/a/b/ notes.md\nEOF",
			"cat <<'EOF'\necho hi > notes.md\nEOF",
			"cat > /tmp/x <<EOF\nhello\nEOF",
			"sed -i -e s/x/y/ /tmp/f",
			"perl -i -pe s/a/b/ /tmp/f",
		}
		for _, post in ipairs({ "centurio", "optio", "decanus", "censor", "faber", "probator", "explorator" }) do
			for _, command in ipairs(allowed) do
				check(post .. " is allowed: " .. command:gsub("\n", " "), PostGuard.check(post, true, "Bash", { command = command }, root, cwd) == nil)
			end
		end
	end)

	test("known limits: a relative or missing cwd lets a write through", function()
		check("known limit: a missing cwd lets a redirect into the repo through", PostGuard.check("centurio", true, "Bash", { command = "echo hi > notes.md" }, "/work/tree", nil) == nil)
		check("known limit: an empty cwd lets an in-repo redirect through", PostGuard.check("centurio", true, "Bash", { command = "echo hi > notes.md" }, "/work/tree", "") == nil)
	end)
	local function prune_setup()
		local Centuria = require("workspace.legio.domain.centuria")
		local Legio = require("workspace.legio.domain.legio")
		local root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		local store = t.make_store(root)
		local contubernia = ContuberniumRepository.new(store)
		local e1 = { id = "e1", title = "agentd sdk", root = "/p", mandata = {
			{ id = "m1", title = "one", text = "# one", state = "open" },
			{ id = "m2", title = "two", text = "# two", state = "done" },
			{ id = "m3", title = "three", text = "# three", state = "open", assignee = "someone" },
			{ id = "m4", title = "four", text = "# four", state = "open" },
		} }
		local e2 = { id = "e2", title = "elsewhere", root = "/p", mandata = {
			{ id = "m6", title = "six", text = "# six", state = "open" },
		} }
		local expeditiones = { e1 = e1, e2 = e2 }
		local centuria = Centuria:new({ id = "c1", expeditio = "e1", centurio = "s1", optio = "t0", contubernia = { "t1", "t2" }, waiting = { "m1", "m2", "m3", "m4", "m6" }, created = 1 })
		local centuriae = {
			get = function(_, id)
				return id == "c1" and centuria or nil
			end,
			update_existing = function(_, id, fn)
				if id == "c1" then
					fn(centuria)
				end
			end,
		}
		local legio = Legio:new({ id = "x-rapax", expeditio = "e1", centuria = "c1", roles = {}, annales = {}, mos_maiorum = {} })
		local calls = { assigned = {}, held = {} }
		contubernia:update("t1", function(c)
			c.centuria, c.todo, c.created = "c1", "m0", 1
			c.members = { { name = "Servius", miles = "d1", role = "decanus" } }
			c.stood_by = nil
		end)
		contubernia:update("t2", function(c)
			c.centuria, c.todo, c.created = "c1", "m4", 2
			c.members = { { name = "Titus", miles = "d2", role = "decanus" } }
		end)
		local process = LegioProcess.new({
			legiones = { all = function() return { legio } end },
			centuriae = centuriae,
			contubernia = contubernia,
			expeditiones = {
				get = function(id) return expeditiones[id] end,
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
			todos = {
				assign = function(id, miles)
					calls.assigned[id] = miles
					return true
				end,
				send = function() end,
				done_command = "todo",
			},
			runner = {
				hold_text = function(_, id, text)
					table.insert(calls.held, { id = id, text = text })
				end,
			},
			log = function() end,
			clock = function()
				return 5
			end,
		})
		return process, centuria, calls, contubernia, e1, e2
	end


	test("prune: stand_by offers an open mandatum, drops a closed or moved one, and leaves assigned and held ones waiting", function()
		local process, centuria, calls = prune_setup()
		local ok = process:stand_by("d1")
		check("the decanus stands by", ok == true, ok)
		check("the open unassigned mandatum is handed out", calls.assigned.m1 == "d1", calls.assigned)
		check("a done mandatum is dropped and not handed out", calls.assigned.m2 == nil and not centuria:is_waiting("m2"), centuria.waiting)
		check("a mandatum that moved to another expeditio is dropped and not handed out", calls.assigned.m6 == nil and not centuria:is_waiting("m6"), centuria.waiting)
		check("an assigned mandatum is not handed out and stays waiting", calls.assigned.m3 == nil and centuria:is_waiting("m3"), centuria.waiting)
		check("a held mandatum is not handed out and stays waiting", calls.assigned.m4 == nil and centuria:is_waiting("m4"), centuria.waiting)
	end)


	test("prune: offer_mandatum drops a done mandatum and keeps an assigned or held one waiting", function()
		local process, centuria = prune_setup()
		local done = process:offer_mandatum("m2")
		check("a done mandatum is refused", done == nil, done)
		check("and dropped from the waiting list", not centuria:is_waiting("m2"), centuria.waiting)
		for _, id in ipairs({ "m3", "m4" }) do
			local r = process:offer_mandatum(id)
			check("offering " .. id .. " is refused", r == nil, r)
			check(id .. " stays on the waiting list", centuria:is_waiting(id), centuria.waiting)
		end
	end)


	test("prune: an open unassigned mandatum of the centuria's expeditio is still offered, and waits when every contubernium is busy", function()
		local process, centuria, calls, contubernia, e1 = prune_setup()
		table.insert(e1.mandata, { id = "m7", title = "seven", text = "# seven", state = "open" })
		local waits = process:offer_mandatum("m7")
		check("with every contubernium busy it waits", waits and waits.waits == true, waits)
		check("and stays on the waiting list", centuria:is_waiting("m7"), centuria.waiting)
		contubernia:update("t1", function(c)
			c.stood_by = 3
		end)
		local taken = process:offer_mandatum("m7")
		check("a stood-by contubernium takes it", taken and taken.taken == true and calls.assigned.m7 == "d1", taken)
		check("and it leaves the waiting list", not centuria:is_waiting("m7"), centuria.waiting)
	end)

	local function deployed_fixture(members)
		local Legio = require("workspace.legio.domain.legio")
		local Centuria = require("workspace.legio.domain.centuria")
		local Contubernium = require("workspace.legio.domain.contubernium")
		local legio = Legio:new({ id = "x-rapax", name = "Legio X Rapax", expeditio = "e1", centuria = "c1", roles = {}, annales = {}, mos_maiorum = {} })
		local centuria = Centuria:new({ id = "c1", legio = "x-rapax", expeditio = "e1", centurio = "cz", optio = "oz", contubernia = { "t1" }, waiting = {}, created = 1 })
		local contubernium = Contubernium:new({ id = "t1", centuria = "c1", todo = "m1", members = members, created = 1 })
		return {
			legiones = { all = function() return { legio } end },
			centuriae = {
				get = function(_, id)
					return id == "c1" and centuria or nil
				end,
				all = function() return { centuria } end,
			},
			contubernia_records = {
				get = function(_, id)
					return id == "t1" and contubernium or nil
				end,
				of = function(_, id)
					return contubernium:member_for(id) and contubernium or nil
				end,
			},
		}
	end

	local function rights_events(cohortes, miles_root)
		local MilesSessionEvents = require("workspace.legio.application.miles_session_events")
		local logged = {}
		local world = deployed_fixture({ { name = "Servius", miles = "d1", role = "decanus" } })
		local events = MilesSessionEvents.new({
			milites = {
				find = function(_, id)
					return { id = id, name = id, root = miles_root, cwd = miles_root, state = "idle" }
				end,
			},
			contubernia = {
				plan_gate_open = function()
					return true
				end,
			},
			cohortes = cohortes,
			legiones = world.legiones,
			centuriae = world.centuriae,
			contubernia_records = world.contubernia_records,
			log = function(entry)
				table.insert(logged, entry)
			end,
		})
		return events, logged
	end

	test("post guard: post_block refuses the decanus's commit in a commander codebase and allows it elsewhere", function()
		local Cohors = require("workspace.legio.domain.cohors")
		local root = "/Users/talaerts/.config"
		local key = Cohors.key(root)
		local cohortes = {
			get = function(_, k)
				if k == key then
					return Cohors:new({ id = key, root = root, commander_commits = true })
				end
			end,
		}
		local events = rights_events(cohortes, root)
		local reply = events:post_block({ moment = "before_tool", session_id = "d1", tool_name = "Bash", tool_input = { command = "git commit -m x" }, cwd = root })
		check("the decanus's commit is denied in the commander's codebase", reply and reply.hookSpecificOutput and reply.hookSpecificOutput.permissionDecision == "deny", reply)
		local worktree = events:post_block({ moment = "before_tool", session_id = "d1", tool_name = "Bash", tool_input = { command = "git worktree add ../w b" }, cwd = root })
		check("and the worktree add", worktree and worktree.hookSpecificOutput and worktree.hookSpecificOutput.permissionDecision == "deny", worktree)
		local elsewhere_events = rights_events(cohortes, "/work/other")
		local allowed = elsewhere_events:post_block({ moment = "before_tool", session_id = "d1", tool_name = "Bash", tool_input = { command = "git commit -m x" }, cwd = "/work/other" })
		check("the decanus can commit in a codebase with no commander flag", allowed == nil, allowed)
	end)

	test("post guard: a cohors lookup that errors refuses the decanus's commit and logs it", function()
		local cohortes = {
			get = function()
				error("cohors store is down")
			end,
		}
		local events, logged = rights_events(cohortes, "/work/tree")
		local reply = events:post_block({ moment = "before_tool", session_id = "d1", tool_name = "Bash", tool_input = { command = "git commit -m x" }, cwd = "/work/tree" })
		check("the decanus is treated as commander-commits and refused", reply and reply.hookSpecificOutput and reply.hookSpecificOutput.permissionDecision == "deny", reply)
		local found = false
		for _, entry in ipairs(logged) do
			if entry.event == "cohors lookup failed" and entry.session == "d1" then
				found = true
			end
		end
		check("and the lookup failure is logged", found, logged)
	end)
	test("post guard: a miles cannot run legio cohors commander-commits, however it is written, and harmless legio words stay allowed", function()
		local legio_posts = { "centurio", "optio", "decanus", "faber", "probator", "censor", "explorator", "primus pilus", "auxilium" }
		local sets = {
			"legio cohors commander-commits on",
			"legio cohors commander-commits off",
			"/Users/talaerts/.config/wezterm/bin/legio cohors commander-commits on",
			"cd /x && legio cohors commander-commits on",
			"rtk legio cohors commander-commits on",
			"env legio cohors commander-commits on",
		}
		for _, post in ipairs(legio_posts) do
			for _, cmd in ipairs(sets) do
				local reason = PostGuard.check(post, true, "Bash", { command = cmd }, "/work/tree", "/work/tree")
				check(post .. " is refused: " .. cmd, reason ~= nil and reason:find("Blocked", 1, true) ~= nil, reason)
			end
			for _, cmd in ipairs({ 'echo "legio cohors commander-commits on"', "legio status" }) do
				check(post .. " is allowed: " .. cmd, PostGuard.check(post, true, "Bash", { command = cmd }, "/work/tree", "/work/tree") == nil)
			end
		end
	end)

	test("known limits: indirect forms of the commander flag are not caught, a second line against honest mistakes", function()
		local cases = {
			{ "known limit: a bash -c string with ANSI-C quoting is not caught", "bash -c $'legio cohors commander-commits on'" },
			{ "known limit: python os.system is not caught", "python3 -c \"import os; os.system('legio cohors commander-commits on')\"" },
			{ "known limit: a symlinked binary is not caught", "lg cohors commander-commits on" },
			{ "known limit: a renamed copy of the script is not caught", "mylegio cohors commander-commits on" },
		}
		for _, case in ipairs(cases) do
			check(case[1], PostGuard.check("centurio", true, "Bash", { command = case[2] }, "/work/tree", "/work/tree") == nil)
		end
	end)

	test("prune: a waiting list of 44ee and 55ce offers 44ee and drops 55ce after stand_by", function()
		local process, centuria, calls, contubernia, e1, e2 = prune_setup()
		table.insert(e1.mandata, { id = "44ee", title = "forty-four", text = "# 44ee", state = "open" })
		table.insert(e2.mandata, { id = "55ce", title = "fifty-five", text = "# 55ce", state = "open" })
		centuria.waiting = { "44ee", "55ce" }
		local ok = process:stand_by("d1")
		check("the decanus stands by", ok == true, ok)
		check("44ee is offered to the standing-by decanus", calls.assigned["44ee"] == "d1", calls.assigned)
		check("55ce is dropped and not offered", calls.assigned["55ce"] == nil and not centuria:is_waiting("55ce"), centuria.waiting)
		check("44ee, offered and taken, has a home and leaves waiting", not centuria:is_waiting("44ee"), centuria.waiting)
	end)

	test("prune: an offered mandatum with every contubernium busy stays listed", function()
		local process, centuria, calls, contubernia, e1 = prune_setup()
		table.insert(e1.mandata, { id = "44ee", title = "forty-four", text = "# 44ee", state = "open" })
		centuria.waiting = { "44ee" }
		local r = process:offer_mandatum("44ee")
		check("every contubernium busy: it waits", r and r.waits == true, r)
		check("and 44ee stays listed in waiting", centuria:is_waiting("44ee"), centuria.waiting)
		check("and nobody is handed it", calls.assigned["44ee"] == nil, calls.assigned)
	end)
	local function run_cli(args, from, service)
		local provider = require("workspace.shared.providers").current()
		local nvim = require("workspace.shared.adapters.nvim")
		local composition_root = require("workspace.composition_root")
		local git = require("workspace.shared.adapters.git")
		local cli = require("workspace.legio.infrastructure.inbound.legio_cli")
		local saved = { session = provider.current_session, store = nvim.new_store, logger = nvim.logger, build = composition_root.build, locate = git.locate, write = vim.uv.fs_write }
		local calls, errs = {}, {}
		provider.current_session = function()
			return from
		end
		nvim.new_store = function()
			return {}
		end
		nvim.logger = function()
			return function() end
		end
		composition_root.build = function()
			return {
				legio_process = {
					set_commander_commits = function(_, f, root, on)
						table.insert(calls, { from = f, root = root, on = on })
						return service.ok, service.why
					end,
				},
			}
		end
		git.locate = function()
			return { root = "/work/tree" }
		end
		vim.uv.fs_write = function(fd, data)
			if fd == 2 then
				table.insert(errs, data)
			end
			return #data
		end
		local out = io.tmpfile()
		local saved_out = io.output()
		io.output(out)
		local ok, code = pcall(cli.run, args)
		io.output(saved_out)
		out:seek("set")
		local text = out:read("*a")
		out:close()
		provider.current_session, nvim.new_store, nvim.logger, composition_root.build, git.locate, vim.uv.fs_write = saved.session, saved.store, saved.logger, saved.build, saved.locate, saved.write
		return ok and code or nil, calls, text, table.concat(errs)
	end

	test("cli: legio cohors commander-commits on and off run without a session id and report the flag", function()
		local code, calls, text = run_cli({ "cohors", "commander-commits", "on" }, nil, { ok = true })
		check("on runs with no session id", code == 0 and calls[1] and calls[1].from == nil and calls[1].on == true, { code, calls })
		check("on says the commander commits here", text:find("does", 1, true) ~= nil and text:find("/work/tree", 1, true) ~= nil, text)
		local code2, calls2, text2 = run_cli({ "cohors", "commander-commits", "off" }, nil, { ok = true })
		check("off runs with no session id", code2 == 0 and calls2[1].on == false, { code2, calls2 })
		check("off says the commander no longer commits here", text2:find("no longer does", 1, true) ~= nil, text2)
	end)

	test("cli: legio cohors refuses an enlisted miles and a codebase with no cohors, with the reason", function()
		local code, _, _, err = run_cli({ "cohors", "commander-commits", "on" }, "f1", { ok = nil, why = "an enlisted miles can't set this: only the commander does" })
		check("an enlisted miles is refused with its reason", code == 1 and err:find("an enlisted miles can't set this", 1, true) ~= nil, { code, err })
		local code2, _, _, err2 = run_cli({ "cohors", "commander-commits", "on" }, nil, { ok = nil, why = "no cohors for this codebase" })
		check("a codebase with no cohors is refused with its reason", code2 == 1 and err2:find("no cohors for this codebase", 1, true) ~= nil, { code2, err2 })
	end)

	test("cli: legio cohors shows usage for a bad argument and runs nothing", function()
		for _, args in ipairs({ { "cohors" }, { "cohors", "commander-commits" }, { "cohors", "commander-commits", "maybe" }, { "cohors", "other", "on" } }) do
			local code, calls, _, err = run_cli(args, nil, { ok = true })
			check("usage for " .. table.concat(args, " "), code == 1 and #calls == 0 and err:find("commander-commits", 1, true) ~= nil, { code, #calls, err })
		end
	end)

	local function flag_setup(store_root, cohors_key)
		local Cohors = require("workspace.legio.domain.cohors")
		local key = Cohors.key(store_root)
		local records = {}
		if cohors_key ~= false then
			records[key] = Cohors:new({ id = key, root = store_root, commander_commits = false })
		end
		local milites = { members = {} }
		function milites:get(id)
			return self.members[id]
		end
		local process = require("workspace.legio.application.legio_process").new({
			milites = milites,
			cohortes = {
				get = function(_, k)
					return records[k]
				end,
				update_existing = function(_, k, fn)
					if records[k] then
						fn(records[k])
					end
				end,
			},
			log = function() end,
			clock = function()
				return 1
			end,
		})
		return process, records[key], records, key
	end


	local function real_world()
		local Cohors = require("workspace.legio.domain.cohors")
		local root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		local store = t.make_store(root)
		local milites = MilesRepository.new(store)
		local cohortes = require(filesystem .. "cohors_repository").new(store)
		local process = LegioProcess.new({ milites = milites, cohortes = cohortes, log = function() end, clock = function() return 1 end })
		return process, milites, cohortes, Cohors
	end

	test("set_commander_commits (real repositories): an enlisted miles is refused and the flag stays, a non-miles or nil session sets it and off restores it", function()
		local process, milites, cohortes, Cohors = real_world()
		local key = Cohors.key("/work/tree")
		cohortes:update(key, function(c)
			c.root, c.commander_commits = "/work/tree", false
		end)
		milites:update("f1", function(a)
			a.legio, a.role, a.roman_name = "x-rapax", "faber", "Marcus"
		end)
		local ok, why = process:set_commander_commits("f1", "/work/tree", true)
		check("an enlisted miles is refused", ok == nil and why == "an enlisted miles can't set this: only the commander does", why)
		check("and the flag is unchanged", cohortes:get(key):committed_by_commander() == false)
		local ok2 = process:set_commander_commits("orphan", "/work/tree", true)
		check("a session that is no miles sets it on", ok2 == true and cohortes:get(key):committed_by_commander() == true)
		local ok3 = process:set_commander_commits("orphan", "/work/tree", false)
		check("and off restores it", ok3 == true and cohortes:get(key):committed_by_commander() == false)
		local ok4 = process:set_commander_commits(nil, "/work/tree", true)
		check("a nil session (the commander at a terminal) sets it on", ok4 == true and cohortes:get(key):committed_by_commander() == true)
	end)


	test("set_commander_commits (real repositories): a codebase with no cohors is refused, and so is a worktree root", function()
		local process, _, cohortes, Cohors = real_world()
		local ok, why = process:set_commander_commits(nil, "/work/tree", true)
		check("no cohors for this codebase", ok == nil and why == "no cohors for this codebase", why)
		check("nothing is recorded", cohortes:get(Cohors.key("/work/tree")) == nil)
		cohortes:update(Cohors.key("/work/tree"), function(c)
			c.root, c.commander_commits = "/work/tree", false
		end)
		local ok2, why2 = process:set_commander_commits(nil, "/work/tree/.claude/worktrees/x", true)
		check("run from a worktree root the flag is refused with no cohors", ok2 == nil and why2 == "no cohors for this codebase", why2)
		check("and the codebase's own flag is untouched", cohortes:get(Cohors.key("/work/tree")):committed_by_commander() == false)
	end)

	test("post guard: a quoted mention of the commander flag is allowed, and a bare one is refused for every post", function()
		local posts = { "centurio", "optio", "decanus", "faber", "probator", "censor", "explorator", "primus pilus", "auxilium" }
		for _, post in ipairs(posts) do
			check(post .. " may mention the flag in a report", PostGuard.check(post, true, "Bash", { command = 'legio report "cohors commander-commits"' }, "/work/tree", "/work/tree") == nil)
			local reason = PostGuard.check(post, true, "Bash", { command = "legio cohors commander-commits on" }, "/work/tree", "/work/tree")
			check(post .. " is refused the bare flag", reason ~= nil and reason:find("Blocked", 1, true) ~= nil, reason)
		end
	end)

	test("known limits: bash -c with the flag in a quoted string passes the guard", function()
		check("known limit: bash -c \"legio cohors commander-commits on\" is not caught", PostGuard.check("centurio", true, "Bash", { command = 'bash -c "legio cohors commander-commits on"' }, "/work/tree", "/work/tree") == nil)
	end)
	local function live_world(o)
		o = o or {}
		local Cohors = require("workspace.legio.domain.cohors")
		local root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		local store = t.make_store(root)
		local services = composition_root.build(store, { clock = os.time })
		local repo_root = o.root or "/work/tree"
		require(filesystem .. "legio_repository").new(store):update("x-rapax", function(l)
			l.name, l.munus, l.roles, l.expeditio, l.centuria = "Legio X Rapax", "implement", { "faber", "probator", "censor" }, "e1", "c1"
		end)
		local function miles(id)
			MilesRepository.new(store):update(id, function(a)
				a.name, a.root, a.cwd, a.state, a.title = id, repo_root, repo_root, "idle", "live " .. id
			end)
		end
		local Cohors = require("workspace.legio.domain.cohors")
		local function centuria(id, fields)
			require(filesystem .. "centuria_repository").new(store):update(id, function(c)
				c.legio, c.cohors, c.expeditio, c.root = "x-rapax", fields.cohors or Cohors.key(repo_root), "e1", repo_root
				c.centurio, c.optio, c.contubernia, c.created = fields.centurio, fields.optio, fields.contubernia or {}, 1
			end)
		end
		local function contubernium(id, fields)
			ContuberniumRepository.new(store):update(id, function(c)
				c.todo, c.centuria, c.created, c.root = "m1", fields.centuria, 1, repo_root
				c.members = fields.members
				c.plan_required = fields.plan_required
				if fields.plan then
					c:submit_plan("the plan", 1)
					if fields.approved then
						c:approve_plan("Titus", 2)
					end
				end
			end)
		end
		local function cohors(fields)
			local key = Cohors.key(repo_root)
			require(filesystem .. "cohors_repository").new(store):update(key, function(c)
				c.root, c.primus_pilus, c.centuriae, c.created = repo_root, fields.primus_pilus, { "c1" }, 1
				c.commander_commits = fields.commander_commits == true
			end)
		end
		local function events_for(session, tool, input)
			return services.miles_session_events:post_block({ moment = "before_tool", session_id = session, tool_name = tool, tool_input = input, cwd = repo_root })
		end
		return { services = services, store = store, miles = miles, centuria = centuria, contubernium = contubernium, cohors = cohors, events_for = events_for, root = repo_root }
	end

	local function denied(reply)
		return reply ~= nil and reply.hookSpecificOutput ~= nil and reply.hookSpecificOutput.permissionDecision == "deny"
	end

	test("live shape: a miles with no legio or role is gated by its centuria post, centurio and optio refused edits", function()
		local w = live_world()
		w.miles("c-m")
		w.miles("o-m")
		w.centuria("c1", { centurio = "c-m", optio = "o-m", contubernia = {} })
		local centurio = w.events_for("c-m", "Edit", { file_path = "a.lua" })
		check("a centurio with no legio or role on his record is denied an edit", denied(centurio), centurio)
		local optio = w.events_for("o-m", "Edit", { file_path = "a.lua" })
		check("an optio with no legio or role on his record is denied an edit", denied(optio), optio)
	end)

	test("live shape: decanus and censor come from their contubernium members, faber is gated, probator is allowed", function()
		local w = live_world()
		w.miles("d-m")
		w.miles("f-m")
		w.miles("p-m")
		w.miles("s-m")
		w.centuria("c1", { centurio = "other", optio = "other2", contubernia = { "t1" } })
		w.contubernium("t1", { centuria = "c1", members = { { name = "Servius", miles = "d-m", role = "decanus" }, { name = "Tiberius", miles = "f-m", role = "faber" }, { name = "Manius", miles = "p-m", role = "probator" }, { name = "Lucius", miles = "s-m", role = "censor" } }, plan = true, plan_required = true })
		check("a decanus from a member role is denied an edit", denied(w.events_for("d-m", "Edit", { file_path = "a.lua" })))
		check("a censor from a member role is denied an edit", denied(w.events_for("s-m", "Edit", { file_path = "a.lua" })))
		check("a faber with an unapproved plan is gated", denied(w.events_for("f-m", "Edit", { file_path = "a.lua" })))
		check("a probator is allowed an edit", w.events_for("p-m", "Edit", { file_path = "a.lua" }) == nil)
	end)

	test("live shape: an approved faber is allowed an edit, and an unapproved one is gated", function()
		local w = live_world()
		w.miles("f-approved")
		w.miles("f-open")
		w.centuria("c1", { centurio = "other", optio = "other2", contubernia = { "t1", "t2" } })
		w.contubernium("t1", { centuria = "c1", members = { { name = "Servius", miles = "d1", role = "decanus" }, { name = "Tiberius", miles = "f-approved", role = "faber" } }, plan = true, approved = true, plan_required = true })
		w.contubernium("t2", { centuria = "c1", members = { { name = "Titus", miles = "d2", role = "decanus" }, { name = "Marcus", miles = "f-open", role = "faber" } }, plan = true, plan_required = true })
		check("the approved faber may edit", w.events_for("f-approved", "Edit", { file_path = "a.lua" }) == nil)
		check("the faber whose plan is still open is gated", denied(w.events_for("f-open", "Edit", { file_path = "a.lua" })))
	end)


	test("live shape: a primus pilus with his role on the record is denied an edit, even as a member faber with an approved plan", function()
		local w = live_world()
		w.miles("pp")
		MilesRepository.new(w.store):update("pp", function(a)
			a.role = "primus pilus"
		end)
		w.centuria("c1", { centurio = "other", optio = "other2", contubernia = { "t1" } })
		w.contubernium("t1", { centuria = "c1", members = { { name = "Gaius", miles = "pp", role = "faber" } }, plan = true, approved = true, plan_required = true })
		w.cohors({ primus_pilus = "pp" })
		check("the primus pilus is denied an edit", denied(w.events_for("pp", "Edit", { file_path = "a.lua" })))
	end)

	test("live shape: a session found in no centuria or contubernium passes untouched", function()
		local w = live_world()
		w.miles("loose")
		check("an unknown post on a loose miles passes an edit", w.events_for("loose", "Edit", { file_path = "a.lua" }) == nil)
		check("and passes a commit", w.events_for("loose", "Bash", { command = "git commit -m x" }) == nil)
	end)

	test("live shape: a centurio's in-repo write is refused and his git status is allowed, a commander codebase refuses the decanus's commit", function()
		local w = live_world()
		w.miles("c-m")
		w.miles("d-m")
		w.centuria("c1", { centurio = "c-m", optio = "other", contubernia = { "t1" } })
		w.contubernium("t1", { centuria = "c1", members = { { name = "Servius", miles = "d-m", role = "decanus" } } })
		check("a centurio's redirect into the repo is denied", denied(w.events_for("c-m", "Bash", { command = "echo hi > notes.md" })))
		check("a centurio's git status is allowed", w.events_for("c-m", "Bash", { command = "git status" }) == nil)
		check("the decanus can commit where no commander flag is set", w.events_for("d-m", "Bash", { command = "git commit -m x" }) == nil)
		w.cohors({ commander_commits = true })
		check("the decanus's commit is denied in a commander codebase", denied(w.events_for("d-m", "Bash", { command = "git commit -m x" })))
	end)
	test("live shape after discharge: the old centurio's edit, the old decanus's commit and the old faber's edit pass", function()
		local w = live_world()
		w.miles("c-m")
		w.miles("d-m")
		w.miles("f-m")
		w.centuria("c1", { centurio = "c-m", optio = "o-m", contubernia = { "t1" } })
		w.contubernium("t1", { centuria = "c1", members = { { name = "Servius", miles = "d-m", role = "decanus" }, { name = "Tiberius", miles = "f-m", role = "faber" } }, plan = true, plan_required = true })
		require(filesystem .. "centuria_repository").new(w.store):remove("c1")
		check("the old centurio may edit once his centuria is gone", w.events_for("c-m", "Edit", { file_path = "a.lua" }) == nil)
		check("the old decanus may commit once his centuria is gone", w.events_for("d-m", "Bash", { command = "git commit -m x" }) == nil)
		check("the old faber may edit once his centuria is gone", w.events_for("f-m", "Edit", { file_path = "a.lua" }) == nil)
	end)

	test("live shape after discharge: a legio no longer deployed lets its old centurio, decanus and faber pass", function()
		local w = live_world()
		w.miles("c-m")
		w.miles("d-m")
		w.miles("f-m")
		w.centuria("c1", { centurio = "c-m", optio = "o-m", contubernia = { "t1" } })
		w.contubernium("t1", { centuria = "c1", members = { { name = "Servius", miles = "d-m", role = "decanus" }, { name = "Tiberius", miles = "f-m", role = "faber" } }, plan = true, plan_required = true })
		require(filesystem .. "legio_repository").new(w.store):update("x-rapax", function(l)
			l.name, l.munus, l.roles, l.expeditio, l.centuria = "Legio X Rapax", "implement", { "faber", "probator", "censor" }, nil, nil
		end)
		check("the old centurio may edit once the legio is discharged", w.events_for("c-m", "Edit", { file_path = "a.lua" }) == nil)
		check("the old decanus may commit once the legio is discharged", w.events_for("d-m", "Bash", { command = "git commit -m x" }) == nil)
		check("the old faber may edit once the legio is discharged", w.events_for("f-m", "Edit", { file_path = "a.lua" }) == nil)
	end)

	test("live shape after discharge: a miles record that still says decanus but whose legio is not deployed passes", function()
		local w = live_world()
		MilesRepository.new(w.store):update("stale", function(a)
			a.name, a.root, a.cwd, a.state, a.title = "stale", "/work/tree", "/work/tree", "idle", "live stale"
			a.legio, a.role = "x-rapax", "decanus"
		end)
		require(filesystem .. "legio_repository").new(w.store):update("x-rapax", function(l)
			l.name, l.munus, l.roles, l.expeditio, l.centuria = "Legio X Rapax", "implement", { "faber", "probator", "censor" }, nil, nil
		end)
		check("a stale decanus record with no deployed legio may commit", w.events_for("stale", "Bash", { command = "git commit -m x" }) == nil)
	end)

	test("live shape: with no deployed legio, nothing is read from centuriae or the contubernia records", function()
		local reads = { centuriae = 0, contubernia_records = 0, cohortes = 0, legiones = 0 }
		local function counted(name)
			return {
				get = function()
					reads[name] = reads[name] + 1
					error(name .. " read with no deployed legio")
				end,
				all = function()
					reads[name] = reads[name] + 1
					error(name .. " read with no deployed legio")
				end,
				of = function()
					reads[name] = reads[name] + 1
					error(name .. " read with no deployed legio")
				end,
			}
		end
		local MilesSessionEvents = require("workspace.legio.application.miles_session_events")
		local events = MilesSessionEvents.new({
			milites = {
				find = function(_, id)
					return { id = id, name = "loose", root = "/work/tree", cwd = "/work/tree", state = "idle" }
				end,
			},
			contubernia = { plan_gate_open = function() return true end },
			legiones = { all = function() reads.legiones = reads.legiones + 1 return {} end },
			centuriae = counted("centuriae"),
			contubernia_records = counted("contubernia_records"),
			cohortes = counted("cohortes"),
			log = function() end,
		})
		local reply = events:post_block({ moment = "before_tool", session_id = "loose", tool_name = "Edit", tool_input = { file_path = "a.lua" }, cwd = "/work/tree" })
		check("a miles with no legio passes", reply == nil, reply)
		check("the legiones were asked which are deployed", reads.legiones == 1, reads)
		check("and nothing was read from centuriae, the contubernia records or the cohortes", reads.centuriae == 0 and reads.contubernia_records == 0 and reads.cohortes == 0, reads)
	end)
	test("primus pilus: a stale leader id on a cohors is not resolved as primus pilus, a genuine one with a role is", function()
		local w = live_world()
		w.centuria("c1", { centurio = "other", optio = "other2", contubernia = { "t1" } })
		w.miles("p-old")
		MilesRepository.new(w.store):update("p-old", function(a)
			a.role = "faber"
		end)
		w.miles("pp-real")
		MilesRepository.new(w.store):update("pp-real", function(a)
			a.role = "primus pilus"
		end)
		w.contubernium("t1", { centuria = "c1", members = { { name = "Gaius", miles = "p-old", role = "faber" }, { name = "Lucius", miles = "pp-real", role = "faber" } }, plan = true, approved = true, plan_required = true })
		w.cohors({ primus_pilus = "p-old" })
		check("a stale leader id, now a faber, is not primus pilus and may edit", w.events_for("p-old", "Edit", { file_path = "a.lua" }) == nil)
		w.cohors({ primus_pilus = "pp-real" })
		check("a genuine primus pilus with his role on the record is denied an edit", denied(w.events_for("pp-real", "Edit", { file_path = "a.lua" })))
	end)


	test("known limit: primus pilus without a role on his record is unguarded until the record carries one", function()
		local w = live_world()
		w.centuria("c1", { centurio = "other", optio = "other2", contubernia = { "t1" } })
		w.miles("pp-live")
		w.contubernium("t1", { centuria = "c1", members = { { name = "Lucius", miles = "pp-live", role = "faber" } }, plan = true, approved = true, plan_required = true })
		w.cohors({ primus_pilus = "pp-live" })
		check("known limit: with no role on his record he resolves as his member role, a faber, and may edit", w.events_for("pp-live", "Edit", { file_path = "a.lua" }) == nil)
	end)

	test("live shape status: a centurio's and a decanus's status show the posts, not 'miles', on records with no role", function()
		local w = live_world()
		w.miles("c-m")
		w.miles("o-m")
		w.miles("d-m")
		w.miles("f-m")
		w.miles("p-m")
		w.miles("s-m")
		w.centuria("c1", { centurio = "c-m", optio = "o-m", contubernia = { "t1" } })
		w.contubernium("t1", { centuria = "c1", members = { { name = "Servius", miles = "d-m", role = "decanus" }, { name = "Tiberius", miles = "f-m", role = "faber" }, { name = "Manius", miles = "p-m", role = "probator" }, { name = "Lucius", miles = "s-m", role = "censor" } }, plan = true, plan_required = true })
		local function posts(rows)
			local out = {}
			for _, row in ipairs(rows or {}) do
				out[row.name] = row.post
			end
			return out
		end
		local function at_depth(rows, depth)
			local out = {}
			for _, row in ipairs(rows or {}) do
				if (row.depth or 0) == depth then
					out[row.name] = row.post
				end
			end
			return out
		end
		local rows = w.services.legio_process:status("c-m")
		local top = at_depth(rows, 0)
		local members = at_depth(rows, 1)
		local optio_row, decanus_row
		for _, row in ipairs(rows or {}) do
			if row.post == "optio" then
				optio_row = row
			end
			if row.post == "decanus" then
				decanus_row = row
			end
		end
		check("the centurio's status shows the optio at the top, by his post", optio_row ~= nil and (optio_row.depth or 0) == 0, rows)
		check("the centurio's status shows the decanus at the top, by his post", decanus_row ~= nil and decanus_row.name == "Servius" and (decanus_row.depth or 0) == 0, rows)
		check("no member is shown at the top of the centurio's status", next(top) == nil or (top.Tiberius == nil and top.Manius == nil and top.Lucius == nil), top)
		check("the members under the decanus are at depth 1 with their posts", members.Tiberius == "faber" and members.Manius == "probator" and members.Lucius == "censor", members)
		check("no status row says 'miles' on these records", (function()
			for _, row in ipairs(rows or {}) do
				if row.post == "miles" then
					return false
				end
			end
			return true
		end)(), rows)
		local under = posts(w.services.legio_process:status("d-m"))
		check("the decanus's status shows faber, probator and censor by their posts", under.Tiberius == "faber" and under.Manius == "probator" and under.Lucius == "censor", under)
	end)
	test("real writers: a miles enlisted by LegioProcess keeps its legio, role and roman name through hook updates, session end and reconcile", function()
		local Legio = require("workspace.legio.domain.legio")
		local root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		local store = t.make_store(root)
		local services = composition_root.build(store, { clock = os.time })
		local milites = MilesRepository.new(store)
		milites:update("m-1", function(a)
			a.state, a.root, a.cwd = "starting", root, root
		end)
		local legio = Legio.raise(Legio.standing[1], 1)
		services.legio_process:enlist(legio, root, { id = "m-1", name = "Servius", post = "decanus", topic = "split the api" })
		local function check_kept(stage)
			local m = milites:find("m-1")
			check(stage .. ": the legio survives", m and m.legio == "x-rapax", m and m.legio)
			check(stage .. ": the role survives", m and m.role == "decanus", m and m.role)
			check(stage .. ": the roman name survives", m and m.roman_name == "Servius", m and m.roman_name)
		end
		check_kept("right after enlisting")
		local events = services.miles_session_events
		events:apply(command("session_event_command").new({ payload = event("start", { session_id = "m-1", cwd = root }), background = true, host = "agentd" }))
		check_kept("after the session starts")
		events:apply(command("session_event_command").new({ payload = event("before_tool", { session_id = "m-1", cwd = root, tool_name = "Bash", tool_input = { command = "echo hi" } }), background = true, host = "agentd" }))
		check_kept("after a hook update")
		events:apply(command("session_event_command").new({ payload = event("end", { session_id = "m-1", cwd = root }), background = true, host = "agentd" }))
		check_kept("after the session ends")
		local registry = {
			needs_reconcile = function()
				return true
			end,
			reconcile = function(_, a)
				return a
			end,
			wait = function()
				return nil
			end,
			untracked = function()
				return {}
			end,
		}
		events.sessions = { list = function() return registry end }
		events:sync_session_files()
		check_kept("after sync_session_files")
		local m = milites:find("m-1")
		check("the title still names the post", m and m.title and m.title:find("decanus", 1, true) ~= nil, m and m.title)
	end)
	test("proposed rule: contubernium ready names the mandatum finished, and only the one it holds makes it idle", function()
		local process, centuria, calls, contubernia, e1 = prune_setup()
		table.insert(e1.mandata, { id = "5319", title = "current", text = "# 5319", state = "open", assignee = "d1" })
		table.insert(e1.mandata, { id = "f0cf", title = "earlier", text = "# f0cf", state = "done" })
		contubernia:update("t1", function(c)
			c.todo, c.earlier, c.stood_by = "5319", { "f0cf" }, nil
		end)
		centuria.waiting = { "m1" }
		local ok, why = process:stand_by("d1", "f0cf")
		check("ready for an earlier mandatum is refused", ok == nil, ok)
		check("the reason names the mandatum it still holds", why ~= nil and why:find("5319", 1, true) ~= nil, why)
		check("stood_by is not set", contubernia:get("t1").stood_by == nil, contubernia:get("t1").stood_by)
		check("nothing is handed out", calls.assigned.m1 == nil, calls.assigned)
		check("the waiting list is untouched", centuria:is_waiting("m1"), centuria.waiting)
		local p3, c3, _, k3, e3 = prune_setup()
		table.insert(e3.mandata, { id = "5319", title = "current", text = "# 5319", state = "open", assignee = "d1" })
		table.insert(e3.mandata, { id = "f0cf", title = "earlier", text = "# f0cf", state = "done" })
		k3:update("t1", function(c)
			c.todo, c.earlier, c.stood_by = "5319", { "f0cf" }, nil
		end)
		c3.waiting = {}
		p3:stand_by("d1", "f0cf")
		check("a refused ready leaves the decanus not stood by, with nothing waiting", k3:get("t1").stood_by == nil, k3:get("t1").stood_by)
		local ok2 = process:stand_by("d1", "5319")
		check("ready for the current todo is accepted", ok2 == true, ok2)
		check("the contubernium then takes the waiting mandatum", calls.assigned.m1 == "d1", calls.assigned)
	end)

	test("proposed rule: contubernium ready with no id declares the current todo finished", function()
		local process, centuria, calls, contubernia, e1 = prune_setup()
		table.insert(e1.mandata, { id = "5319", title = "current", text = "# 5319", state = "open", assignee = "d1" })
		contubernia:update("t1", function(c)
			c.todo, c.stood_by = "5319", nil
		end)
		centuria.waiting = { "m1" }
		local ok = process:stand_by("d1")
		check("ready with no id stands the decanus by on his current todo", ok == true, ok)
		check("and the waiting mandatum goes to him", calls.assigned.m1 == "d1", calls.assigned)
	end)

	test("proposed rule: the CLI passes the mandatum id to ready, and a wrong id is reported", function()
		local cli = require("workspace.legio.infrastructure.inbound.contubernium_cli")
		local Contubernium = require("workspace.legio.domain.contubernium")
		local nvim = require("workspace.shared.adapters.nvim")
		local composition_root = require("workspace.composition_root")
		local provider = require("workspace.shared.providers").current()
		local saved = { session = provider.current_session, store = nvim.new_store, logger = nvim.logger, build = composition_root.build }
		local decanus = Contubernium:new({ id = "t1", members = { { name = "Servius", miles = "d1", role = "decanus" } } })
		local got = {}
		local refuse
		provider.current_session = function()
			return "d1"
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
						return miles == "d1" and decanus or nil
					end,
				},
				legio_process = {
					stand_by = function(_, miles, mandatum)
						table.insert(got, { miles = miles, mandatum = mandatum })
						if refuse then
							return nil, "contubernium still holds 5319, not " .. tostring(mandatum)
						end
						return true
					end,
				},
			}
		end
		local out = io.tmpfile()
		local saved_out = io.output()
		io.output(out)
		local code1 = cli.run({ "ready", "f0cf" })
		refuse = true
		local code2 = cli.run({ "ready", "f0cf" })
		io.output(saved_out)
		out:close()
		provider.current_session, nvim.new_store, nvim.logger, composition_root.build = saved.session, saved.store, saved.logger, saved.build
		check("ready with an id passes the id to the service", got[1] ~= nil and got[1].mandatum == "f0cf", got)
		check("and succeeds when the service accepts it", code1 == 0, code1)
		check("a wrong id is reported and fails", code2 == 1, code2)
	end)
	local function real_writer_case(post, roman, miles_id)
		local Legio = require("workspace.legio.domain.legio")
		local root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		local store = t.make_store(root)
		local services = composition_root.build(store, { clock = os.time })
		local milites = MilesRepository.new(store)
		milites:update(miles_id, function(a)
			a.state, a.root, a.cwd = "starting", root, root
		end)
		local legio = Legio.raise(Legio.standing[1], 1)
		services.legio_process:enlist(legio, root, { id = miles_id, name = roman, post = post, topic = "split the api" })
		local function kept(stage)
			local m = milites:find(miles_id)
			check(post .. " " .. stage .. ": the legio survives", m and m.legio == "x-rapax", m and m.legio)
			check(post .. " " .. stage .. ": the role survives", m and m.role == post, m and m.role)
			check(post .. " " .. stage .. ": the roman name survives", m and m.roman_name == roman, m and m.roman_name)
		end
		kept("right after enlisting")
		local events = services.miles_session_events
		events:apply(command("session_event_command").new({ payload = event("start", { session_id = miles_id, cwd = root }), background = true, host = "agentd" }))
		kept("after the session starts")
		events:apply(command("session_event_command").new({ payload = event("before_tool", { session_id = miles_id, cwd = root, tool_name = "Bash", tool_input = { command = "echo hi" } }), background = true, host = "agentd" }))
		kept("after a hook update")
		events:apply(command("session_event_command").new({ payload = event("end", { session_id = miles_id, cwd = root }), background = true, host = "agentd" }))
		kept("after the session ends")
		local registry = {
			needs_reconcile = function()
				return true
			end,
			reconcile = function(_, a)
				return a
			end,
			wait = function()
				return nil
			end,
			untracked = function()
				return {}
			end,
		}
		events:reconcile(registry, milites:find(miles_id), os.time(), {})
		kept("after reconcile")
		events.sessions = { list = function() return registry end }
		events:sync_session_files()
		kept("after sync_session_files")
	end

	local writer_posts = {
		{ "centurio", "Servius", "w-centurio" },
		{ "optio", "Titus", "w-optio" },
		{ "decanus", "Tiberius", "w-decanus" },
		{ "faber", "Marcus", "w-faber" },
		{ "probator", "Manius", "w-probator" },
		{ "censor", "Lucius", "w-censor" },
		{ "primus pilus", "Gaius", "w-primus" },
	}
	for _, case in ipairs(writer_posts) do
		test("real writers: a " .. case[1] .. " enlisted through the deploy path keeps his legio, role and roman name through hook updates, session end and reconcile", function()
			real_writer_case(case[1], case[2], case[3])
		end)
	end
	test("real writers through the deploy path: every post keeps its legio, role and roman name in the stored record and through the session events", function()
		local DeployLegioCommand = require("workspace.legio.application.commands.deploy_legio_command")
		local root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		local store = t.make_store(root)
		local services = composition_root.build(store, { clock = os.time })
		local lp = services.legio_process
		local started, n = {}, 0
		local expeditio = { id = "e1", title = "agentd sdk", root = "/p", mandata = { { id = "m1", title = "split", text = "# split", state = "open" } } }
		lp.runner = {
			new_miles_id = function()
				n = n + 1
				return ("dm-%02d"):format(n)
			end,
			start = function(_, command, done)
				table.insert(started, command)
				done(true, "short")
			end,
			hold_text = function() end,
			stop = function(_, _, done)
				if done then
					done(true)
				end
			end,
		}
		lp.git = { locate = function() return { branch = "main" } end }
		lp.todos = { assign = function() return true end, send = function() end, release = function() end, done_command = "todo", text = function() return "# text" end }
		lp.expeditiones = { get = function(id) return id == "e1" and expeditio or nil end, of = function(mid) for _, m in ipairs(expeditio.mandata) do if m.id == mid then return expeditio end end end }
		local seed = 0
		lp.random = function(a, b)
			seed = seed + 1
			return a + seed % (b - a + 1)
		end
		lp:raise_legiones()
		local deployed
		lp:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function(ok, r)
			deployed = { ok = ok, r = r }
		end)
		check("the legio deploys through the real process", deployed and deployed.ok, deployed)
		local milites = MilesRepository.new(store)
		local by_role = {}
		for _, m in ipairs(milites:plain_all()) do
			if m.legio == "x-rapax" and m.role then
				by_role[m.role] = m
			end
		end
		local events = services.miles_session_events
		local registry = {
			needs_reconcile = function()
				return true
			end,
			reconcile = function(_, a)
				return a
			end,
			wait = function()
				return nil
			end,
			untracked = function()
				return {}
			end,
		}
		for _, post in ipairs({ "centurio", "optio", "decanus", "faber", "probator", "censor", "primus pilus" }) do
			local m = by_role[post]
			check(post .. " is enlisted through the deploy path with a stored record", m ~= nil, by_role)
			if m then
				local id, roman = m.id, m.roman_name
				check(post .. " keeps the legio in the stored record", m.legio == "x-rapax", m.legio)
				check(post .. " keeps the role in the stored record", m.role == post, m.role)
				check(post .. " keeps a roman name in the stored record", roman ~= nil and roman ~= "", roman)
				events:apply(command("session_event_command").new({ payload = event("start", { session_id = id, cwd = root }), background = true, host = "agentd" }))
				events:apply(command("session_event_command").new({ payload = event("before_tool", { session_id = id, cwd = root, tool_name = "Bash", tool_input = { command = "echo hi" } }), background = true, host = "agentd" }))
				events:apply(command("session_event_command").new({ payload = event("end", { session_id = id, cwd = root }), background = true, host = "agentd" }))
				events:reconcile(registry, milites:find(id), os.time(), {})
				events.sessions = { list = function() return registry end }
				events:sync_session_files()
				local after = milites:find(id)
				check(post .. " keeps legio, role and roman name after hook updates, session end, reconcile and sync", after and after.legio == "x-rapax" and after.role == post and after.roman_name == roman, after and { after.legio, after.role, after.roman_name })
			end
		end
	end)
	test("real deploy path: the primus pilus deploy creates keeps legio, role 'primus pilus' and roman name, and the cohors leads on the stored record", function()
		local DeployLegioCommand = require("workspace.legio.application.commands.deploy_legio_command")
		local Cohors = require("workspace.legio.domain.cohors")
		local root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		local store = t.make_store(root)
		local services = composition_root.build(store, { clock = os.time })
		local lp = services.legio_process
		local n = 0
		local expeditio = { id = "e1", title = "agentd sdk", root = "/p", mandata = { { id = "m1", title = "split", text = "# split", state = "open" } } }
		lp.runner = {
			new_miles_id = function()
				n = n + 1
				return ("pp-%02d"):format(n)
			end,
			start = function(_, _, done)
				done(true, "short")
			end,
			hold_text = function() end,
			stop = function(_, _, done)
				if done then
					done(true)
				end
			end,
		}
		lp.git = { locate = function() return { branch = "main" } end }
		lp.todos = { assign = function() return true end, send = function() end, release = function() end, done_command = "todo", text = function() return "# text" end }
		lp.expeditiones = { get = function(id) return id == "e1" and expeditio or nil end, of = function(mid) for _, m in ipairs(expeditio.mandata) do if m.id == mid then return expeditio end end end }
		local seed = 0
		lp.random = function(a, b)
			seed = seed + 1
			return a + seed % (b - a + 1)
		end
		lp:raise_legiones()
		local deployed
		lp:deploy(DeployLegioCommand.new({ legio_id = "x-rapax", expeditio_id = "e1" }), function(ok, r)
			deployed = { ok = ok, r = r }
		end)
		check("the legio deploys through the real process", deployed and deployed.ok, deployed)
		local milites = MilesRepository.new(store)
		local pp
		for _, m in ipairs(milites:plain_all()) do
			if m.role == "primus pilus" then
				pp = m
			end
		end
		check("the deploy enlists a primus pilus with role 'primus pilus'", pp ~= nil, pp)
		if not pp then
			return
		end
		local id, roman = pp.id, pp.roman_name
		check("the stored primus pilus keeps the legio", pp.legio == "x-rapax", pp.legio)
		check("the stored primus pilus has a roman name", roman ~= nil and roman ~= "", roman)
		local cohors = require(filesystem .. "cohors_repository").new(store):get(Cohors.key("/p"))
		check("the cohors names him as primus pilus", cohors ~= nil and cohors.primus_pilus == id, cohors and cohors.primus_pilus)
		check("cohors:is_led_by is true on the stored record", cohors ~= nil and cohors:is_led_by(milites:find(id)), milites:find(id))
		local events = services.miles_session_events
		events:apply(command("session_event_command").new({ payload = event("before_tool", { session_id = id, cwd = root, tool_name = "Bash", tool_input = { command = "echo hi" } }), background = true, host = "agentd" }))
		events:apply(command("session_event_command").new({ payload = event("end", { session_id = id, cwd = root }), background = true, host = "agentd" }))
		local registry = {
			needs_reconcile = function()
				return true
			end,
			reconcile = function(_, a)
				return a
			end,
			wait = function()
				return nil
			end,
			untracked = function()
				return {}
			end,
		}
		events:reconcile(registry, milites:find(id), os.time(), {})
		local after = milites:find(id)
		check("after a hook update, end and reconcile he keeps legio, role and roman name", after and after.legio == "x-rapax" and after.role == "primus pilus" and after.roman_name == roman, after and { after.legio, after.role, after.roman_name })
		local cohors_after = require(filesystem .. "cohors_repository").new(store):get(Cohors.key("/p"))
		check("and the cohors still leads on the stored record", cohors_after ~= nil and cohors_after:is_led_by(after), cohors_after and cohors_after.primus_pilus)
	end)
	test("proposed rule: ready on a contubernium with no current todo says it holds no mandatum, never nil", function()
		local process, centuria, calls, contubernia = prune_setup()
		contubernia:update("t1", function(c)
			c.todo, c.stood_by = nil, nil
		end)
		centuria.waiting = { "m1" }
		local ok, why = process:stand_by("d1", "5319")
		check("ready with no held mandatum is refused", ok == nil, ok)
		check("the reason says the contubernium holds no mandatum", why ~= nil and why:find("holds no mandatum", 1, true) ~= nil, why)
		check("the reason never says nil", why ~= nil and why:find("nil", 1, true) == nil, why)
		check("nothing is handed out", calls.assigned.m1 == nil, calls.assigned)
	end)
end

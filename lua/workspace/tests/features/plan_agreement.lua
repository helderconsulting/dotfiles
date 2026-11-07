local Miles = require("workspace.legio.domain.miles")
local Centuria = require("workspace.legio.domain.centuria")
local Contubernium = require("workspace.legio.domain.contubernium")
local LegioProcess = require("workspace.legio.application.legio_process")
local filesystem = "workspace.legio.infrastructure.outbound.filesystem."
local contubernium_record_mapper = require(filesystem .. "contubernium_record_mapper")

return function(t)
	local test, check = t.test, t.check

	local function has(value, needle)
		return vim.inspect(value):find(needle, 1, true) ~= nil
	end

	local function setup(o)
		local store = t.make_store(vim.fn.tempname())
		local milites = require(filesystem .. "miles_repository").new(store)
		local contubernia = require(filesystem .. "contubernium_repository").new(store)
		local centuriae = require(filesystem .. "centuria_repository").new(store)
		store:update(Miles, "o1", function(a)
			a.legio, a.role, a.state, a.cwd, a.root, a.title = "x-rapax", "optio", "working", "/p", "/p", "Titus"
		end)
		store:update(Miles, "d1", function(a)
			a.legio, a.role, a.state, a.cwd, a.root, a.title = "x-rapax", "decanus", "working", "/p", "/p", "Quintus"
		end)
		store:update(Miles, "d2", function(a)
			a.legio, a.role, a.state, a.cwd, a.root, a.title = "x-rapax", "decanus", "working", "/p", "/p", "Publius"
		end)
		store:update(Miles, "m1", function(a)
			a.legio, a.role, a.state, a.cwd, a.root, a.title = "x-rapax", "faber", "working", "/p", "/p", "Gaius"
		end)
		if o and o.third then
			store:update(Miles, "d3", function(a)
				a.legio, a.role, a.state, a.cwd, a.root, a.title = "x-rapax", "decanus", "working", "/p", "/p", "Servius"
			end)
			contubernia:save(Contubernium.enlist({ id = "t3", name = "wolf", todo = "ef56", root = "/p", base = "main", centuria = "c1", created = 1, members = { { name = "Servius", miles = "d3", role = "decanus" } } }))
		end
		centuriae:save(Centuria.make({ id = "c1", legio = "x-rapax", root = "/p", centurio = "o1", optio = "o1", contubernia = o and o.third and { "t1", "t2", "t3" } or { "t1", "t2" }, created = 1 }))
		contubernia:save(Contubernium.enlist({ id = "t1", name = "otter", todo = "ab12", root = "/p", base = "main", centuria = "c1", created = 1, members = { { name = "Quintus", miles = "d1", role = "decanus" }, { name = "Gaius", miles = "m1", role = "faber" } } }))
		contubernia:save(Contubernium.enlist({ id = "t2", name = "heron", todo = "cd34", root = "/p", base = "main", centuria = "c1", created = 1, members = { { name = "Publius", miles = "d2", role = "decanus" } } }))
		local calls = { held = {} }
		local runner = {
			new_miles_id = function()
				return "x"
			end,
			start = function(_, _, done)
				done(true, "short")
			end,
			hold_text = function(_, id, text)
				table.insert(calls.held, { id = id, text = text })
			end,
			stop = function(_, _, done)
				if done then
					done(true)
				end
			end,
		}
		local service = LegioProcess.new({
			legiones = require(filesystem .. "legio_repository").new(store),
			cohortes = require(filesystem .. "cohors_repository").new(store),
			centuriae = centuriae,
			contubernia = contubernia,
			milites = milites,
			runner = runner,
			git = { locate = function() return { branch = "main" } end },
			todos = { done_command = "todo" },
			expeditiones = { get = function() return nil end },
			clock = function()
				return 100
			end,
			random = math.random,
		})
		return service, calls, contubernia
	end

	local function held_by(calls, id)
		local out = {}
		for _, h in ipairs(calls.held) do
			if h.id == id then
				table.insert(out, h.text)
			end
		end
		return out
	end

	test("the optio sees the other decani's plans when a plan is submitted", function()
		local service, calls = setup()
		check("the other decanus submits first", service:submit_plan({ from = "d2", text = "publius plan: the bridge" }) == true)
		check("the decanus submits his plan", service:submit_plan({ from = "d1", text = "quintus plan: the api" }) == true)
		local to_optio = held_by(calls, "o1")
		check("the optio gets the submitted plan", has(to_optio, "quintus plan: the api"), to_optio)
		check("the optio also sees the other decanus's plan", has(to_optio, "publius plan: the bridge"), to_optio)
	end)

	test("aligning shared parts writes them into the named contubernium's plan", function()
		local service, calls, contubernia = setup()
		service:submit_plan({ from = "d1", text = "quintus plan: the api" })
		service:submit_plan({ from = "d2", text = "publius plan: the bridge" })
		local aligned, align_err = service:align_plan({ from = "o1", to = "Quintus", text = "contract: api.lua" })
		check("the optio aligns one decanus", aligned ~= nil and align_err == nil, align_err)
		check("it names the decanus told", aligned ~= nil and has(aligned, "Quintus") and not has(aligned, "Publius"), aligned)
		local t1 = contubernia:all()
		local one, two
		for _, c in ipairs(t1) do
			if c.id == "t1" then
				one = c
			elseif c.id == "t2" then
				two = c
			end
		end
		check("the named contubernium gets the shared part", one ~= nil and has(one.plan.shared, "contract: api.lua"), one and one.plan)
		check("the other contubernium does not", two ~= nil and not has(two.plan and two.plan.shared, "contract: api.lua"), two and two.plan)
		check("the decanus is told", has(held_by(calls, "d1"), "contract: api.lua"), held_by(calls, "d1"))
	end)

	test("aligning all decani reaches every contubernium", function()
		local service, calls, contubernia = setup()
		service:submit_plan({ from = "d1", text = "quintus plan: the api" })
		service:submit_plan({ from = "d2", text = "publius plan: the bridge" })
		local aligned, align_err = service:align_plan({ from = "o1", to = "all", text = "contract: api.lua" })
		check("the optio aligns all", aligned ~= nil and align_err == nil, align_err)
		check("it names both decani told", aligned ~= nil and has(aligned, "Quintus") and has(aligned, "Publius"), aligned)
		for _, c in ipairs(contubernia:all()) do
			check("contubernium " .. c.id .. " gets the shared part", c.plan ~= nil and has(c.plan.shared, "contract: api.lua"), c.plan)
		end
		check("the second decanus is told", has(held_by(calls, "d2"), "contract: api.lua"), held_by(calls, "d2"))
	end)

	test("a decanus cannot hand out a plan the optio has not approved", function()
		local service = setup()
		service:submit_plan({ from = "d1", text = "quintus plan: the api" })
		local names, err = service:hand_out_plan({ from = "d1" })
		check("the handout is refused", names == nil and err ~= nil, { names = names, err = err })
	end)

	test("an approved plan goes to each member with his role, the plan and the shared parts", function()
		local service, calls = setup()
		service:submit_plan({ from = "d1", text = "quintus plan: the api" })
		service:approve_plan({ from = "o1", name = "Quintus" })
		service:align_plan({ from = "o1", to = "all", text = "contract: api.lua" })
		local names, err = service:hand_out_plan({ from = "d1" })
		check("the handout goes out", names ~= nil and err == nil, err)
		check("it names the milites sent to", names ~= nil and has(names, "Gaius") and not has(names, "Quintus"), names)
		local to_gaius = held_by(calls, "m1")
		check("the member gets his role", has(to_gaius, "faber"), to_gaius)
		check("the member gets the full plan", has(to_gaius, "quintus plan: the api"), to_gaius)
		check("the member gets the shared parts", has(to_gaius, "contract: api.lua"), to_gaius)
		local handouts = 0
		for _, text in ipairs(held_by(calls, "d1")) do
			if text:find("Your role:", 1, true) then
				handouts = handouts + 1
			end
		end
		check("the decanus is not sent his own handout", handouts == 0, held_by(calls, "d1"))
	end)

	test("only the optio aligns, and only known decani are named", function()
		local service = setup()
		service:submit_plan({ from = "d1", text = "quintus plan: the api" })
		local by_decanus, err1 = service:align_plan({ from = "d1", to = "all", text = "x" })
		check("a decanus can't align", by_decanus == nil and err1 ~= nil, err1)
		local by_faber, err2 = service:align_plan({ from = "m1", to = "all", text = "x" })
		check("a faber can't align", by_faber == nil and err2 ~= nil, err2)
		local unknown, err3 = service:align_plan({ from = "o1", to = "Nobody", text = "x" })
		check("an unknown decanus is refused", unknown == nil and err3 ~= nil, err3)
	end)

	test("the plan's shared parts survive the contubernium record", function()
		local plan = { text = "quintus plan: the api", at = 1, shared = { { text = "contract: api.lua", by = "o1", at = 1 } } }
		local t = Contubernium.enlist({ id = "t1", root = "/p", base = "main", created = 1, plan = plan, members = {} })
		local back = contubernium_record_mapper.to_domain(contubernium_record_mapper.to_record(t))
		check("the shared parts round-trip", back.plan ~= nil and has(back.plan.shared, "contract: api.lua"), back.plan)
	end)

	test("resubmitting a plan keeps the shared parts already agreed", function()
		local service, _, contubernia = setup()
		service:submit_plan({ from = "d1", text = "quintus plan: the api" })
		service:align_plan({ from = "o1", to = "Quintus", text = "contract: api.lua" })
		service:submit_plan({ from = "d1", text = "quintus plan v2: the api" })
		local one
		for _, c in ipairs(contubernia:all()) do
			if c.id == "t1" then
				one = c
			end
		end
		check("the new text is in", one ~= nil and one.plan.text == "quintus plan v2: the api", one and one.plan)
		check("the agreed shared part is kept", one ~= nil and has(one.plan.shared, "contract: api.lua"), one and one.plan)
	end)

	test("a comma list of decani reaches exactly those decani", function()
		local service, calls = setup({ third = true })
		service:submit_plan({ from = "d1", text = "quintus plan: the api" })
		service:submit_plan({ from = "d2", text = "publius plan: the bridge" })
		service:submit_plan({ from = "d3", text = "servius plan: the docs" })
		local names, err = service:align_plan({ from = "o1", to = "Quintus,Publius", text = "contract: shared two" })
		check("the list is accepted", names ~= nil and err == nil, err)
		check("it names the two decani", names ~= nil and has(names, "Quintus") and has(names, "Publius") and not has(names, "Servius"), names)
		check("the third decanus is not told", #held_by(calls, "d3") == 0 or not has(held_by(calls, "d3"), "contract: shared two"), held_by(calls, "d3"))
		check("the first decanus is told", has(held_by(calls, "d1"), "contract: shared two"), held_by(calls, "d1"))
	end)

	test("a second handout is refused until the plan is resubmitted", function()
		local service, _, contubernia = setup()
		service:submit_plan({ from = "d1", text = "quintus plan: the api" })
		service:approve_plan({ from = "o1", name = "Quintus" })
		check("the first handout goes out", service:hand_out_plan({ from = "d1" }) ~= nil)
		local one
		for _, c in ipairs(contubernia:all()) do
			if c.id == "t1" then
				one = c
			end
		end
		check("the handout is stamped", one ~= nil and one.plan.handed_out_at ~= nil, one and one.plan)
		local names, err = service:hand_out_plan({ from = "d1" })
		check("the second handout is refused", names == nil and err ~= nil and has(err, "already handed out"), { names = names, err = err })
	end)

	test("resubmitting a plan re-enables the handout", function()
		local service = setup()
		service:submit_plan({ from = "d1", text = "quintus plan: the api" })
		service:approve_plan({ from = "o1", name = "Quintus" })
		service:hand_out_plan({ from = "d1" })
		service:submit_plan({ from = "d1", text = "quintus plan v2: the api" })
		service:approve_plan({ from = "o1", name = "Quintus" })
		local names, err = service:hand_out_plan({ from = "d1" })
		check("the new plan goes out", names ~= nil and err == nil, err)
	end)

	test("an alignment after the handout still reaches the members", function()
		local service, calls = setup()
		service:submit_plan({ from = "d1", text = "quintus plan: the api" })
		service:approve_plan({ from = "o1", name = "Quintus" })
		service:hand_out_plan({ from = "d1" })
		service:align_plan({ from = "o1", to = "Quintus", text = "late contract" })
		check("the member hears the late contract", has(held_by(calls, "m1"), "late contract"), held_by(calls, "m1"))
	end)

	test("the handout stamp survives the contubernium record", function()
		local plan = { text = "quintus plan: the api", at = 1, handed_out_at = 9, shared = { { text = "contract: api.lua", by = "o1", at = 2 } } }
		local t = Contubernium.enlist({ id = "t1", root = "/p", base = "main", created = 1, plan = plan, members = {} })
		local back = contubernium_record_mapper.to_domain(contubernium_record_mapper.to_record(t))
		check("the handout time round-trips", back.plan ~= nil and back.plan.handed_out_at == 9, back.plan)
	end)

	test("an unknown name in a comma list refuses the whole alignment", function()
		local service, calls, contubernia = setup()
		service:submit_plan({ from = "d1", text = "quintus plan: the api" })
		local names, err = service:align_plan({ from = "o1", to = "Quintus,Nobody", text = "contract: partial" })
		check("the call is refused", names == nil and err ~= nil, { names = names, err = err })
		check("the refusal names the unknown decanus", err ~= nil and has(err, "no decanus Nobody in your centuria"), err)
		local one
		for _, c in ipairs(contubernia:all()) do
			if c.id == "t1" then
				one = c
			end
		end
		check("nothing is aligned into the known decanus's plan", one ~= nil and not has(one.plan.shared, "contract: partial"), one and one.plan)
		check("the known decanus is not told", not has(held_by(calls, "d1"), "contract: partial"), held_by(calls, "d1"))
		local all_names, all_err = service:align_plan({ from = "o1", to = "all", text = "contract: whole" })
		check("aligning all still works", all_names ~= nil and all_err == nil and has(all_names, "Quintus"), all_err)
	end)

	test("a planless decanus in a comma list is skipped and named", function()
		local service, calls = setup()
		service:submit_plan({ from = "d1", text = "quintus plan: the api" })
		local names, skipped = service:align_plan({ from = "o1", to = "Quintus,Publius", text = "contract: half" })
		check("the planned decanus is aligned", names ~= nil and has(names, "Quintus") and not has(names, "Publius"), names)
		check("the planless one is reported skipped", skipped ~= nil and has(skipped, "Publius") and not has(skipped, "Quintus"), skipped)
		check("the planned decanus is told", has(held_by(calls, "d1"), "contract: half"), held_by(calls, "d1"))
	end)

	test("a list with no names is refused, a stray comma is not", function()
		local service = setup()
		service:submit_plan({ from = "d1", text = "quintus plan: the api" })
		local bare, bare_err = service:align_plan({ from = "o1", to = ",", text = "x" })
		check("a bare comma is refused", bare == nil and bare_err ~= nil and has(bare_err, "name at least one decanus, or all"), bare_err)
		local blanks, blanks_err = service:align_plan({ from = "o1", to = ", ,", text = "x" })
		check("blank entries only are refused", blanks == nil and blanks_err ~= nil and has(blanks_err, "name at least one decanus, or all"), blanks_err)
		local trailing, trailing_err = service:align_plan({ from = "o1", to = "Quintus,", text = "trail" })
		check("a stray trailing comma still aligns the name", trailing ~= nil and trailing_err == nil and has(trailing, "Quintus"), trailing_err)
	end)
end

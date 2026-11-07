local app = require("workspace.workbench.presentation.nvim.app")
local board = require("workspace.workbench.presentation.nvim.board")
local legio_panel = require("workspace.legio.presentation.nvim.legio_panel")
local miles_panel = require("workspace.legio.presentation.nvim.miles_panel")
local legio_mapper = require("workspace.legio.presentation.mappers.legio_view_mapper")

local miles_cards = require("workspace.legio.presentation.mappers.miles_view_mapper")

-- the app tables the legio modules read, found through their upvalues: a module keeps the app it loaded with,
-- and a harness that swaps package.loaded for a while can leave a module holding another one
local function app_tables(functions)
	local found, seen = { app }, { [app] = true }
	local function walk(fn, depth)
		if depth > 3 then
			return
		end
		for i = 1, 80 do
			local name, value = debug.getupvalue(fn, i)
			if not name then
				break
			end
			if name == "app" and type(value) == "table" and not seen[value] then
				seen[value] = true
				table.insert(found, value)
			elseif type(value) == "function" then
				walk(value, depth + 1)
			end
		end
	end
	for _, fn in ipairs(functions) do
		walk(fn, 0)
	end
	return found
end

-- points every app the modules read at services for the duration of a call; returns the restore
-- loaded when first used, not at file load: loading review_marks needs the app the tests have just put in place
local function review_counts()
	-- review_marks subscribes to app events when it loads; a harness may have left a table without 'on' in place
	local current = package.loaded["workspace.workbench.presentation.nvim.app"] or require("workspace.workbench.presentation.nvim.app")
	if current.on == nil then
		current.on = function() end
	end
	return require("workspace.workflow.presentation.nvim.review_marks").counts
end

local function swap_services(functions, services)
	local saved = {}
	for _, t in ipairs(app_tables(functions)) do
		saved[t] = { services = t.services, on = t.on }
		t.services = services
		t.on = function() end
	end
	return function()
		for t, v in pairs(saved) do
			t.services, t.on = v.services, v.on
		end
	end
end

local HIERARCHY_FUNCTIONS = function()
	return {
		legio_panel.entries_on_refresh,
		legio_panel.card_on_render,
		miles_panel.dto,
		miles_panel.live_row,
		miles_panel.card_lines,
		review_counts(),
		miles_panel.thread_on_select,
		miles_panel.open_on_enter,
		miles_panel.show_conversation_on_select,
	}
end

local MANDATUM = "Split the api into two layers"
local function mandatum_of(unit)
	if unit.kind == "contubernium" then
		return MANDATUM
	end
end

-- a post carries the miles fields too, so the same record can be mapped as a live miles dto
local function post(name, role, rank, state)
	return {
		id = name:lower(),
		miles_id = name:lower(),
		name = name,
		post = role,
		role = role,
		rank = rank,
		standing = { rank = rank, level = 1, done = 0, needed = 3, unit = "mandata" },
		state = state,
		tone = state == "working" and "busy" or "off",
		running = state ~= "starting",
		busy = state == "working",
		root = "/p",
		legio = "x",
		context_fraction = 0.4,
		model_label = "opus",
		mode_label = "ask",
	}
end

local function fixture()
	return {
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
end

-- every string anywhere inside a value, so the test does not depend on how a view model nests its rows
local function texts(value, out)
	out = out or {}
	if type(value) == "string" then
		table.insert(out, value)
	elseif type(value) == "table" then
		for _, v in pairs(value) do
			texts(v, out)
		end
	end
	return out
end

local function contains(list, needle)
	for _, s in ipairs(list) do
		if s:find(needle, 1, true) then
			return true
		end
	end
	return false
end

-- runs the real legio panel refresh against a fake service holding one legio, and returns what it hands the sidebar
local function refresh(legio)
	local fake = {
		raise_legiones = function() end,
		revive_waiting = function() end,
		credit_finished = function() end,
		legiones = function()
			return { legio }
		end,
	}
	local restore = swap_services(HIERARCHY_FUNCTIONS(), function()
		return { legio_process = fake }
	end)
	local entries
	local ok, err = pcall(legio_panel.entries_on_refresh, nil, function(list)
		entries = list
	end)
	restore()
	assert(ok, err)
	return entries or {}
end

return function(t)
	local test, check = t.test, t.check

	test("a deployed legio shows its centurio, optio and each contubernium with its milites on the main entries", function()
		local entries = refresh(fixture())
		check("the deployed legio leads its hierarchy", entries[1] and entries[1].id == "legio:x" and #entries > 1, #entries)
		local all = texts(entries)
		check("the centurio is on the main entry", contains(all, "Marcus"), all)
		check("the optio is on the main entry", contains(all, "Gaius"), all)
		check("the contubernium's decanus is on the main entry", contains(all, "Lucius"), all)
		check("the contubernium's miles are on the main entry", contains(all, "Quintus") and contains(all, "Aulus"), all)
	end)

	test("entering a legio opens no sublayout", function()
		local entries = refresh(fixture())
		check("entries were produced", #entries > 1)
		local thread = board.thread_on_select(entries[1], { log = {} })
		check("the legio entry opens no thread", thread == nil, thread)
	end)

	test("the sidebar section is no longer named agents", function()
		local here = vim.fs.abspath(debug.getinfo(1, "S").source:sub(2))
		local lua_dir = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here))))
		local path = lua_dir .. "/workspace/workbench/presentation/nvim/sidebar.lua"
		local file = io.open(path, "r")
		check("the sidebar source can be read", file ~= nil, path)
		if file then
			local source = file:read("*a")
			file:close()
			check("no section is named agents", not source:find('name = "agents"', 1, true), path)
		end
	end)

	local function action(desc)
		for _, a in ipairs(board.actions) do
			if a[3] == desc then
				return a
			end
		end
	end

	-- collects every vim.notify call as { message, level } while fn runs
	local function notes_during(fn)
		local notes = {}
		local original = vim.notify
		vim.notify = function(msg, level)
			table.insert(notes, { msg, level })
		end
		local ok, err = pcall(fn)
		vim.notify = original
		assert(ok, err)
		return notes
	end

	local function warnings(notes)
		local out = {}
		for _, n in ipairs(notes) do
			if n[2] == vim.log.levels.WARN then
				table.insert(out, n[1])
			end
		end
		return out
	end

	test("a miles hierarchy line run through a miles action acts as that miles and does not warn", function()
		local line
		for _, l in ipairs(legio_mapper.to_legion_thread(fixture()).items) do
			if l.miles_id == "quintus" then
				line = l
			end
		end
		check("the hierarchy has Quintus's line", line ~= nil)
		if not line then
			return
		end
		line.name = "Quintus"
		local interrupted = {}
		local services = function()
			return {
				roster = { get = function() return nil end },
				miles_runner = {
					interrupt = function(_, id)
						table.insert(interrupted, id)
					end,
				},
			}
		end
		local a = action("interrupt a miles")
		check("interrupt a miles is an action", a ~= nil)
		local notes
		local functions = HIERARCHY_FUNCTIONS()
		table.insert(functions, 1, a[2])
		local restore = swap_services(functions, services)
		local ok, err = pcall(function()
			notes = notes_during(function()
				a[2](line, { batch = false, confirm = function() return true end }, nil)
			end)
		end)
		restore()
		check("the action runs without an error", ok, err)
		check("no warning for a miles line", #warnings(notes or {}) == 0, warnings(notes or {}))
		check("the miles handler gets the miles id, not the line id", interrupted[1] == "quintus", interrupted)
	end)

	test("a legio key on a miles line still guards and does not run", function()
		local line
		for _, l in ipairs(legio_mapper.to_legion_thread(fixture()).items) do
			if l.miles_id == "quintus" then
				line = l
			end
		end
		if not line then
			return check("the hierarchy has Quintus's line", false)
		end
		line.name = "Quintus"
		local expeditio_panel = require("workspace.workflow.presentation.nvim.expeditio_panel")
		local deployed = {}
		local original_deploy = legio_panel.deploy_on
		legio_panel.deploy_on = function(epic)
			table.insert(deployed, epic)
		end
		local a = action("deploy a legio")
		local notes, ok, err = {}, nil, nil
		if a then
			ok, err = pcall(function()
				notes = notes_during(function()
					a[2](line, { batch = false, confirm = function() return true end }, nil)
				end)
			end)
		end
		legio_panel.deploy_on = original_deploy
		check("deploy a legio is an action", a ~= nil)
		check("the guard runs without crashing on a miles line", ok ~= false, err)
		check("the guard warns on a miles line", #warnings(notes) == 1, warnings(notes))
		check("nothing is deployed from a miles line", #deployed == 0, deployed)
		check("expeditio panel still owns deploy", expeditio_panel.actions ~= nil)
	end)

	test("the deploy action on an expeditio row still deploys its legio", function()
		local a = action("deploy a legio")
		check("deploy a legio is an action", a ~= nil)
		if not a then
			return
		end
		local deployed = {}
		local original_deploy = legio_panel.deploy_on
		legio_panel.deploy_on = function(epic)
			table.insert(deployed, epic)
		end
		local epic = { component = require("workspace.workflow.presentation.nvim.expeditio_panel"), expeditio = "e1", name = "agentd sdk" }
		local notes = notes_during(function()
			a[2](epic, { batch = false, confirm = function() return true end }, nil)
		end)
		legio_panel.deploy_on = original_deploy
		check("no warning on an expeditio row", #warnings(notes) == 0, warnings(notes))
		check("deploy hands the expeditio to the legio panel", deployed[1] == "e1", deployed)
	end)

	-- plain text of a card line, whether it is a string or a row of segments
	local function line_text(line)
		if type(line) == "string" then
			return line
		end
		if type(line) == "table" and line.segments then
			local out = {}
			for _, seg in ipairs(line.segments) do
				table.insert(out, seg[1])
			end
			return table.concat(out)
		end
		return ""
	end

	local function count(haystack, needle)
		local n, from = 0, 1
		while true do
			local at = haystack:find(needle, from, true)
			if not at then
				return n
			end
			n, from = n + 1, at + #needle
		end
	end

	local function hierarchy_for(legio)
		local out = {}
		for _, e in ipairs(legio_mapper.to_hierarchy_entries(legio, 200, nil, mandatum_of)) do
			table.insert(out, e)
		end
		return out
	end

	-- every miles in the legio, by id, so the live roster can hand back the same records
	local function miles_by_id(legio)
		local map = {}
		local function walk(unit)
			for _, key in ipairs({ "leader", "second" }) do
				if unit[key] then
					map[unit[key].id] = unit[key]
				end
			end
			for _, p in ipairs(unit.milites or {}) do
				map[p.id] = p
			end
			for _, c in ipairs(unit.units or {}) do
				walk(c)
			end
		end
		if legio.cohors then
			walk(legio.cohors)
		end
		return map
	end

	-- runs fn with a live roster for the legio, a review count and a merge request, then restores the app
	local function with_live(legio, fn)
		local dtos = miles_by_id(legio)
		local services = function()
			return {
				roster = {
					get = function(_, id)
						return dtos[id]
					end,
				},
				review_process = {
					summary = function()
						return { sent = 2, resolved = 1 }
					end,
				},
				merge_request_process = {
					allows = function(role)
						return role == nil or role == "decanus"
					end,
					summary = function()
						return { card_lines = { { segments = { { "!12 open", "ok" } } } } }
					end,
				},
			}
		end
		local restore = swap_services(HIERARCHY_FUNCTIONS(), services)
		local ok, a, b = pcall(fn)
		restore()
		return ok, a, b
	end

	local function entry_for(entries, miles_id)
		for _, e in ipairs(entries) do
			if e.miles_id == miles_id then
				return e
			end
		end
	end

	-- the sidebar's active miles rows for a set of dtos and contubernia, as the miles mapper builds them
	local function active_rows(dtos, contubernia, legiones)
		return miles_cards.to_active_rows(dtos, "/p", nil, nil, contubernia, legio_mapper.deployed_miles_ids(legiones or {}))
	end

	test("a miles in a deployed legio appears once, and the miles panel holds only milites outside a legio", function()
		local legio = fixture()
		local dtos = {
			post("Lucius", "decanus", "princeps", "working"),
			post("Quintus", "faber", "hastatus", "working"),
			post("Aulus", "probator", "hastatus", "starting"),
			{ id = "free", name = "Free", root = "/p", state = "idle", busy = false, running = true, tone = "off" },
		}
		local contubernia = { { label = "split the api", members = { { miles_id = "lucius", decanus = true, position = 1 }, { miles_id = "quintus", position = 2 }, { miles_id = "aulus", position = 3 } } } }
		local rows = active_rows({ dtos[1], dtos[2], dtos[3], dtos[4] }, contubernia, { legio })
		local ids = {}
		local cards = 0
		for _, r in ipairs(rows) do
			table.insert(ids, tostring(r.miles_id))
			if r.mark == "◆ " then
				cards = cards + 1
			end
		end
		check("no contubernium card in the miles panel", cards == 0, ids)
		check("no legio miles in the miles panel", not vim.tbl_contains(ids, "quintus") and not vim.tbl_contains(ids, "aulus") and not vim.tbl_contains(ids, "lucius"), ids)
		check("the miles outside a legio stay in the miles panel", #rows == 1 and rows[1].miles_id == "free", ids)

		local seen = 0
		for _, e in ipairs(hierarchy_for(legio)) do
			if e.miles_id == "quintus" then
				seen = seen + 1
			end
		end
		for _, r in ipairs(rows) do
			if r.miles_id == "quintus" then
				seen = seen + 1
			end
		end
		check("Quintus appears exactly once across the legio and the miles panel", seen == 1, seen)
	end)

	test("a decanus card is his live card: name, mandatum, counts, meter and rank", function()
		local legio = fixture()
		local entry = entry_for(hierarchy_for(legio), "lucius")
		check("Lucius has a leader card", entry ~= nil)
		if not entry then
			return
		end
		local ok, card = with_live(legio, function()
			return legio_panel.card_on_render(entry)
		end)
		check("the decanus card renders", ok, card)
		if not ok then
			return
		end
		check("line 1 names the contubernium, the miles and the role", line_text(card[1]) == "split the api · Lucius · decanus", line_text(card[1]))
		check("line 2 is the mandatum title", line_text(card[2]) == MANDATUM, line_text(card[2]))
		check("line 3 is the unit summary and the counts", line_text(card[3]) == "1 working · 1 starting · 2 open · 1 resolved", line_text(card[3]))
		check("line 4 is the live meter at 40%", card[4] ~= nil and card[4].percent == "40%", card[4])
		check("line 5 is the rank", line_text(card[5]) == "▴ princeps", line_text(card[5]))
		check("line 6 is the merge request, as on the live card", card[6] ~= nil and line_text(card[6]) == "!12 open", card[6])
		check("the leader card has six lines", #card == 6, #card)
	end)
	test("a contubernium is one decanus card, with every member one tree line under it", function()
		local entries = hierarchy_for(fixture())
		local cards, at = {}, nil
		for i, e in ipairs(entries) do
			if e.summary and e.summary.title == "split the api · Lucius · decanus" then
				table.insert(cards, e)
				at = at or i
			end
		end
		check("the contubernium is exactly one card", #cards == 1, #cards)
		if not at then
			return
		end
		local lines = {}
		for i = at + 1, #entries do
			if entries[i].miles_id then
				table.insert(lines, line_text(entries[i].card[1]))
			end
		end
		check("each member is one tree line under the card, last one └", vim.inspect(lines) == vim.inspect({ "├ Quintus faber · working · 40% · opus", "└ Aulus probator · starting · 40% · opus" }), lines)
	end)
	test("every member gets one compact line, idle and done members included", function()
		local legio = fixture()
		local members = legio.cohors.units[1].units[1].milites
		table.insert(members, post("Julius", "probator", "hastatus", "idle"))
		table.insert(members, post("Marcus II", "censor", "hastatus", "done"))
		local entries = hierarchy_for(legio)
		local lines = {}
		for _, e in ipairs(entries) do
			if e.miles_id and not e.live and (e.miles_id == "julius" or e.miles_id == "marcus ii" or e.miles_id == "quintus" or e.miles_id == "aulus") then
				table.insert(lines, line_text(e.card[1]))
				check(e.miles_id .. " is one line", #e.card == 1, #e.card)
			end
		end
		check("idle and done members each get their line, in order", vim.inspect(lines) == vim.inspect({ "├ Quintus faber · working · 40% · opus", "├ Aulus probator · starting · 40% · opus", "├ Julius probator · idle · 40% · opus", "└ Marcus II censor · done · 40% · opus" }), lines)
	end)

	test("a decanus card's first line names the contubernium, the miles and the role once", function()
		local legio = fixture()
		local entry = entry_for(hierarchy_for(legio), "lucius")
		check("Lucius has a leader card", entry ~= nil)
		if not entry then
			return
		end
		local ok, card = with_live(legio, function()
			return legio_panel.card_on_render(entry)
		end)
		check("the decanus card renders", ok, card)
		if not ok then
			return
		end
		local first = line_text(card[1])
		check("the contubernium is named once", count(first, "split the api") == 1, first)
		check("the miles is named once", count(first, "Lucius") == 1, first)
		check("the role is named once", count(first, "decanus") == 1, first)
	end)
	test("a decanus card carries the review counts and the meter of his live row", function()
		local legio = fixture()
		local entry = entry_for(hierarchy_for(legio), "lucius")
		check("Lucius has a leader card", entry ~= nil)
		if not entry then
			return
		end
		local ok, card = with_live(legio, function()
			return legio_panel.card_on_render(entry)
		end)
		check("the decanus card renders", ok, card)
		if not ok then
			return
		end
		local counts = line_text(card[3])
		check("the counts line holds the sent and resolved review counts", count(counts, "2 open") == 1 and count(counts, "1 resolved") == 1, counts)
		check("the meter sits under the counts line at 40%", card[4] ~= nil and card[4].percent == "40%", card[4])
	end)

	test("enter on a member line or a leader card opens that miles' thread, and the legio row opens none", function()
		local legio = fixture()
		local entries = refresh(legio)
		local member = entry_for(entries, "quintus")
		local leader = entry_for(entries, "lucius")
		local legio_row = entries[1]
		check("the member line and the leader card are there", member ~= nil and leader ~= nil)
		if not (member and leader) then
			return
		end
		local miles_panel = require("workspace.legio.presentation.nvim.miles_panel")
		local recorded = {}
		local services = function()
			return {
				roster = {
					get = function(_, id)
						return miles_by_id(legio)[id]
					end,
				},
				conversation_thread = {
					for_session = function(_, id, miles_id)
						return { session_id = id, miles_id = miles_id }
					end,
				},
				drafting = {
					load = function()
						return nil
					end,
				},
			}
		end
		local restore = swap_services(HIERARCHY_FUNCTIONS(), services)
		local opened, shown = {}, {}
		local original_open, original_show = miles_panel.open_on_enter, miles_panel.show_conversation_on_select
		miles_panel.open_on_enter = function(e)
			table.insert(opened, e.miles_id)
		end
		miles_panel.show_conversation_on_select = function(e)
			table.insert(shown, e.miles_id)
		end
		local ok, err = pcall(function()
			recorded.member = board.thread_on_select(member, { log = {} })
			recorded.leader = board.thread_on_select(leader, { log = {} })
			recorded.legio = board.thread_on_select(legio_row, { log = {} })
			board.open_on_enter(member, nil)
			board.show_conversation_on_select(member, nil)
		end)
		restore()
		miles_panel.open_on_enter, miles_panel.show_conversation_on_select = original_open, original_show
		check("the stubs ran", ok, err)
		check("a member line returns its miles' thread via the miles panel", recorded.member ~= nil and recorded.member.session_id == "quintus" and recorded.member.miles_id == "quintus", recorded.member)
		check("a leader card returns its miles' thread via the miles panel", recorded.leader ~= nil and recorded.leader.session_id == "lucius" and recorded.leader.miles_id == "lucius", recorded.leader)
		check("the legio row still returns no thread", recorded.legio == nil, recorded.legio)
		check("enter on a member reaches the miles panel with that miles", vim.inspect(opened) == vim.inspect({ "quintus" }), opened)
		check("showing the conversation of a member reaches the miles panel with that miles", vim.inspect(shown) == vim.inspect({ "quintus" }), shown)
	end)

end

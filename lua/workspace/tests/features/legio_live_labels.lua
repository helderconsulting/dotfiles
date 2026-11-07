local app = require("workspace.workbench.presentation.nvim.app")
local cards = require("workspace.workbench.presentation.nvim.cards")
local legio_panel = require("workspace.legio.presentation.nvim.legio_panel")
local miles_panel = require("workspace.legio.presentation.nvim.miles_panel")

local BARS = { "▏", "▎", "▌" }

-- records shaped like live data: session titles as names, labels that already start with their kind
local function miles(id, title, role, rank, state, context, model)
	return {
		id = id,
		miles_id = id,
		name = title,
		title = title,
		role = role,
		post = role,
		rank = rank,
		standing = { rank = rank, level = 1, done = 0, needed = 3, unit = "mandata" },
		state = state,
		tone = state == "working" and "busy" or "off",
		running = true,
		busy = state == "working",
		root = "/p",
		legio = "x",
		context_fraction = context,
		model_label = model,
		mode_label = "ask",
	}
end

local function fixture()
	local servius = miles("servius", "Servius · decanus · Split the api", "decanus", "princeps", "working", 0.42, "opus")
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
		},
		cohors = {
			kind = "cohors",
			id = "c1",
			label = ".config",
			milites = {},
			units = {
				{
					kind = "centuria",
					id = "ce1",
					label = "centuria agentd sdk",
					leader = (function()
						local marcus = miles("marcus", "Marcus · centurio · Own the agentd sdk", "centurio", "triarius", "working", 0.2, "opus")
						marcus.worktree = "agentd sdk"
						return marcus
					end)(),
					second = miles("gaius", "Gaius · optio · Review the agentd sdk", "optio", "princeps", "idle", 0.09, "sonnet"),
					milites = {},
					units = {
						{
							kind = "contubernium",
							id = "co1",
							label = "contubernium pluvialis",
							leader = servius,
							milites = {
								miles("titus", "Titus · faber · Write the annales for the sidebar", "faber", "hastatus", "done", 0.12, "haiku"),
								miles("cassius", "Cassius · probator · Test the annales", "probator", "hastatus", "working", 0.4, "sonnet"),
								miles("flavius", "Flavius · censor · Check the annales", "censor", "hastatus", "idle", 0.07, "opus"),
							},
							units = {},
						},
					},
				},
			},
		},
	}
end

-- runs fn with the legio panel's services: the legio, its miles by id, a review count and no merge request
-- the app tables the legio modules actually read: a module keeps the app it loaded with, and a harness
-- that swaps package.loaded for a while can leave a module holding a different one, so we find them
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

-- loaded when first used, not at file load: loading review_marks needs the app the tests have just put in place
local function review_counts()
	-- review_marks subscribes to app events when it loads; a harness may have left a table without 'on' in place
	local current = package.loaded["workspace.workbench.presentation.nvim.app"] or require("workspace.workbench.presentation.nvim.app")
	if current.on == nil then
		current.on = function() end
	end
	return require("workspace.workflow.presentation.nvim.review_marks").counts
end

local function with_services(legio, fn, review, contubernia, roster_dtos)
	local dtos = {}
	local function walk(unit)
		for _, key in ipairs({ "leader", "second" }) do
			if unit[key] then
				dtos[unit[key].id] = unit[key]
			end
		end
		for _, p in ipairs(unit.milites or {}) do
			dtos[p.id] = p
		end
		for _, c in ipairs(unit.units or {}) do
			walk(c)
		end
	end
	walk(legio.cohors)
	local tables = app_tables({ legio_panel.entries_on_refresh, legio_panel.card_on_render, miles_panel.dto, miles_panel.live_row, miles_panel.card_lines, review_counts() })
	local saved = {}
	local services = function()
		return {
			legio_process = {
				raise_legiones = function() end,
				revive_waiting = function() end,
				credit_finished = function() end,
				legiones = function()
					return { legio }
				end,
			},
			roster = {
				get = function(_, id)
					return (roster_dtos and roster_dtos[id]) or dtos[id]
				end,
				all_contubernia = function()
					return contubernia or {}
				end,
			},
			review_process = {
				summary = function()
					return review or { sent = 0, resolved = 13 }
				end,
			},
			merge_request_process = {
				allows = function(role)
					return role == nil or role == "decanus"
				end,
				summary = function()
					return nil
				end,
			},
		}
	end
	for _, t in ipairs(tables) do
		saved[t] = { services = t.services, on = t.on }
		t.services = services
		t.on = function() end
	end
	local ok, a = pcall(fn)
	for _, t in ipairs(tables) do
		t.services, t.on = saved[t].services, saved[t].on
	end
	return ok, a
end

local function entries_of(legio)
	local out
	legio_panel.entries_on_refresh(nil, function(list)
		out = list
	end)
	return out or {}
end

-- rendered rows in a window of the given width, with the bar and gap taken off
local function render(entries, width)
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 0, col = 0, width = width, height = 120, style = "minimal" })
	local ns = vim.api.nvim_create_namespace("legio_live_labels")
	cards.render(buf, win, ns, entries, legio_panel.card_on_render, { wrap = true })
	local raw = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	vim.api.nvim_win_close(win, true)
	vim.api.nvim_buf_delete(buf, { force = true })
	local out = {}
	for _, line in ipairs(raw) do
		for _, bar in ipairs(BARS) do
			if line:sub(1, #bar) == bar then
				line = line:sub(#bar + 1):gsub("^ ", "")
				break
			end
		end
		if line ~= "" then
			table.insert(out, line)
		end
	end
	return out
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

local function row_with(rows, needle)
	for _, line in ipairs(rows) do
		if line:find(needle, 1, true) then
			return line
		end
	end
end

-- rendered rows as they are drawn, bar and gap taken off, blank separator rows kept
local function raw_rows(entries, width)
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 0, col = 0, width = width, height = 120, style = "minimal" })
	local ns = vim.api.nvim_create_namespace("legio_live_labels_raw")
	cards.render(buf, win, ns, entries, legio_panel.card_on_render, { wrap = true })
	local raw = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	vim.api.nvim_win_close(win, true)
	vim.api.nvim_buf_delete(buf, { force = true })
	local out = {}
	for _, line in ipairs(raw) do
		for _, bar in ipairs(BARS) do
			if line:sub(1, #bar) == bar then
				line = line:sub(#bar + 1):gsub("^ ", "")
				break
			end
		end
		table.insert(out, line)
	end
	return out
end

local function two_contubernia()
	local legio = fixture()
	local centuria = legio.cohors.units[1]
	table.insert(centuria.units, {
		kind = "contubernium",
		id = "co2",
		label = "contubernium castor",
		leader = miles("pollux", "Pollux · decanus · Guard the sdk", "decanus", "princeps", "idle", 0.1, "sonnet"),
		milites = { miles("helix", "Helix · faber · Ship it", "faber", "hastatus", "done", 0.05, "haiku") },
		units = {},
	})
	return legio
end

local function line_text_of(line)
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

return function(t)
	local test, check = t.test, t.check

	test("a live centuria label that already says centuria is not prefixed twice", function()
		local legio = fixture()
		local ok, rows = with_services(legio, function()
			return render(entries_of(legio), 60)
		end)
		check("the legio renders", ok, rows)
		if not ok then
			return
		end
		local joined = table.concat(rows, "\n")
		check("no 'centuria centuria'", not joined:find("centuria centuria", 1, true), rows)
		check("the centurio's title line is the bare name", row_with(rows, "Marcus") == "agentd sdk · Marcus · centurio", row_with(rows, "Marcus"))
		check("'centuria' is not doubled anywhere on the card", count(joined, "centuria") <= 1, rows)
	end)

	test("a live contubernium label that already says contubernium is not prefixed twice", function()
		local legio = fixture()
		local ok, rows = with_services(legio, function()
			return render(entries_of(legio), 60)
		end)
		check("the legio renders", ok, rows)
		if not ok then
			return
		end
		local joined = table.concat(rows, "\n")
		check("no 'contubernium contubernium'", not joined:find("contubernium contubernium", 1, true), rows)
		local line = row_with(rows, "Servius") or ""
		check("the decanus title line is the bare name", line == "pluvialis · Servius · decanus", line)
		check("'contubernium' is not doubled anywhere on the card", count(joined, "contubernium") <= 1, rows)
	end)

	test("a member line is only the tree glyph, name, role, state, context and model", function()
		local legio = fixture()
		local ok, rows = with_services(legio, function()
			return render(entries_of(legio), 60)
		end)
		check("the legio renders", ok, rows)
		if not ok then
			return
		end
		check("Titus's line is literal, without the session title", row_with(rows, "Titus") == "├ Titus faber · done · 12% · haiku", row_with(rows, "Titus"))
		check("Cassius's line is literal", row_with(rows, "Cassius") == "├ Cassius probator · working · 40% · sonnet", row_with(rows, "Cassius"))
		check("the last member closes with └", row_with(rows, "Flavius") == "└ Flavius censor · idle · 7% · opus", row_with(rows, "Flavius"))
		local joined = table.concat(rows, "\n")
		check("no session title reaches a member line", not joined:find("Write the annales", 1, true) and not joined:find("Test the annales", 1, true), rows)
		check("the role appears once on Titus's line", count(row_with(rows, "Titus") or "", "faber") == 1, row_with(rows, "Titus"))
	end)

	test("the centurio card names the expeditio once", function()
		local legio = fixture()
		local ok, rows = with_services(legio, function()
			return render(entries_of(legio), 60)
		end)
		check("the legio renders", ok, rows)
		if not ok then
			return
		end
		local centurio = row_with(rows, "Marcus") or ""
		check("the centurio's line names the expeditio once", count(centurio, "agentd sdk") == 1, centurio)
		local block, started = {}, false
		for _, line in ipairs(rows) do
			if line:find("Marcus", 1, true) then
				started = true
			elseif line:find("Servius", 1, true) then
				break
			end
			if started then
				table.insert(block, line)
			end
		end
		check("the expeditio appears once across the centurio card, place line included", count(table.concat(block, "\n"), "agentd sdk") == 1, block)
	end)

	test("a decanus card line 1 is '<contubernium> · <decanus> · decanus' for a prefixed label", function()
		local legio = fixture()
		local ok, rows = with_services(legio, function()
			return render(entries_of(legio), 60)
		end)
		check("the legio renders", ok, rows)
		if ok then
			check("line 1 is exactly 'pluvialis · Servius · decanus'", row_with(rows, "Servius") == "pluvialis · Servius · decanus", row_with(rows, "Servius"))
		end
	end)

	test("a decanus card line 1 is the same for a bare contubernium label", function()
		local legio = fixture()
		legio.cohors.units[1].units[1].label = "pluvialis"
		local ok, rows = with_services(legio, function()
			return render(entries_of(legio), 60)
		end)
		check("the legio renders", ok, rows)
		if ok then
			check("line 1 is exactly 'pluvialis · Servius · decanus' with a bare label", row_with(rows, "Servius") == "pluvialis · Servius · decanus", row_with(rows, "Servius"))
		end
	end)

	test("the second contubernium's first entry is set off by a blank separator, the first is not", function()
		local legio = two_contubernia()
		local ok, rows = with_services(legio, function()
			return raw_rows(entries_of(legio), 60)
		end)
		check("the legio renders", ok, rows)
		if not ok then
			return
		end
		local first, second
		for i, line in ipairs(rows) do
			if line:find("Servius", 1, true) and not first then
				first = i
			end
			if line:find("Pollux", 1, true) and not second then
				second = i
			end
		end
		check("both decanus cards are drawn", first ~= nil and second ~= nil, { first, second })
		if not (first and second) then
			return
		end
		check("the second contubernium's first entry has a blank line above it", rows[second - 1] == "", rows[second - 1])
		check("the first contubernium's first entry has no blank line above it", rows[first - 1] ~= "", rows[first - 1])
	end)

	test("the decanus and centurio lines come out right from the real DTO mapper's units", function()
		local Miles = require("workspace.legio.domain.miles")
		local Contubernium = require("workspace.legio.domain.contubernium")
		local Centuria = require("workspace.legio.domain.centuria")
		local dto_mapper = require("workspace.legio.application.mappers.legio_dto_mapper")
		local legio_mapper = require("workspace.legio.presentation.mappers.legio_view_mapper")

		local function domain_miles(id, roman, state)
			return Miles:new({ id = id, roman_name = roman, state = state, legio = "x", root = "/p", cwd = "/p" })
		end
		local by_id = {
			servius = domain_miles("servius", "Servius", "working"),
			titus = domain_miles("titus", "Titus", "done"),
			marcus = domain_miles("marcus", "Marcus", "working"),
			gaius = domain_miles("gaius", "Gaius", "idle"),
			pollux = domain_miles("pollux", "Pollux", "idle"),
			helix = domain_miles("helix", "Helix", "done"),
		}
		local function find(id)
			return by_id[id]
		end
		local pluvialis = dto_mapper.to_contubernium_unit(Contubernium.make("co1", "todo1", "/p", "main", { "servius", "titus" }, 1, "pluvialis"), find)
		local castor = dto_mapper.to_contubernium_unit(Contubernium.make("co2", "todo2", "/p", "main", { "pollux", "helix" }, 2, "castor"), find)
		local centuria = dto_mapper.to_centuria_unit(Centuria.make({ id = "ce1", title = "agentd sdk", centurio = "marcus", optio = "gaius" }), { Contubernium.make("co1", "todo1", "/p", "main", { "servius", "titus" }, 1, "pluvialis"), Contubernium.make("co2", "todo2", "/p", "main", { "pollux", "helix" }, 2, "castor") }, find)
		check("the real mapper keeps the live label", pluvialis.label == "contubernium pluvialis", pluvialis.label)

		-- a dto shaped like the one the roster hands the view: the real post fields plus the miles fields
		local function as_miles(post)
			return { id = post.miles_id, miles_id = post.miles_id, name = post.name, role = post.post, post = post.post, rank = post.rank, standing = post.standing, state = post.state, tone = post.tone, running = post.running, root = "/p", legio = "x" }
		end
		local legio = { id = "x", name = "Legio X Rapax", munus = "implement", roles = {}, deployed = true, expeditio = "agentd sdk", cohors = centuria }
		local ok, out = with_services(fixture(), function()
			local entries = legio_mapper.to_hierarchy_entries(legio, 200, as_miles, function(unit)
				if unit.kind == "contubernium" then
					return "Split the api"
				end
			end)
			local decanus, centurio, castor_leader
			for _, e in ipairs(entries) do
				if e.label == "contubernium pluvialis" and e.position == 1 then
					decanus = e
				elseif e.summary and e.summary.title and e.summary.title:find("agentd sdk", 1, true) and e.kind then
					centurio = centurio or e
				elseif e.label == "contubernium castor" and e.position == 1 then
					castor_leader = e
				end
			end
			local rows = {}
			for _, e in ipairs({ centurio, decanus, castor_leader }) do
				rows[#rows + 1] = e and legio_panel.card_on_render(e) or {}
			end
			return { rows = rows, entries = entries, decanus = decanus, castor = castor_leader }
		end)
		check("the legio builds from the real units", ok, out)
		if not ok then
			return
		end
		local decanus_line = out.rows[2][1] and line_text_of(out.rows[2][1]) or nil
		check("the decanus line is exactly 'pluvialis · Servius · decanus' from the real units", decanus_line == "pluvialis · Servius · decanus", decanus_line)
		local centurio_line = out.rows[1][1] and line_text_of(out.rows[1][1]) or nil
		check("the centurio line is exactly 'agentd sdk · Marcus · centurio' from the real units", centurio_line == "agentd sdk · Marcus · centurio", centurio_line)
		check("the second contubernium's decanus is in the entries", out.castor ~= nil, out.castor)
	end)

	test("a contubernium whose decanus is gone still gets a name card, its members after it, and a blank separator", function()
		local Contubernium = require("workspace.legio.domain.contubernium")
		local Miles = require("workspace.legio.domain.miles")
		local legio_mapper = require("workspace.legio.presentation.mappers.legio_view_mapper")
		local dto_mapper = require("workspace.legio.application.mappers.legio_dto_mapper")
		local legio = fixture()
		local helix = Miles:new({ id = "helix", roman_name = "Helix", state = "done", legio = "x", root = "/p", cwd = "/p" })
		local find = function(id)
			return id == "helix" and helix or nil
		end
		-- the first member's miles is gone, so the decanus (members[1]) has no miles and the unit has no leader
		local castor = Contubernium.enlist({ id = "co3", name = "castor", members = { { name = "ash", miles = nil }, { name = "birch", miles = "helix" } } })
		local castor_unit = dto_mapper.to_contubernium_unit(castor, find)
		check("the real unit has no leader", castor_unit.leader == nil and castor_unit.label == "contubernium castor", castor_unit.label)
		table.insert(legio.cohors.units[1].units, castor_unit)
		local ok, rows = with_services(fixture(), function()
			local entries = legio_mapper.to_hierarchy_entries(legio, 200, function(post)
				return { id = post.miles_id, miles_id = post.miles_id, name = post.name, role = post.post, post = post.post, rank = post.rank, standing = post.standing, state = post.state, tone = post.tone, running = post.running, root = "/p", legio = "x" }
			end, nil)
			return raw_rows(entries, 60)
		end)
		check("the legio renders with the leaderless unit", ok, rows)
		if not ok then
			return
		end
		local at
		for i, line in ipairs(rows) do
			if line == "castor" then
				at = i
			end
		end
		check("the leaderless contubernium shows its bare name on line 1", at ~= nil, rows)
		if not at then
			return
		end
		check("a blank separator precedes its card", rows[at - 1] == "", rows[at - 1])
		check("its second line is its state counts", rows[at + 1] == "1 done", rows[at + 1])
		check("its member follows the card", rows[at + 2] ~= nil and rows[at + 2]:find("Helix", 1, true) ~= nil, rows[at + 2])
		local after = table.concat({ unpack(rows, at + 1) }, "\n")
		check("the previous contubernium's members do not follow it", not after:find("Tiberius", 1, true), rows)
	end)

	test("a leader's line shows the Roman name when the roster's display name is a session title", function()
		local legio = fixture()
		local leader = legio.cohors.units[1].units[1].leader
		-- the plan post carries the Roman name; the roster's display name is the session title
		leader.name = "Servius"
		local roster_dto = {}
		for k, v in pairs(leader) do
			roster_dto[k] = v
		end
		roster_dto.name = "Servius · decanus · Fix the annales parser"
		-- the contubernium's members carry slot names, as Contubernium.make stores them
		local contubernia = {
			{
				id = "co1",
				todo = "todo1",
				members = {
					{ name = "ash", miles_id = "servius" },
					{ name = "birch", miles_id = "titus" },
					{ name = "cedar", miles_id = "cassius" },
					{ name = "elm", miles_id = "flavius" },
				},
			},
		}
		local ok, rows = with_services(legio, function()
			return raw_rows(entries_of(legio), 60)
		end, nil, contubernia, { servius = roster_dto })
		check("the legio renders", ok, rows)
		if not ok then
			return
		end
		check("line 1 shows the Roman name", row_with(rows, "Servius") == "pluvialis · Servius · decanus", row_with(rows, "Servius"))
		check("the session title is not in the name slot", row_with(rows, "Fix the annales parser") == nil, row_with(rows, "Fix the annales parser"))
		check("no slot name reaches the card", not table.concat(rows, "\n"):find("ash", 1, true), rows)
	end)

	test("with no own name anywhere, the leader's name falls back to the title text", function()
		local legio = fixture()
		legio.cohors.units[1].units[1].leader.name = "Fix the annales parser"
		local ok, rows = with_services(legio, function()
			return raw_rows(entries_of(legio), 60)
		end)
		check("the legio renders", ok, rows)
		if not ok then
			return
		end
		check("line 1 falls back to 'pluvialis · Fix the annales parser · decanus'", row_with(rows, "Fix the annales parser") == "pluvialis · Fix the annales parser · decanus", row_with(rows, "Fix the annales parser"))
	end)

	test("a leader card with no review counts renders without error and shows no counts, the rest intact", function()
		local legio = fixture()
		local ok, card = with_services(legio, function()
			for _, e in ipairs(entries_of(legio)) do
				if e.label == "contubernium pluvialis" and e.position == 1 then
					return legio_panel.card_on_render(e)
				end
			end
		end, {})
		check("the card builds without a review count", ok, card)
		if not ok then
			return
		end
		local text = {}
		for _, line in ipairs(card) do
			table.insert(text, line_text_of(line))
		end
		local joined = table.concat(text, "\n")
		check("no '0 open' is shown", not joined:find("0 open", 1, true), joined)
		check("no 'resolved' count is shown", not joined:find("resolved", 1, true), joined)
		check("the name line is still there", text[1] == "pluvialis · Servius · decanus", text[1])
		local meter, rank = false, false
		for _, line in ipairs(card) do
			if type(line) == "table" and line.percent ~= nil then
				meter = true
			end
			if line_text_of(line) == "▴ princeps" then
				rank = true
			end
		end
		check("the meter is still there", meter, card)
		check("the rank is still there", rank, text)
	end)

	test("slot names from the roster never reach a member line or a title: Titus keeps his Roman name", function()
		local legio = fixture()
		-- the roster's contubernia carry slot names (ash, birch, ...), as Contubernium.make stores them
		local contubernia = {
			{
				id = "co1",
				todo = "todo1",
				members = {
					{ name = "ash", miles_id = "servius" },
					{ name = "birch", miles_id = "titus" },
					{ name = "cedar", miles_id = "cassius" },
					{ name = "elm", miles_id = "flavius" },
				},
			},
		}
		local ok, rows = with_services(legio, function()
			return raw_rows(entries_of(legio), 60)
		end, nil, contubernia)
		check("the legio renders with slot names on the roster", ok, rows)
		if not ok then
			return
		end
		check("Titus's line uses his Roman name, not 'birch'", row_with(rows, "Titus") == "├ Titus faber · done · 12% · haiku", row_with(rows, "Titus"))
		check("the decanus title is 'pluvialis · Servius · decanus', not a slot name", row_with(rows, "Servius") == "pluvialis · Servius · decanus", row_with(rows, "Servius"))
		local joined = table.concat(rows, "\n")
		check("no slot name appears anywhere on the card", not joined:find("ash", 1, true) and not joined:find("birch", 1, true) and not joined:find("cedar", 1, true) and not joined:find("elm", 1, true), rows)
	end)

	test("a leaderless contubernium after another is set off by a blank separator before its name", function()
		local Contubernium = require("workspace.legio.domain.contubernium")
		local Miles = require("workspace.legio.domain.miles")
		local dto_mapper = require("workspace.legio.application.mappers.legio_dto_mapper")
		local legio_mapper = require("workspace.legio.presentation.mappers.legio_view_mapper")
		local legio = fixture()
		local helix = Miles:new({ id = "helix", roman_name = "Helix", state = "done", legio = "x", root = "/p", cwd = "/p" })
		local castor = Contubernium.enlist({ id = "co3", name = "castor", members = { { name = "ash", miles = nil }, { name = "birch", miles = "helix" } } })
		table.insert(legio.cohors.units[1].units, dto_mapper.to_contubernium_unit(castor, function(id)
			return id == "helix" and helix or nil
		end))
		local ok, rows = with_services(fixture(), function()
			local entries = legio_mapper.to_hierarchy_entries(legio, 200, function(post)
				return { id = post.miles_id, miles_id = post.miles_id, name = post.name, role = post.post, post = post.post, rank = post.rank, standing = post.standing, state = post.state, tone = post.tone, running = post.running, root = "/p", legio = "x" }
			end, nil, nil)
			return raw_rows(entries, 60)
		end)
		check("the legio renders", ok, rows)
		if not ok then
			return
		end
		local decanus, bare
		for i, line in ipairs(rows) do
			if line == "pluvialis · Servius · decanus" then
				decanus = i
			elseif line == "castor" then
				bare = i
			end
		end
		check("the first contubernium is drawn first", decanus ~= nil and bare ~= nil and decanus < bare, { decanus, bare })
		check("a blank line sets the leaderless contubernium off", bare ~= nil and rows[bare - 1] == "", bare and rows[bare - 1])
	end)

end

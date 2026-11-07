local app = require("workspace.workbench.presentation.nvim.app")
local cards = require("workspace.workbench.presentation.nvim.cards")
local legio_panel = require("workspace.legio.presentation.nvim.legio_panel")
local miles_panel = require("workspace.legio.presentation.nvim.miles_panel")
local legio_mapper = require("workspace.legio.presentation.mappers.legio_view_mapper")

local BARS = { "▏", "▎", "▌" }
local TITLE = "Split the api into two layers"

local function mandatum_of(unit)
	if unit.kind == "contubernium" then
		return TITLE
	end
end
local COUNTS = "1 idle · 2 done · 13 resolved"

local function member(name, role, state, context, model)
	return {
		id = name:lower(),
		miles_id = name:lower(),
		name = name,
		post = role,
		role = role,
		rank = "hastatus",
		standing = { rank = "hastatus", level = 1, done = 0, needed = 3, unit = "mandata" },
		state = state,
		tone = state == "working" and "busy" or "off",
		running = true,
		busy = state == "working",
		root = "/p",
		legio = "x",
		context_fraction = context,
		model_label = model,
		mode_label = "ask",
		title = TITLE,
	}
end

-- agentd sdk: centurio Marcus, optio Gaius, contubernium pluvialis led by decanus Servius
local function fixture()
	local servius = member("Servius", "decanus", "working", 0.42, "opus")
	servius.rank = "princeps"
	servius.standing = { rank = "princeps", level = 1, done = 0, needed = 3, unit = "mandata" }
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
					label = "agentd sdk",
					leader = member("Marcus", "centurio", "working", 0.2, "opus"),
					second = member("Gaius", "optio", "idle", 0.09, "sonnet"),
					milites = {},
					units = {
						{
							kind = "contubernium",
							id = "co1",
							label = "pluvialis",
							leader = servius,
							milites = {
								member("Tiberius", "faber", "done", 0.12, "haiku"),
								member("Cassius", "probator", "done", 0.3, "sonnet"),
								member("Flavius", "censor", "idle", 0.07, "opus"),
							},
							units = {},
						},
					},
				},
			},
		},
	}
end

-- every miles in the legio by id, so the live roster hands back the same records
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
	walk(legio.cohors)
	return map
end

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

-- runs fn with a live roster, the review counts of the legio (13 resolved, none open) and no merge request
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
					return { sent = 0, resolved = 13 }
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
	local restore = swap_services({ legio_panel.entries_on_refresh, legio_panel.card_on_render, miles_panel.dto, miles_panel.live_row, miles_panel.card_lines, review_counts() }, services)
	local ok, a, b = pcall(fn)
	restore()
	return ok, a, b
end

-- the rendered rows of a list of entries in a window of the given width, with the bar and gap taken off
local function render(entries, width, card_fn)
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 0, col = 0, width = width, height = 80, style = "minimal" })
	local ns = vim.api.nvim_create_namespace("legio_card_layout")
	cards.render(buf, win, ns, entries, card_fn, { wrap = true })
	local raw = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	vim.api.nvim_win_close(win, true)
	vim.api.nvim_buf_delete(buf, { force = true })
	local out = {}
	for _, line in ipairs(raw) do
		local text = line
		for _, bar in ipairs(BARS) do
			if text:sub(1, #bar) == bar then
				text = text:sub(#bar + 1):gsub("^ ", "")
				break
			end
		end
		if text ~= "" then
			table.insert(out, text)
		end
	end
	return out, raw
end

local function index_of(list, text)
	for i, line in ipairs(list) do
		if line == text then
			return i
		end
	end
end

return function(t)
	local test, check = t.test, t.check

	test("a leader card reads name line, mandatum title, counts, meter, rank, then one tree line per member", function()
		local legio = fixture()
		local ok, lines = with_live(legio, function()
			local entries = legio_mapper.to_hierarchy_entries(legio, 200, nil, mandatum_of)
			return render(entries, 44, legio_panel.card_on_render)
		end)
		check("the legio renders", ok, lines)
		if not ok then
			return
		end
		local rows = lines
		local at = index_of(rows, "pluvialis · Servius · decanus")
		check("the decanus card's name line is 'pluvialis · Servius · decanus'", at ~= nil, rows)
		if not at then
			return
		end
		check("the title follows the name line, whole", rows[at + 1] == TITLE, rows[at + 1])
		check("the counts line follows the title", rows[at + 2] == COUNTS, rows[at + 2])
		check("the live meter line follows the counts", rows[at + 3] ~= nil and rows[at + 3]:find("42%", 1, true) ~= nil and rows[at + 3]:find("opus", 1, true) ~= nil, rows[at + 3])
		check("the rank line follows the meter", rows[at + 4] == "▴ princeps", rows[at + 4])
		check("Tiberius's tree line is literal", rows[at + 5] == "├ Tiberius faber · done · 12% · haiku", rows[at + 5])
		check("Cassius's tree line is literal", rows[at + 6] == "├ Cassius probator · done · 30% · sonnet", rows[at + 6])
		check("the last member closes the tree with └", rows[at + 7] == "└ Flavius censor · idle · 7% · opus", rows[at + 7])
	end)

	test("the decanus meter line is the same line a live card shows for him", function()
		local legio = fixture()
		local ok, pair = with_live(legio, function()
			local entries = legio_mapper.to_hierarchy_entries(legio, 200, nil, mandatum_of)
			local leader
			for _, e in ipairs(entries) do
				if e.label == "pluvialis" and e.position == 1 then
					leader = e
				end
			end
			local live_row = miles_panel.live_row("servius", "pluvialis", 1)
			local live = render({ { id = "live", name = "Servius", kind = "busy", card = miles_panel.card_on_render(live_row), miles_id = "servius" } }, 44, function(e)
				return e.card
			end)
			local leader_lines = render({ leader }, 44, legio_panel.card_on_render)
			return { live = live, leader = leader_lines }
		end)
		check("both render", ok, pair)
		if not ok then
			return
		end
		local meter_live
		for _, line in ipairs(pair.live) do
			if line:find("42%", 1, true) then
				meter_live = line
			end
		end
		local meter_leader
		for _, line in ipairs(pair.leader) do
			if line:find("42%", 1, true) then
				meter_leader = line
			end
		end
		check("the live card shows the meter", meter_live ~= nil, pair.live)
		check("the leader card's meter line equals the live card's", meter_live ~= nil and meter_live == meter_leader, { meter_live, meter_leader })
	end)

	test("a narrow card wraps every line: no ellipsis, nothing wider than the card, the title's words all kept", function()
		local legio = fixture()
		local width = 26
		local ok, lines = with_live(legio, function()
			local entries = legio_mapper.to_hierarchy_entries(legio, 200, nil, mandatum_of)
			return render(entries, width, legio_panel.card_on_render)
		end)
		check("the legio renders narrow", ok, lines)
		if not ok then
			return
		end
		local joined = table.concat(lines, "\n")
		check("no line is cut with an ellipsis", not joined:find("…", 1, true), lines)
		local too_wide = {}
		for _, line in ipairs(lines) do
			if vim.fn.strdisplaywidth(line) > width then
				table.insert(too_wide, line)
			end
		end
		check("no row is wider than the card", #too_wide == 0, too_wide)
		local title_words = {}
		for word in TITLE:gmatch("%S+") do
			table.insert(title_words, word)
		end
		local seen = 0
		for _, word in ipairs(title_words) do
			if joined:find(word, 1, true) then
				seen = seen + 1
			end
		end
		check("every word of the title is on a row", seen == #title_words, { seen, #title_words })
		check("the name line never repeats the contubernium", not joined:find("contubernium contubernium", 1, true) and not joined:find("pluvialis pluvialis", 1, true), lines)
		check("Tiberius keeps his haiku on a tree line", joined:find("├ Tiberius", 1, true) ~= nil and joined:find("haiku", 1, true) ~= nil, lines)
		check("the last member still closes with └", joined:find("└ Flavius", 1, true) ~= nil, lines)
	end)

	test("the centurio card names the centuria, carries the optio as a member line, and the contubernia sit below as cards", function()
		local legio = fixture()
		local ok, lines = with_live(legio, function()
			local entries = legio_mapper.to_hierarchy_entries(legio, 200, nil, mandatum_of)
			return render(entries, 44, legio_panel.card_on_render)
		end)
		check("the legio renders", ok, lines)
		if not ok then
			return
		end
		local centurio = index_of(lines, "agentd sdk · Marcus · centurio")
		check("the centurio's name line is 'agentd sdk · Marcus · centurio'", centurio ~= nil, lines)
		if not centurio then
			return
		end
		local optio = index_of(lines, "└ Gaius optio · idle · 9% · sonnet")
		local decanus = index_of(lines, "pluvialis · Servius · decanus")
		check("the optio is a literal member line", optio ~= nil, lines)
		check("the optio line sits under the centurio card", optio ~= nil and optio > centurio, { optio, centurio })
		check("the contubernium card comes after the optio line", optio ~= nil and decanus ~= nil and decanus > optio, { decanus, optio })
	end)
end

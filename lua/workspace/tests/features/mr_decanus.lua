local app = require("workspace.workbench.presentation.nvim.app")
local board = require("workspace.workbench.presentation.nvim.board")
local miles_panel = require("workspace.legio.presentation.nvim.miles_panel")
local MergeRequest = require("workspace.workflow.domain.merge_request")
local MergeRequestProcess = require("workspace.workflow.application.merge_request_process")
local MilesSessionEvents = require("workspace.legio.application.miles_session_events")

local NON_DECANUS = { "faber", "probator", "censor", "centurio", "optio" }

-- the app tables the miles panel reads, found through its upvalues; a harness can leave a module holding another app
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

local function with_services(functions, services, fn)
	local saved = {}
	for _, t in ipairs(app_tables(functions)) do
		saved[t] = { services = t.services, on = t.on }
		t.services = services
		t.on = function() end
	end
	local ok, a, b = pcall(fn)
	for t, v in pairs(saved) do
		t.services, t.on = v.services, v.on
	end
	return ok, a, b
end

-- collects vim.notify calls as { message, level } while fn runs
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

local function agent(role, root)
	return { id = role .. "-" .. root, running = true, root = root, branch = "feat/" .. role, role = role }
end

return function(t)
	local test, check = t.test, t.check

	test("only a decanus's root is watched for a merge request", function()
		local agents = { agent("decanus", "/p/a") }
		for _, role in ipairs(NON_DECANUS) do
			table.insert(agents, agent(role, "/p/" .. role))
		end
		local watched = MergeRequest.watched(agents)
		local roots = {}
		for _, w in ipairs(watched) do
			table.insert(roots, w.root)
		end
		check("the decanus's root is watched", vim.inspect(roots) == vim.inspect({ "/p/a" }), roots)
	end)

	test("the poll checks only a decanus's root", function()
		local checked = {}
		local fake = {
			project_of = function()
				return true
			end,
			check = function(_, root)
				table.insert(checked, root)
			end,
			forget_gone = function() end,
		}
		local agents = { agent("decanus", "/p/a") }
		for _, role in ipairs(NON_DECANUS) do
			table.insert(agents, agent(role, "/p/" .. role))
		end
		MergeRequestProcess.poll(fake, agents)
		check("the poll checks the decanus's root and nothing else", vim.inspect(checked) == vim.inspect({ "/p/a" }), checked)
	end)

	test("a session event pokes the merge request check for a decanus only", function()
		local roles = { ["servius"] = { role = "decanus" }, ["titus"] = { role = "faber" }, ["marcus"] = { role = "centurio" } }
		local poked = {}
		local fake = {
			milites = {
				find = function(_, id)
					return roles[id]
				end,
			},
			merge_requests = {
				allows = function(role)
					return role == nil or role == "decanus"
				end,
				pokes = function()
					return true
				end,
				poke = function(root)
					table.insert(poked, root)
				end,
			},
			git = {
				locate = function(cwd)
					return { root = cwd }
				end,
			},
			cwd = function()
				return "/p"
			end,
		}
		MilesSessionEvents.poke_merge_request(fake, { session_id = "servius", cwd = "/p/a" })
		MilesSessionEvents.poke_merge_request(fake, { session_id = "titus", cwd = "/p/b" })
		MilesSessionEvents.poke_merge_request(fake, { session_id = "marcus", cwd = "/p/c" })
		check("only the decanus's root is poked", vim.inspect(poked) == vim.inspect({ "/p/a" }), poked)
	end)

	test("a decanus's card shows the merge request lines, a faber's card shows none", function()
		local summary = { card_lines = { { segments = { { "!12 open", "ok" } } } } }
		local services = function()
			return {
				merge_request_process = {
					allows = function(role)
						return role == nil or role == "decanus"
					end,
					summary = function()
						return summary
					end,
				},
			}
		end
		local decanus_row = { id = "servius", miles_id = "servius", name = "Servius", root = "/p/a", place = "a", role = "decanus", state = "idle", tone = "off", running = true, word = "idle" }
		local faber_row = { id = "titus", miles_id = "titus", name = "Titus", root = "/p/a", place = "a", role = "faber", state = "idle", tone = "off", running = true, word = "idle" }
		local ok, lines = with_services({ miles_panel.card_lines }, services, function()
			return { decanus = miles_panel.card_lines(decanus_row), faber = miles_panel.card_lines(faber_row) }
		end)
		check("both cards build", ok, lines)
		if not ok then
			return
		end
		local function has_mr(card)
			for _, line in ipairs(card) do
				if type(line) == "table" and line.segments and line.segments[1][1] == "!12 open" then
					return true
				end
			end
			return false
		end
		check("the decanus's card shows the merge request", has_mr(lines.decanus), lines.decanus)
		check("the faber's card shows no merge request even though his root has one", not has_mr(lines.faber), lines.faber)
	end)

	for _, role in ipairs(NON_DECANUS) do
		test("open merge request on a " .. role .. " is refused and opens nothing", function()
			local action
			for _, a in ipairs(board.actions) do
				if a[3] == "open a merge request for a miles" then
					action = a
				end
			end
			check("the open merge request action exists", action ~= nil)
			if not action then
				return
			end
			local opened = {}
			local original_open = vim.ui.open
			vim.ui.open = function(url)
				table.insert(opened, url)
			end
			local services = function()
				return {
					merge_request_process = {
						allows = function(role)
							return role == nil or role == "decanus"
						end,
						url_of = function()
							return "https://gitlab.example/mr/1"
						end,
					},
				}
			end
			local e = { component = miles_panel, id = role, miles_id = role, name = role, root = "/p/x", cwd = "/p/x", role = role, running = true }
			local ok, notes = with_services({ action[2] }, services, function()
				return notes_during(function()
					action[2](e, { batch = false, confirm = function() return true end }, nil)
				end)
			end)
			vim.ui.open = original_open
			check("the refusal runs without error", ok, notes)
			local said = false
			for _, n in ipairs(notes or {}) do
				if type(n[1]) == "string" and n[1]:find("only the decanus has one", 1, true) then
					said = true
				end
			end
			check("the refusal says only the decanus has one", said, notes)
			check("nothing is opened", #opened == 0, opened)
		end)
	end

	test("open merge request on a decanus with a merge request opens his url", function()
		local action
		for _, a in ipairs(board.actions) do
			if a[3] == "open a merge request for a miles" then
				action = a
			end
		end
		check("the open merge request action exists", action ~= nil)
		if not action then
			return
		end
		local opened = {}
		local original_open = vim.ui.open
		vim.ui.open = function(url)
			table.insert(opened, url)
		end
		local services = function()
			return {
				merge_request_process = {
					allows = function(role)
						return role == nil or role == "decanus"
					end,
					url_of = function()
						return "https://gitlab.example/mr/1"
					end,
				},
			}
		end
		local e = { component = miles_panel, id = "servius", miles_id = "servius", name = "Servius", root = "/p/a", cwd = "/p/a", role = "decanus", running = true }
		local ok, err = with_services({ action[2] }, services, function()
			action[2](e, { batch = false, confirm = function() return true end }, nil)
		end)
		vim.ui.open = original_open
		check("the open runs without error", ok, err)
		check("the decanus's url is opened", vim.inspect(opened) == vim.inspect({ "https://gitlab.example/mr/1" }), opened)
	end)

	test("a running miles with the legacy role 'pilus prior' gets the same rank entry as 'primus pilus'", function()
		local miles_view_mapper = require("workspace.legio.presentation.mappers.miles_view_mapper")
		local function row_for(role)
			return miles_view_mapper.to_miles_row({ id = "titus", name = "Titus", root = "/p", state = "idle", busy = false, running = true, legio = "x", role = role, standing = { rank = "triarius", level = 3, done = 5, needed = 10, unit = "mandata" } })
		end
		local legacy, current = row_for("pilus prior"), row_for("primus pilus")
		check("the legacy role is a leader like the primus pilus", legacy.leader == true and current.leader == true, { legacy.leader, current.leader })
		check("the legacy role gets the same mark", legacy.mark == current.mark and current.mark == "★ ", { legacy.mark, current.mark })
		check("the legacy role gets the same bar and indent", legacy.bar == current.bar and legacy.indent == current.indent, { legacy.bar, current.bar, legacy.indent, current.indent })
		local legacy_card = miles_view_mapper.to_card_lines(legacy)
		local current_card = miles_view_mapper.to_card_lines(current)
		local function text(line)
			if type(line) == "string" then
				return line
			end
			local out = {}
			for _, seg in ipairs(line.segments or {}) do
				table.insert(out, seg[1])
			end
			return table.concat(out)
		end
		check("the legacy card reads the same as the primus pilus card", text(legacy_card[1]) == text(current_card[1]) and text(legacy_card[1]) == "★ Titus", { text(legacy_card[1]), text(current_card[1]) })
	end)

end

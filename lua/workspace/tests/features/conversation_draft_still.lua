local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")

local APP = "workspace.workbench.presentation.nvim.app"
local PANE = "workspace.conversations.presentation.nvim.conversation_pane"
local TRANSCRIPT_REPO = "workspace.conversations.infrastructure.outbound.filesystem.transcript_repository"

local function legacy_pane()
	local path = package.searchpath((PANE:gsub("%.", "/")), package.path)
	local f = path and io.open(path)
	if not f then
		return false
	end
	local src = f:read("*a")
	f:close()
	return src:find("transcript_repository", 1, true) ~= nil
end

local function transcript(id, count)
	local turns = {}
	for i = 1, count do
		local reply = {}
		for line = 1, 60 do
			reply[line] = ("turn %d reply line %d"):format(i, line)
		end
		turns[i] = { prompt = "question " .. i, reply = reply }
	end
	if legacy_pane() then
		local Transcript = require("workspace.conversations.domain.transcript")
		local records = {}
		for i = 1, count do
			table.insert(records, { k = "p", t = "question " .. i })
			for _, line in ipairs(turns[i].reply) do
				table.insert(records, { k = "x", t = line })
			end
		end
		return Transcript.new(id, records)
	end
	return { id = id, count = count, turns = turns }
end

local function harness()
	local fx = { screen = ConversationScreen:new({ id = "w" }), agents = {}, transcripts = {}, sent = {} }
	local services = {
		roster = {
			get = function(_, id)
				return fx.agents[id]
			end,
			running_in = function()
				return {}
			end,
			awaiting_turn = function()
				return nil
			end,
		},
		miles_runner = {
			mark_read = function() end,
			watch_agentd = function() end,
			release = function() end,
			interrupt = function() end,
			deliver = function(_, command, done)
				table.insert(fx.sent, command)
				done(true, "sent")
			end,
		},
		conversation_transcript = {
			get = function(_, id)
				return fx.transcripts[id]
			end,
			received = function()
				return nil
			end,
			seen_through = function()
				return 0
			end,
		},
		inquiry = {
			next_for = function()
				return nil
			end,
			can_surface = function()
				return true
			end,
			claim = function() end,
		},
		review_process = setmetatable({
			prompt_parts = function()
				return nil
			end,
		}, {
			__index = function()
				return function()
					return {}
				end
			end,
		}),
		drafting = {
			key = function(_, target)
				return target.agent
			end,
			file = function(_, target)
				return fx.draft_file or vim.fn.tempname()
			end,
			write = function() end,
			load = function()
				return ""
			end,
			starts_session = function()
				return false
			end,
			outgoing = function(_, command)
				return { target = { agent = command.agent or "a4", name = "a4" }, message = "hi" }
			end,
			discard = function() end,
		},
	}
	local app = {
		workspace = "w",
		pane = nil,
		state = function()
			return { log = { warn = function() end } }
		end,
		services = function()
			return services
		end,
		screen = function()
			return fx.screen
		end,
		update_screen = function(_, fn)
			return fn(fx.screen)
		end,
		on = function() end,
		paths = {
			draft = function()
				return vim.fn.tempname()
			end,
			images = vim.fn.tempname(),
		},
		store = function()
			return { all = function() return {} end, update = function() end, get = function() return nil end }
		end,
		now = function()
			return 100
		end,
		workspace_model = function()
			return nil
		end,
		folder = function()
			return "/p"
		end,
		main_window = function()
			return vim.api.nvim_get_current_win()
		end,
		focus = function() end,
	}
	fx.app = app
	return fx
end

local function with_pane(fx, body)
	local saved_app, saved_pane = package.loaded[APP], package.loaded[PANE]
	local saved_repo = package.loaded[TRANSCRIPT_REPO]
	package.loaded[APP] = fx.app
	package.loaded[PANE] = nil
	package.loaded[TRANSCRIPT_REPO] = {
		get = function(id)
			return fx.transcripts[id]
		end,
		reload = function() end,
		path = function() return nil end,
	}
	local ok, err = pcall(function()
		body(require(PANE))
	end)
	package.loaded[APP], package.loaded[PANE] = saved_app, saved_pane
	package.loaded[TRANSCRIPT_REPO] = saved_repo
	if not ok then
		error(err, 0)
	end
end

local function text(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function type_draft(win, lines, cursor)
	local buf = vim.api.nvim_win_get_buf(win)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_win_set_cursor(win, cursor)
	return buf
end

local function drawn(win)
	vim.cmd("redraw!")
	local pos = vim.fn.win_screenpos(win)
	local rows = {}
	for r = 0, vim.api.nvim_win_get_height(win) - 1 do
		local cells = {}
		for c = 0, vim.api.nvim_win_get_width(win) - 1 do
			table.insert(cells, vim.fn.screenstring(pos[1] + r, pos[2] + c))
		end
		table.insert(rows, table.concat(cells))
	end
	return rows
end

local function view(win)
	return vim.api.nvim_win_call(win, function()
		return vim.fn.winsaveview()
	end)
end

local function with_review(body)
	local name = "workspace.workflow.presentation.nvim.review_marks"
	local saved = package.loaded[name]
	package.loaded[name] = { drafts_for = function() return {} end, send = function() end, prompt = function() end }
	local ok, err = pcall(body)
	package.loaded[name] = saved
	if not ok then
		error(err, 0)
	end
end

local function open_draft(fx, pane, id)
	fx.agents[id] = { id = id, name = id, root = "/p" }
	fx.transcripts[id] = transcript(id, 3)
	fx.screen:select(id)
	pane.open()
	local win = pane.window()
	vim.api.nvim_win_call(win, function()
		vim.cmd("normal! G")
	end)
	fx.screen:compose({ agent = id, name = id })
	pane.render()
	return win
end

return function(t)
	local test, check = t.test, t.check

	local function arrive(fx, pane, id, count)
		fx.transcripts[id] = transcript(id, count)
		fx.app.update_screen(ConversationScreen, function(v)
			return v:follow_item({ id = id, name = id, cwd = "/p" }, { turn = count }, true)
		end)
		pane.render()
	end

	test("a draft at the bottom, in insert mode: an incoming message through follow_item leaves the draft, cursor and view put", function()
		vim.cmd("only")
		local fx = harness()
		with_pane(fx, function(pane)
			local win = open_draft(fx, pane, "a4")
			local buf = type_draft(win, { "my draft", "second line", "third line" }, { 3, 4 })
			vim.cmd("startinsert")
			local before = view(win)
			local cursor = vim.api.nvim_win_get_cursor(win)
			arrive(fx, pane, "a4", 4)
			vim.cmd("redraw")
			check("still the same draft buffer", vim.api.nvim_win_get_buf(win) == buf)
			check("the draft text is unchanged", text(buf) == "my draft\nsecond line\nthird line", text(buf))
			check("the cursor is still on the last draft line", vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor), { cursor = cursor, now = vim.api.nvim_win_get_cursor(win) })
			check("the visible lines are unchanged", vim.deep_equal(view(win), before), { before = before, now = view(win) })
			check("the screen is still drafting", fx.screen.state == "draft", fx.screen.state)
		end)
	end)

	test("a draft at the bottom: the drawn draft has no transcript characters at its left edge after a message arrives", function()
		vim.cmd("only")
		local fx = harness()
		with_pane(fx, function(pane)
			local win = open_draft(fx, pane, "a5")
			type_draft(win, { "my draft", "second line" }, { 2, 0 })
			arrive(fx, pane, "a5", 4)
			local rows = drawn(win)
			local gutter = vim.fn.getwininfo(win)[1].textoff
			check("the gutter is measured", gutter > 0, gutter)
			check("row 1 is the winbar and is blank", rows[1]:match("^%s*$") ~= nil, rows[1])
			local function row_of(text)
				for r, row in ipairs(rows) do
					if row:sub(gutter + 1, gutter + #text) == text then
						return r
					end
				end
			end
			local first, second = row_of("my draft"), row_of("second line")
			check("the first draft line is drawn after the gutter", first ~= nil, rows)
			check("the second draft line is drawn on the row below it", first ~= nil and second == first + 1, { first = first, second = second })
			for r = 1, #rows do
				check("row " .. r .. " has nothing in the gutter", rows[r]:sub(1, gutter):match("^%s*$") ~= nil, rows[r])
			end
			for r = (second or 0) + 1, #rows do
				check("row " .. r .. " below the draft has no transcript text", rows[r]:sub(gutter + 1):match("^%s*$") ~= nil, rows[r])
			end
			for _, row in ipairs(rows) do
				check("no transcript text anywhere in the draft window", not row:find("turn", 1, true) and not row:find("question", 1, true), row)
			end
		end)
	end)

	test("a draft's screen row and topline hold when a message arrives through the real path", function()
		vim.cmd("only")
		local fx = harness()
		with_pane(fx, function(pane)
			local win = open_draft(fx, pane, "a8")
			type_draft(win, { "my draft", "second line", "third line" }, { 3, 4 })
			vim.cmd("startinsert")
			vim.cmd("redraw")
			local function place()
				return vim.api.nvim_win_call(win, function()
					return { row = vim.fn.winline(), top = vim.fn.line("w0") }
				end)
			end
			local before, cursor = place(), vim.api.nvim_win_get_cursor(win)
			arrive(fx, pane, "a8", 4)
			vim.cmd("redraw")
			local after = place()
			check("the draft's screen row holds", after.row == before.row, { before = before, after = after })
			check("the cursor holds", vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor), { cursor = cursor, now = vim.api.nvim_win_get_cursor(win) })
		end)
	end)

	test("sending a draft after a message arrived moves the view to the new message", function()
		vim.cmd("only")
		local fx = harness()
		with_pane(fx, function(pane)
			local win = open_draft(fx, pane, "a6")
			type_draft(win, { "my draft" }, { 1, 0 })
			fx.transcripts.a6 = transcript("a6", 4)
			pane.render()
			with_review(function()
				vim.cmd("stopinsert")
				vim.api.nvim_feedkeys(vim.keycode("<C-s>"), "x", false)
				vim.wait(100, function()
					return false
				end)
			end)
			vim.wait(100, function()
				return false
			end)
			pane.render()
			local buf = vim.api.nvim_win_get_buf(win)
			check("the view moved to turn 4", text(buf):find("question 4", 1, true) ~= nil)
			check("no indicator once I'm on the latest turn", vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" }) == " ")
		end)
	end)

	test("closing a draft after a message arrived moves the view to the new message", function()
		vim.cmd("only")
		local fx = harness()
		with_pane(fx, function(pane)
			local win = open_draft(fx, pane, "a7")
			type_draft(win, { "my draft" }, { 1, 0 })
			fx.transcripts.a7 = transcript("a7", 4)
			pane.render()
			vim.cmd("stopinsert")
			vim.api.nvim_feedkeys("q", "x", false)
			vim.wait(100, function()
				return false
			end)
			pane.render()
			local buf = vim.api.nvim_win_get_buf(win)
			check("the draft is closed", fx.screen.state ~= "draft", fx.screen.state)
			check("the view moved to turn 4", text(buf):find("question 4", 1, true) ~= nil)
		end)
	end)
end

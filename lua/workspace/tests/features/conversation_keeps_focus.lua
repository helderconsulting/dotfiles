local pane_harness = require("workspace.tests.support.pane_harness")
local ConversationScreen = pane_harness.ConversationScreen
local transcript = pane_harness.transcript
local harness = pane_harness.harness
local with_pane = pane_harness.with_pane
local text = pane_harness.text
local open_draft = pane_harness.open_draft
local view = pane_harness.view

local WAITING = " ↓ new message below"
local LEGIO_PANEL = "workspace.legio.presentation.nvim.legio_panel"
local MILES_PANEL = "workspace.legio.presentation.nvim.miles_panel"
local PANE = "workspace.conversations.presentation.nvim.conversation_pane"

local function reset()
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(w).relative ~= "" then
			pcall(vim.api.nvim_win_close, w, true)
		end
	end
	vim.cmd("only")
end

local function unfocus()
	vim.cmd("botright new")
	return vim.api.nvim_get_current_win()
end

local function arrive(fx, pane, id, count)
	fx.transcripts[id] = transcript(id, count)
	fx.app.update_screen(ConversationScreen, function(v)
		return v:follow_item({ id = id, name = id, cwd = "/p" }, { turn = count }, true)
	end)
	pane.render()
end

local function winbar(win)
	return vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })
end

local function reading_latest(fx, pane, id)
	fx.agents[id] = { id = id, name = id, root = "/p" }
	fx.transcripts[id] = transcript(id, 3)
	fx.screen:select(id)
	pane.open()
	local win = pane.window()
	vim.api.nvim_exec_autocmds("FocusGained", {})
	vim.cmd("botright new")
	local other = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(win)
	vim.api.nvim_win_call(win, function()
		vim.cmd("normal! G")
	end)
	return win, other
end

return function(t)
	local test, check = t.test, t.check

	test("reading the latest answer, window focused and not scrolled up: a decanus's report keeps me on the answer I'm reading", function()
		reset()
		local fx = harness()
		with_pane(fx, function(pane)
			local win = reading_latest(fx, pane, "c1")
			local shown = vim.api.nvim_win_get_buf(win)
			check("I start on question 3", text(shown):find("question 3", 1, true) ~= nil)
			arrive(fx, pane, "c1", 4)
			check("the pane stays on question 3", vim.api.nvim_win_get_buf(win) == shown and text(shown):find("question 4", 1, true) == nil, text(vim.api.nvim_win_get_buf(win)):sub(1, 60))
			check("the winbar says a message is below", winbar(win) == WAITING, winbar(win))
		end)
	end)

	test("a comment draft (<leader>ra) open: an incoming turn doesn't replace the draft buffer", function()
		reset()
		local fx = harness()
		with_pane(fx, function(pane)
			local win = reading_latest(fx, pane, "c2")
			vim.api.nvim_win_set_cursor(win, { 1, 0 })
			require("workspace.workflow.presentation.nvim.review_marks").add(1, 1)
			local draft_win = vim.api.nvim_get_current_win()
			local draft_buf = vim.api.nvim_win_get_buf(draft_win)
			check("the comment draft is open", draft_win ~= win and vim.api.nvim_buf_is_valid(draft_buf), draft_win)
			arrive(fx, pane, "c2", 4)
			check("the comment draft is still the same buffer", vim.api.nvim_win_is_valid(draft_win) and vim.api.nvim_win_get_buf(draft_win) == draft_buf)
			check("the answer under the draft still shows question 3", text(vim.api.nvim_win_get_buf(win)):find("question 3", 1, true) ~= nil and text(vim.api.nvim_win_get_buf(win)):find("question 4", 1, true) == nil)
		end)
	end)

	test("a message draft (<leader>m) open: an incoming turn doesn't replace the draft buffer", function()
		reset()
		local fx = harness()
		with_pane(fx, function(pane)
			local win = reading_latest(fx, pane, "c3")
			local draft = open_draft(fx, pane, "c3")
			local draft_buf = vim.api.nvim_win_get_buf(win)
			arrive(fx, pane, "c3", 4)
			check("the message draft is still the same buffer", vim.api.nvim_win_get_buf(win) == draft_buf)
			check("the screen is still drafting", fx.screen.state == "draft", fx.screen.state)
		end)
	end)

	test("the cursor moved in the last minute, window not focused: an incoming turn holds", function()
		reset()
		local fx = harness()
		with_pane(fx, function(pane)
			local win, other = reading_latest(fx, pane, "c4")
			fx.now = 100
			vim.api.nvim_win_call(win, function()
				vim.cmd("normal! G")
			end)
			vim.api.nvim_exec_autocmds("CursorMoved", {})
			vim.api.nvim_set_current_win(other)
			fx.now = 130
			local shown = vim.api.nvim_win_get_buf(win)
			arrive(fx, pane, "c4", 4)
			check("the pane holds on question 3 for a minute after the cursor moved", vim.api.nvim_win_get_buf(win) == shown and text(shown):find("question 4", 1, true) == nil)
			check("the winbar says a message is below", winbar(win) == WAITING, winbar(win))
		end)
	end)

	test("the cursor last moved over a minute ago, window not focused: an incoming turn is followed", function()
		reset()
		local fx = harness()
		with_pane(fx, function(pane)
			local win, other = reading_latest(fx, pane, "c5")
			fx.now = 100
			vim.api.nvim_win_call(win, function()
				vim.cmd("normal! G")
			end)
			vim.api.nvim_exec_autocmds("CursorMoved", {})
			vim.api.nvim_set_current_win(other)
			fx.now = 170
			arrive(fx, pane, "c5", 4)
			check("the pane follows to question 4 after the minute", text(vim.api.nvim_win_get_buf(win)):find("question 4", 1, true) ~= nil, { winbar = winbar(win), cur = vim.api.nvim_get_current_win(), win = win, other = other, first = text(vim.api.nvim_win_get_buf(win)):sub(1, 40) })
		end)
	end)

	test("the commander reads the centurio from the legio hierarchy: a new turn for that miles and pane.render only keeps the answer I'm reading", function()
		reset()
		local fx = harness()
		local saved = package.loaded[LEGIO_PANEL]
		package.loaded[LEGIO_PANEL] = nil
		with_pane(fx, function(pane)
			local win = reading_latest(fx, pane, "c7")
			local legio_panel = require(LEGIO_PANEL)
			local select = legio_panel.show_conversation_on_select or function(e)
				fx.app.update_screen(ConversationScreen, function(v)
					return v:select(e.miles_id)
				end)
			end
			select({ miles_id = "c7" })
			check("the centurio is the selected conversation", fx.screen.agent == "c7", fx.screen.agent)
			local shown = vim.api.nvim_win_get_buf(win)
			local cursor, before = vim.api.nvim_win_get_cursor(win), view(win)
			fx.transcripts.c7 = transcript("c7", 4)
			pane.render()
			check("the window still shows question 3", vim.api.nvim_win_get_buf(win) == shown and text(shown):find("question 4", 1, true) == nil)
			check("the winbar says a message is below", winbar(win) == WAITING, winbar(win))
			check("the cursor is unchanged", vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor), { cursor = cursor, now = vim.api.nvim_win_get_cursor(win) })
			check("the view is unchanged", vim.deep_equal(view(win), before), { before = before, now = view(win) })
		end)
		package.loaded[LEGIO_PANEL] = saved
	end)

	local function with_miles_panel(fx, body)
		local saved = package.loaded[MILES_PANEL]
		package.loaded[MILES_PANEL] = nil
		local ok, err = pcall(function()
			with_pane(fx, function(pane)
				body(pane, require(MILES_PANEL))
			end)
		end)
		package.loaded[MILES_PANEL] = saved
		if not ok then
			error(err, 0)
		end
	end

	test("a decanus's report arrives through the panel while the centurio's answer is scrolled up and unattended: the view holds", function()
		reset()
		local fx = harness()
		with_miles_panel(fx, function(pane, miles_panel)
			local win = reading_latest(fx, pane, "c9")
			unfocus()
			vim.api.nvim_win_call(win, function()
				vim.cmd("normal! gg")
			end)
			fx.now = 100
			fx.transcripts.d9 = transcript("d9", 2)
			local shown = vim.api.nvim_win_get_buf(win)
			local cursor, before = vim.api.nvim_win_get_cursor(win), view(win)
			fx.now = 200
			miles_panel.show_conversation_on_select({ id = "d9", name = "d9", cwd = "/p" }, { turn = 2 }, { incoming = true })
			pane.render()
			check("the centurio's answer is still shown", vim.api.nvim_win_get_buf(win) == shown and text(shown):find("question 3", 1, true) ~= nil)
			check("the screen still belongs to the centurio", fx.screen.agent == "c9", fx.screen.agent)
			check("the view and cursor are unchanged on the same buffer", vim.api.nvim_win_get_buf(win) == shown and vim.deep_equal(view(win), before) and vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor), { before = before, now = view(win) })
		end)
	end)

	test("a draft closed while I read an older turn, then focused: an incoming turn holds, and moving to the latest follows", function()
		reset()
		local fx = harness()
		with_miles_panel(fx, function(pane, miles_panel)
			fx.agents.c8 = { id = "c8", name = "c8", root = "/p" }
			fx.transcripts.c8 = transcript("c8", 3)
			fx.screen:select("c8", 2)
			pane.open()
			local win = pane.window()
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_exec_autocmds("FocusGained", {})
			pane.render()
			check("I start on question 2", text(vim.api.nvim_win_get_buf(win)):find("question 2", 1, true) ~= nil)
			fx.screen:compose({ agent = "c8", name = "c8" })
			pane.render()
			vim.cmd("stopinsert")
			vim.api.nvim_feedkeys("q", "x", false)
			vim.wait(100, function()
				return false
			end)
			check("the draft is closed", fx.screen.state ~= "draft", fx.screen.state)
			check("I'm still on question 2", fx.screen.turn == 2, fx.screen.turn)
			vim.api.nvim_set_current_win(win)
			pane.render()
			fx.transcripts.c8 = transcript("c8", 4)
			miles_panel.show_conversation_on_select({ id = "c8", name = "c8", cwd = "/p" }, { turn = 4 }, { incoming = true })
			pane.render()
			check("the incoming turn holds on question 2", text(vim.api.nvim_win_get_buf(win)):find("question 2", 1, true) ~= nil and text(vim.api.nvim_win_get_buf(win)):find("question 4", 1, true) == nil)
			fx.app.update_screen(ConversationScreen, function(v)
				return v:select("c8")
			end)
			pane.render()
			check("moving to the latest follows to question 4", text(vim.api.nvim_win_get_buf(win)):find("question 4", 1, true) ~= nil)
		end)
	end)

	test("a draft shown, then the window switched to another buffer: an incoming turn follows once the draft is gone", function()
		reset()
		local fx = harness()
		with_pane(fx, function(pane)
			local win = open_draft(fx, pane, "c10")
			local other = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_win_set_buf(win, other)
			vim.wait(200, function()
				return false
			end)
			check("the draft is no longer on screen", fx.screen.state ~= "draft", fx.screen.state)
			check("the answer is drawn after the draft is finished, without a second render", text(vim.api.nvim_win_get_buf(win)):find("question 3", 1, true) ~= nil)
			unfocus()
			fx.now = 100
			fx.transcripts.c10 = transcript("c10", 4)
			pane.render()
			fx.now = 300
			fx.app.update_screen(ConversationScreen, function(v)
				return v:follow_item({ id = "c10", name = "c10", cwd = "/p" }, { turn = 4 }, true)
			end)
			pane.render()
			check("the incoming turn eventually shows question 4", text(vim.api.nvim_win_get_buf(win)):find("question 4", 1, true) ~= nil)
		end)
	end)
end

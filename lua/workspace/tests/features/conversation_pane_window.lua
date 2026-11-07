local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")

local APP = "workspace.workbench.presentation.nvim.app"
local PANE = "workspace.conversations.presentation.nvim.conversation_pane"
local WAITING = " ↓ new message below"
local clock = 100

local function transcript(id, count)
	local turns = {}
	for i = 1, count do
		local reply = {}
		for line = 1, 60 do
			reply[line] = ("turn %d reply line %d"):format(i, line)
		end
		turns[i] = { prompt = "question " .. i, reply = reply }
	end
	return { id = id, count = count, turns = turns }
end

local function harness()
	local fx = { screen = ConversationScreen:new({ id = "w" }), agents = {}, transcripts = {} }
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
		review_process = {
			prompt_parts = function()
				return nil
			end,
		},
		drafting = {
			key = function(_, target)
				return target.agent
			end,
			file = function()
				return vim.fn.tempname()
			end,
			write = function() end,
			load = function()
				return ""
			end,
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
		now = function()
			return clock
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

local function with_pane(app, body)
	local saved_app, saved_pane = package.loaded[APP], package.loaded[PANE]
	package.loaded[APP] = app
	package.loaded[PANE] = nil
	local ok, err = pcall(function()
		body(require(PANE))
	end)
	package.loaded[APP], package.loaded[PANE] = saved_app, saved_pane
	if not ok then
		error(err, 0)
	end
end

local function winbar(win)
	return vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })
end

local function text(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

return function(t)
	local test, check = t.test, t.check

	test("scrolled up on the latest turn, a new turn arrives: the view holds and the winbar says a message is below", function()
		vim.cmd("only")
		local fx = harness()
		fx.agents.a1 = { id = "a1", name = "a1", root = "/p" }
		fx.transcripts.a1 = transcript("a1", 3)
		fx.screen:select("a1")
		with_pane(fx.app, function(pane)
			pane.open()
			local win = pane.window()
			local shown = vim.api.nvim_win_get_buf(win)
			check("turn 3 is on screen", text(shown):find("question 3", 1, true) ~= nil)
			vim.api.nvim_win_call(win, function()
				vim.cmd("normal! gg")
			end)
			fx.transcripts.a1 = transcript("a1", 4)
			pane.render()
			check("the buffer stays on turn 3 while I read it", vim.api.nvim_win_get_buf(win) == shown)
			check("the winbar says a message is below", winbar(win) == WAITING, winbar(win))
		end)
	end)

	test("at the bottom of the latest turn, a new turn arrives: the view switches to it and the indicator clears", function()
		vim.cmd("only")
		clock = 100
		local fx = harness()
		fx.agents.a2 = { id = "a2", name = "a2", root = "/p" }
		fx.transcripts.a2 = transcript("a2", 3)
		fx.screen:select("a2")
		with_pane(fx.app, function(pane)
			pane.open()
			local win = pane.window()
			vim.api.nvim_win_call(win, function()
				vim.cmd("normal! G")
			end)
			vim.cmd("botright new")
			clock = 200
			fx.transcripts.a2 = transcript("a2", 4)
			pane.render()
			local buf = vim.api.nvim_win_get_buf(win)
			check("the view switched to turn 4", text(buf):find("question 4", 1, true) ~= nil)
			check("no indicator once I'm on the latest turn", winbar(win) == " ", winbar(win))
		end)
	end)

	test("while I type a draft, a new turn arrives: the draft buffer and winbar are untouched", function()
		vim.cmd("only")
		local fx = harness()
		fx.agents.a3 = { id = "a3", name = "a3", root = "/p" }
		fx.transcripts.a3 = transcript("a3", 3)
		fx.screen:select("a3")
		with_pane(fx.app, function(pane)
			pane.open()
			local win = pane.window()
			fx.screen:compose({ agent = "a3", name = "a3" })
			pane.render()
			local draft = vim.api.nvim_win_get_buf(win)
			local before = winbar(win)
			fx.transcripts.a3 = transcript("a3", 4)
			pane.render()
			check("still the same draft buffer", vim.api.nvim_win_get_buf(win) == draft)
			check("the winbar is unchanged", winbar(win) == before, winbar(win))
			check("the screen is still drafting", fx.screen.state == "draft")
		end)
	end)
end

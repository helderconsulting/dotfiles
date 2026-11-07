local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")
local pane_harness = require("workspace.tests.support.pane_harness")
local harness = pane_harness.harness
local with_pane = pane_harness.with_pane
local transcript = pane_harness.transcript
local text = pane_harness.text

local APP = "workspace.workbench.presentation.nvim.app"
local MILES_PANEL = "workspace.legio.presentation.nvim.miles_panel"

return function(t)
	local test, check = t.test, t.check

	local function routed(store, fx)
		fx.app.screen = function(cls)
			return store:get(cls, "w") or cls:new({ id = "w" })
		end
		fx.app.update_screen = function(cls, fn)
			return store:update(cls, "w", fn)
		end
		return fx.app
	end

	local function stored(root)
		return t.make_store(root):get(ConversationScreen, "w")
	end

	local function with_panel(app, body)
		local saved_app, saved_panel = package.loaded[APP], package.loaded[MILES_PANEL]
		package.loaded[APP] = app
		package.loaded[MILES_PANEL] = nil
		local ok, err = pcall(function()
			body(require(MILES_PANEL))
		end)
		package.loaded[APP], package.loaded[MILES_PANEL] = saved_app, saved_panel
		if not ok then
			error(err, 0)
		end
	end

	local function unfocus()
		vim.cmd("botright new")
		return vim.api.nvim_get_current_win()
	end

	local function reset()
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_config(w).relative ~= "" then
				pcall(vim.api.nvim_win_close, w, true)
			end
		end
		vim.cmd("only")
	end

	local function pane_shows_c15(root, fx, setup)
		local store = t.make_store(root)
		local app = routed(store, fx)
		fx.app = app
		fx.transcripts.c15 = transcript("c15", 3)
		app.update_screen(ConversationScreen, function(v)
			return v:select("c15")
		end)
		with_pane(fx, function(pane)
			pane.open()
			local win = pane.window()
			vim.api.nvim_exec_autocmds("FocusGained", {})
			setup(win, pane)
			pane.render()
			fx.pane_win = win
		end)
		if fx.pane_win and vim.api.nvim_win_is_valid(fx.pane_win) then
			vim.api.nvim_win_close(fx.pane_win, true)
		end
	end

	local function panel_incoming(root, fx)
		local store = t.make_store(root)
		local app = routed(store, fx)
		fx.transcripts.d15 = transcript("d15", 2)
		with_panel(app, function(miles_panel)
			miles_panel.show_conversation_on_select({ id = "d15", name = "d15", cwd = "/p" }, { turn = 2 }, { incoming = true })
		end)
		return stored(root)
	end

	test("across processes: the centurio's view is focused in the pane, a decanus's report on the panel path holds", function()
		reset()
		local fx = harness()
		local root = vim.fn.tempname()
		fx.now = 100
		ConversationScreen.clock = function()
			return fx.now
		end
		pane_shows_c15(root, fx, function(win)
			vim.api.nvim_set_current_win(win)
		end)
		reset()
		fx.now = 130
		local after = panel_incoming(root, fx)
		check("the stored screen still belongs to the centurio", after ~= nil and after.agent == "c15", after and after.agent)
		vim.fn.delete(root, "rf")
	end)

	test("across processes: the centurio's view is scrolled up and unattended in the pane, a decanus's report on the panel path holds", function()
		reset()
		local fx = harness()
		local root = vim.fn.tempname()
		fx.now = 100
		ConversationScreen.clock = function()
			return fx.now
		end
		pane_shows_c15(root, fx, function(win)
			unfocus()
			vim.api.nvim_win_call(win, function()
				vim.cmd("normal! gg")
			end)
		end)
		reset()
		fx.now = 300
		local after = panel_incoming(root, fx)
		check("the stored screen still belongs to the centurio", after ~= nil and after.agent == "c15", after and after.agent)
		vim.fn.delete(root, "rf")
	end)

	test("across processes: the centurio's view is unattended and at the bottom, a decanus's report on the panel path switches", function()
		reset()
		local fx = harness()
		local root = vim.fn.tempname()
		fx.now = 100
		ConversationScreen.clock = function()
			return fx.now
		end
		pane_shows_c15(root, fx, function(win)
			vim.api.nvim_win_call(win, function()
				vim.cmd("normal! G")
			end)
			unfocus()
		end)
		reset()
		fx.now = 300
		local after = panel_incoming(root, fx)
		check("the stored screen moves to the decanus", after ~= nil and after.agent == "d15", after and after.agent)
		vim.fn.delete(root, "rf")
	end)

	test("across processes: a draft open in the pane, the window switched to another buffer with no render, finishes the draft", function()
		reset()
		local fx = harness()
		local root = vim.fn.tempname()
		fx.now = 100
		ConversationScreen.clock = function()
			return fx.now
		end
		local store = t.make_store(root)
		fx.app = routed(store, fx)
		fx.transcripts.c15 = transcript("c15", 3)
		fx.agents.c15 = { id = "c15", name = "c15", root = "/p" }
		fx.app.update_screen(ConversationScreen, function(v)
			return v:select("c15")
		end)
		with_pane(fx, function(pane)
			pane.open()
			local win = pane.window()
			vim.api.nvim_set_current_win(win)
			fx.app.update_screen(ConversationScreen, function(v)
				return v:compose({ agent = "c15", name = "c15" })
			end)
			pane.render()
			check("the draft is open in the pane", stored(root).state == "draft", stored(root).state)
			local scratch = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_win_set_buf(win, scratch)
			vim.wait(200, function()
				return false
			end)
			check("the draft is finished after the buffer switch", stored(root).state ~= "draft", stored(root).state)
		end)
		reset()
		vim.fn.delete(root, "rf")
	end)
end

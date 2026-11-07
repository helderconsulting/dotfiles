local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")
local pane_harness = require("workspace.tests.support.pane_harness")
local harness = pane_harness.harness
local with_pane = pane_harness.with_pane
local transcript = pane_harness.transcript
local text = pane_harness.text

local MILES_PANEL = "workspace.legio.presentation.nvim.miles_panel"
local APP = "workspace.workbench.presentation.nvim.app"

return function(t)
	local test, check = t.test, t.check

	local function reset()
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_config(w).relative ~= "" then
				pcall(vim.api.nvim_win_close, w, true)
			end
		end
		vim.cmd("only")
	end

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

	local function setup(id)
		reset()
		local fx = harness()
		local root = vim.fn.tempname()
		fx.now = 100
		ConversationScreen.clock = function()
			return fx.now
		end
		fx.app = routed(t.make_store(root), fx)
		fx.transcripts[id] = transcript(id, 3)
		fx.agents[id] = { id = id, name = id, root = "/p" }
		fx.app.update_screen(ConversationScreen, function(v)
			return v:select(id)
		end)
		return fx, root
	end

	test("B2: a freshly opened pane whose window is current holds for a minute from open, without a focus event", function()
		local fx, root = setup("e1")
		with_pane(fx, function(pane)
			pane.open()
			local win = pane.window()
			vim.api.nvim_set_current_win(win)
			pane.render()
			check("the open holds the view for a minute", stored(root).attended_until == 160, stored(root).attended_until)
			check("it is not published as focused before a focus event", stored(root).focused ~= true, stored(root).focused)
		end)
		reset()
		vim.fn.delete(root, "rf")
	end)

	test("vacate on exit clears the hold: the pane gone, the panel switches to the decanus", function()
		local fx, root = setup("e2")
		with_pane(fx, function(pane)
			pane.open()
			local win = pane.window()
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_exec_autocmds("FocusGained", {})
			pane.render()
			check("the pane held focus while shown", stored(root).focused == true, stored(root).focused)
			vim.api.nvim_exec_autocmds("VimLeavePre", {})
		end)
		reset()
		local before = stored(root)
		check("the owner is cleared on exit", before.owner_pid == nil, before.owner_pid)
		fx.transcripts.d2 = transcript("d2", 2)
		local saved_app, saved = package.loaded[APP], package.loaded[MILES_PANEL]
		package.loaded[APP], package.loaded[MILES_PANEL] = fx.app, nil
		local ok, err = pcall(function()
			require(MILES_PANEL).show_conversation_on_select({ id = "d2", name = "d2", cwd = "/p" }, { turn = 2 }, { incoming = true })
		end)
		package.loaded[APP], package.loaded[MILES_PANEL] = saved_app, saved
		if not ok then
			error(err, 0)
		end
		check("with the pane gone the screen moves to the decanus", stored(root).agent == "d2", stored(root).agent)
		vim.fn.delete(root, "rf")
	end)

	test("FocusLost and FocusGained set the focus fact the pane publishes", function()
		local fx, root = setup("e3")
		with_pane(fx, function(pane)
			pane.open()
			local win = pane.window()
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_exec_autocmds("FocusGained", {})
			pane.render()
			check("gained focus is published", stored(root).focused == true, stored(root).focused)
			vim.api.nvim_exec_autocmds("FocusLost", {})
			pane.render()
			check("lost focus is published", stored(root).focused ~= true, stored(root).focused)
		end)
		reset()
		vim.fn.delete(root, "rf")
	end)

	test("S1: a stuck draft that finishes draws the answer with one render, no second render call", function()
		local fx, root = setup("e4")
		fx.agents.e4 = { id = "e4", name = "e4", root = "/p" }
		with_pane(fx, function(pane)
			pane.open()
			local win = pane.window()
			vim.api.nvim_set_current_win(win)
			fx.app.update_screen(ConversationScreen, function(v)
				return v:compose({ agent = "e4", name = "e4" })
			end)
			pane.render()
			vim.cmd("stopinsert")
			vim.api.nvim_feedkeys("q", "x", false)
			vim.wait(200, function()
				return false
			end)
			check("the draft is finished", stored(root).state ~= "draft", stored(root).state)
			check("the answer is drawn without another render call", text(vim.api.nvim_win_get_buf(win)):find("question 3", 1, true) ~= nil, text(vim.api.nvim_win_get_buf(win)):sub(1, 60))
		end)
		reset()
		vim.fn.delete(root, "rf")
	end)
end

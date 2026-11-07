local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")
local pane_harness = require("workspace.tests.support.pane_harness")
local harness = pane_harness.harness
local with_pane = pane_harness.with_pane
local transcript = pane_harness.transcript

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

	local function to_bottom(win)
		vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)), 0 })
	end

	local function open_in_background(fx, pane)
		local pane_win = vim.api.nvim_get_current_win()
		vim.cmd("botright new")
		fx.app.main_window = function()
			return pane_win
		end
		pane.open()
		to_bottom(pane_win)
		pane.render()
		return pane_win
	end

	test("X1: a fresh pane whose window is current holds for HOLD_SECONDS from open, with no focus event, then stops", function()
		local fx, root = setup("x1")
		with_pane(fx, function(pane)
			pane.open()
			to_bottom(pane.window())
			pane.render()
			check("the open records one move: the hold runs a minute from open", stored(root).attended_until == 160, stored(root).attended_until)
			check("no focus event yet, so the window is not published as focused", stored(root).focused ~= true, stored(root).focused)
			fx.now = 150
			check("50 seconds after open an incoming turn is held", stored(root):holds_view("x1", 4) == true)
			fx.now = 200
			check("after HOLD_SECONDS with no moves the hold stops", stored(root):holds_view("x1", 4) == false)
		end)
		reset()
		vim.fn.delete(root, "rf")
	end)

	test("X1: after an explicit FocusLost a cursor move does not hold the view", function()
		local fx, root = setup("x2")
		with_pane(fx, function(pane)
			open_in_background(fx, pane)
			vim.api.nvim_exec_autocmds("FocusLost", {})
			local win = pane.window()
			vim.api.nvim_set_current_win(win)
			fx.now = 100
			vim.api.nvim_exec_autocmds("CursorMoved", {})
			check("a move after FocusLost records nothing", stored(root).attended_until == nil, stored(root).attended_until)
			check("a move after FocusLost does not hold an incoming turn", stored(root):holds_view("x2", 4) == false)
		end)
		reset()
		vim.fn.delete(root, "rf")
	end)

	test("X1: a pane whose window is not current at open holds nothing", function()
		local fx, root = setup("x3")
		with_pane(fx, function(pane)
			open_in_background(fx, pane)
			pane.render()
			check("no move is recorded at open", stored(root).attended_until == nil, stored(root).attended_until)
			check("an incoming turn is not held", stored(root):holds_view("x3", 4) == false)
		end)
		reset()
		vim.fn.delete(root, "rf")
	end)

	test("X1: the pane publishes focused only after FocusGained", function()
		local fx, root = setup("x4")
		with_pane(fx, function(pane)
			pane.open()
			pane.render()
			check("before FocusGained the window is not focused in the record", stored(root).focused ~= true, stored(root).focused)
			vim.api.nvim_exec_autocmds("FocusGained", {})
			pane.render()
			check("after FocusGained the window is focused in the record", stored(root).focused == true, stored(root).focused)
		end)
		reset()
		vim.fn.delete(root, "rf")
	end)
end

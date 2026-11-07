local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")
local pane_harness = require("workspace.tests.support.pane_harness")
local harness = pane_harness.harness
local with_pane = pane_harness.with_pane
local transcript = pane_harness.transcript
local text = pane_harness.text

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

	test("a held view is not attended once the clock is more than a minute past it, even after a backward clock jump", function()
		local s = ConversationScreen:new({ id = "w", agent = "c16" })
		s.owner_pid = vim.fn.getpid()
		s:moved(1000, true)
		check("it is attended right after the cursor moved", s:is_attended(1000) == true, { until_at = s.attended_until })
		check("it is not attended at a clock reading that is far past the hold", s:is_attended(200) == false, { until_at = s.attended_until })
	end)

	test("a pane that has exited leaves no stale focus in the stored screen", function()
		reset()
		local fx = harness()
		local root = vim.fn.tempname()
		fx.now = 100
		ConversationScreen.clock = function()
			return fx.now
		end
		local store = t.make_store(root)
		fx.app = routed(store, fx)
		fx.transcripts.c17 = transcript("c17", 3)
		fx.app.update_screen(ConversationScreen, function(v)
			return v:select("c17")
		end)
		with_pane(fx, function(pane)
			pane.open()
			local win = pane.window()
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_exec_autocmds("FocusGained", {})
			pane.render()
			check("the pane publishes focus while it is shown", stored(root).focused == true, stored(root).focused)
			vim.api.nvim_win_close(win, true)
			fx.app.update_screen(ConversationScreen, function(v)
				v.owner_pid = vim.fn.getpid()
				return v:vacate(true)
			end)
		end)
		reset()
		local after = stored(root)
		check("after the pane is gone the stored screen is not focused", after.focused ~= true, after.focused)
		check("after the pane is gone its owner is cleared", after.owner_pid == nil, after.owner_pid)
		check("after the pane is gone nothing is alive to hold", after:pane_alive() == false)
		vim.fn.delete(root, "rf")
	end)

	test("focus is only taken from FocusGained and FocusLost, not from a window enter", function()
		reset()
		local fx = harness()
		local root = vim.fn.tempname()
		fx.now = 100
		ConversationScreen.clock = function()
			return fx.now
		end
		local store = t.make_store(root)
		fx.app = routed(store, fx)
		fx.transcripts.c18 = transcript("c18", 3)
		fx.app.update_screen(ConversationScreen, function(v)
			return v:select("c18")
		end)
		with_pane(fx, function(pane)
			pane.open()
			local win = pane.window()
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_exec_autocmds("FocusLost", {})
			pane.render()
			check("a lost terminal focus clears focus even on the pane window", stored(root).focused ~= true, stored(root).focused)
			vim.api.nvim_exec_autocmds("WinEnter", {})
			pane.render()
			check("a window enter alone does not restore focus", stored(root).focused ~= true, stored(root).focused)
			vim.api.nvim_exec_autocmds("FocusGained", {})
			pane.render()
			check("a gained terminal focus restores focus on the pane window", stored(root).focused == true, stored(root).focused)
		end)
		reset()
		vim.fn.delete(root, "rf")
	end)

	test("finishing a draft draws the answer in the window without another event", function()
		reset()
		local fx = harness()
		local root = vim.fn.tempname()
		fx.now = 100
		ConversationScreen.clock = function()
			return fx.now
		end
		local store = t.make_store(root)
		fx.app = routed(store, fx)
		fx.transcripts.c19 = transcript("c19", 3)
		fx.agents.c19 = { id = "c19", name = "c19", root = "/p" }
		fx.app.update_screen(ConversationScreen, function(v)
			return v:select("c19")
		end)
		with_pane(fx, function(pane)
			pane.open()
			local win = pane.window()
			vim.api.nvim_set_current_win(win)
			fx.app.update_screen(ConversationScreen, function(v)
				return v:compose({ agent = "c19", name = "c19" })
			end)
			pane.render()
			vim.cmd("stopinsert")
			vim.api.nvim_feedkeys("q", "x", false)
			vim.wait(200, function()
				return false
			end)
			check("the draft is finished", stored(root).state ~= "draft", stored(root).state)
			check("the answer is drawn in the window", text(vim.api.nvim_win_get_buf(win)):find("question 3", 1, true) ~= nil, text(vim.api.nvim_win_get_buf(win)):sub(1, 60))
		end)
		reset()
		vim.fn.delete(root, "rf")
	end)
end

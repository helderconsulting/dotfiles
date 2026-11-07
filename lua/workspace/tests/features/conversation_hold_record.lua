local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")
local pane_harness = require("workspace.tests.support.pane_harness")
local harness = pane_harness.harness
local with_pane = pane_harness.with_pane

local DEAD_PID = 2147483646
local APP = "workspace.workbench.presentation.nvim.app"
local MILES_PANEL = "workspace.legio.presentation.nvim.miles_panel"

return function(t)
	local test, check = t.test, t.check

	local function other()
		return { id = "d", name = "d", cwd = "/p" }
	end

	test("B1: a draft whose owner is dead holds nothing, and an incoming turn from another agent follows", function()
		local v = ConversationScreen:new({ id = "w" })
		v:select("c", 3)
		v:compose({ agent = "c", name = "c" })
		v.owner_pid = DEAD_PID
		check("the draft is open", v.state == "draft", v.state)
		v:follow_item(other(), { turn = 2 }, true)
		check("a dead owner's draft doesn't hold: the screen moves to d", v.agent == "d", v.agent)
	end)

	test("B1: a question whose owner is dead holds nothing, and an incoming turn from another agent follows", function()
		local v = ConversationScreen:new({ id = "w" })
		v:select("c", 3)
		v:show_ask("q1", "c")
		v.owner_pid = DEAD_PID
		v:follow_item(other(), { turn = 2 }, true)
		check("a dead owner's question doesn't hold: the screen moves to d", v.agent == "d" and v.state ~= "ask", { agent = v.agent, state = v.state })
	end)

	test("B1: an entry whose owner is dead holds nothing, and an incoming turn from another agent follows", function()
		local v = ConversationScreen:new({ id = "w" })
		v:select("c", 3)
		v:show_entry("mandatum", "m1")
		v.owner_pid = DEAD_PID
		v:follow_item(other(), { turn = 2 }, true)
		check("a dead owner's entry doesn't hold: the screen moves to d", v.agent == "d" and v.state ~= "entry", { agent = v.agent, state = v.state })
	end)

	test("B1: a history page whose owner is dead holds nothing, and an incoming turn from another agent follows", function()
		local v = ConversationScreen:new({ id = "w" })
		v:select("c", 3)
		v.history = { at = 1 }
		v.owner_pid = DEAD_PID
		v:follow_item(other(), { turn = 2 }, true)
		check("a dead owner's history doesn't hold: the screen moves to d", v.agent == "d" and v.history == nil, { agent = v.agent, history = v.history })
	end)

	test("B1 control: a draft whose owner is alive still holds the incoming turn", function()
		local v = ConversationScreen:new({ id = "w" })
		v:select("c", 3)
		v:compose({ agent = "c", name = "c" })
		v.owner_pid = vim.fn.getpid()
		v:follow_item(other(), { turn = 2 }, true)
		check("a live owner's draft holds: the screen stays on c's draft", v.agent == "c" and v.state == "draft", { agent = v.agent, state = v.state })
	end)

	test("vacate ends an open draft and clears its owner", function()
		local v = ConversationScreen:new({ id = "w" })
		v:select("c", 3)
		v:compose({ agent = "c", name = "c" })
		v.owner_pid = vim.fn.getpid()
		v:vacate(true)
		check("the draft is gone", v.state == "answer" and v.draft == nil, { state = v.state, draft = v.draft })
		check("the owner is cleared", v.owner_pid == nil, v.owner_pid)
	end)

	test("S3: vacate on exit clears only this pane's owner, not another pane's", function()
		local v = ConversationScreen:new({ id = "w" })
		v:select("c", 3)
		v.owner_pid = 1
		v:vacate(true)
		check("another pane's owner is left alone", v.owner_pid == 1, v.owner_pid)
		local mine = ConversationScreen:new({ id = "w" })
		mine.owner_pid = vim.fn.getpid()
		mine:vacate(true)
		check("this pane's own owner is cleared", mine.owner_pid == nil, mine.owner_pid)
	end)

	test("pane_alive is false with no owner and with a dead owner, true with a live one", function()
		local v = ConversationScreen:new({ id = "w" })
		check("no owner: not alive", v:pane_alive() == false)
		v.owner_pid = DEAD_PID
		check("a dead owner: not alive", v:pane_alive() == false)
		v.owner_pid = vim.fn.getpid()
		check("a live owner: alive", v:pane_alive() == true)
	end)

	test("is_attended clamps a far-future attended_until to the hold", function()
		local v = ConversationScreen:new({ id = "w" })
		v.owner_pid = vim.fn.getpid()
		v.attended_until = 100000
		check("a far-future hold does not keep the view attended", v:is_attended(100) == false, v:is_attended(100))
		v.attended_until = 130
		check("a hold inside the minute does", v:is_attended(100) == true)
	end)

	test("observe writes only changed facts and reports whether anything changed", function()
		local v = ConversationScreen:new({ id = "w" })
		local facts = { focused = true, editing = false, scrolled_up = false, shown_agent = "c", shown_turn = 3, waiting = false, owner_pid = vim.fn.getpid() }
		check("the first observe changes the record", v:observe(facts) == true)
		check("the focused fact is stored", v.focused == true and v.shown_turn == 3)
		check("the same facts again change nothing", v:observe(facts) == false)
	end)

	test("moved sets the hold to a minute from the move", function()
		local v = ConversationScreen:new({ id = "w" })
		v:moved(100, false)
		check("the hold runs to a minute after the move", v.attended_until == 160, v.attended_until)
	end)

	test("M2: a backward clock jump shortens the hold that moved() sets", function()
		local v = ConversationScreen:new({ id = "w" })
		v.attended_until = 10000
		v:moved(100, false)
		check("the hold is pulled back to a minute from the new clock", v.attended_until == 160, v.attended_until)
	end)

	test("settle clears a release once and only once", function()
		local v = ConversationScreen:new({ id = "w" })
		v.released = true
		check("the first settle clears it", v:settle() == true and v.released ~= true)
		check("a second settle finds nothing", v:settle() == false)
	end)

	test("M3: one incoming decision on the panel path, not two", function()
		local calls = 0
		local original = ConversationScreen.follow_item
		ConversationScreen.follow_item = function(self, ...)
			calls = calls + 1
			return original(self, ...)
		end
		local fx = harness()
		fx.agents.c20 = { id = "c20", name = "c20", root = "/p" }
		fx.screen:select("c20", 3)
		local saved_app, saved = package.loaded[APP], package.loaded[MILES_PANEL]
		package.loaded[APP], package.loaded[MILES_PANEL] = fx.app, nil
		local ok, err = pcall(function()
			local miles_panel = require(MILES_PANEL)
			miles_panel.show_conversation_on_select({ id = "d20", name = "d20", cwd = "/p" }, { turn = 2 }, { incoming = true })
		end)
		package.loaded[APP], package.loaded[MILES_PANEL] = saved_app, saved
		ConversationScreen.follow_item = original
		if not ok then
			error(err, 0)
		end
		check("the follow decision is taken once", calls == 1, calls)
	end)

	test("S2: a stored draft holds the view through holds_view, read back from a fresh store view", function()
		local root = vim.fn.tempname()
		local writer = t.make_store(root)
		writer:update(ConversationScreen, "w", function(v)
			v.state = "draft"
			v.agent = "c"
			v.turn = 3
			v.draft = { agent = "c" }
			v.owner_pid = vim.fn.getpid()
		end)
		local stored = t.make_store(root):get(ConversationScreen, "w")
		check("the stored draft reads back as a draft", stored ~= nil and stored.state == "draft", stored and stored.state)
		check("a live owner's draft holds an incoming turn from another agent", stored:holds_view("d", 2) == true)
		writer:update(ConversationScreen, "w", function(v)
			v.owner_pid = DEAD_PID
		end)
		local dead = t.make_store(root):get(ConversationScreen, "w")
		check("a dead owner's stored draft holds nothing", dead:holds_view("d", 2) == false)
		vim.fn.delete(root, "rf")
	end)
end

local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")

local function stored_with(t, fields)
	local root = vim.fn.tempname()
	t.make_store(root):update(ConversationScreen, "w", function(v)
		for k, val in pairs(fields) do
			v[k] = val
		end
		v.owner_pid = vim.fn.getpid()
	end)
	local v = t.make_store(root):get(ConversationScreen, "w")
	vim.fn.delete(root, "rf")
	return v
end

local function incoming_holds(t, fields, latest)
	return stored_with(t, fields):holds_view(fields.agent or "a", latest)
end

return function(t)
	local test, check = t.test, t.check
	local function stored(fields)
		return stored_with(t, fields)
	end
	local function holds(fields, latest)
		return incoming_holds(t, fields, latest)
	end

	test("an incoming message doesn't end the draft I'm typing", function()
		local v = stored({ state = "draft", agent = "a", draft = { agent = "a" } })
		check("I'm drafting", v.state == "draft")
		check("an incoming turn holds the draft through holds_view", v:holds_view("a", 4) == true)
		check("an incoming turn leaves the draft alone", not v:follow_item({ id = "a" }, { turn = 4 }, true) and v.state == "draft")
		check("an incoming turn with no item leaves it alone too", not v:follow_item({ id = "a" }, nil, true) and v.state == "draft")
		check("choosing a turn myself still leaves the draft", v:follow_item({ id = "a" }, { turn = 4 }) and v.state == "answer")
	end)

	test("an incoming message doesn't pull me out of a question", function()
		local v = stored({ state = "ask", agent = "a", ask = "q1" })
		check("an incoming turn holds the question through holds_view", v:holds_view("a", 4) == true)
		check("an incoming turn leaves the question alone", not v:follow_item({ id = "a" }, { turn = 4 }, true) and v.state == "ask" and v.ask == "q1")
	end)

	test("at the bottom of the conversation the view follows an incoming message", function()
		local v = stored({ state = "answer", agent = "a", turn = 4, shown_agent = "a", shown_turn = 4 })
		check("at the bottom nothing holds the view", v:holds_view("a", 5) == false)
		check("it follows", v:follow_item({ id = "a" }, { turn = 5 }, true) and v.turn == nil and v:follows_latest())
	end)

	test("an incoming auto-follow keeps following latest, so a later message still holds a scrolled-up reader", function()
		local v = stored({ state = "answer", agent = "a", turn = 2, shown_agent = "a", shown_turn = 2 })
		check("auto-follow to turn 3", v:follow_item({ id = "a" }, { turn = 3 }, true))
		check("still following latest, not pinned to turn 3", v:follows_latest() and v.turn == nil)
		check("turn 4 arrives while scrolled up on turn 3: hold", holds({ state = "answer", agent = "a", shown_agent = "a", shown_turn = 3, scrolled_up = true }, 4))
		check("turn 4 arrives at the bottom: follow", not holds({ state = "answer", agent = "a", shown_agent = "a", shown_turn = 3, scrolled_up = false }, 4))
	end)

	test("an incoming message doesn't pull me out of a past answer I'm reading", function()
		local past = { at = 7 }
		local v = stored({ state = "answer", agent = "a", history = past })
		check("an incoming turn holds the past answer through holds_view", v:holds_view("a", 4) == true)
		check("an incoming turn leaves the past answer alone", not v:follow_item({ id = "a" }, { turn = 4 }, true) and v.history.at == past.at)
		check("choosing a turn myself still leaves the past answer", v:follow_item({ id = "a" }, { turn = 4 }) and v.history == nil)
	end)

	test("an incoming message doesn't pull me out of a mandatum or expeditio view", function()
		local v = stored({ state = "entry", agent = "a", entry = { kind = "mandatum", id = "m1" } })
		check("an incoming turn holds the entry through holds_view", v:holds_view("a", 4) == true)
		check("an incoming turn leaves the entry alone", not v:follow_item({ id = "a" }, { turn = 4 }, true) and v.state == "entry" and v.entry.id == "m1")
		check("choosing a turn myself still leaves the entry", v:follow_item({ id = "a" }, { turn = 4 }) and v.state == "answer")
	end)

	test("the view holds still while I read an earlier part, and says a message is waiting", function()
		check("scrolled up on turn 3 while turn 4 arrives: hold", holds({ state = "answer", agent = "a", shown_agent = "a", shown_turn = 3, scrolled_up = true }, 4))
		check("at the bottom of turn 3: follow", not holds({ state = "answer", agent = "a", shown_agent = "a", shown_turn = 3, scrolled_up = false }, 4))
		check("already on the latest turn: nothing to hold", not holds({ state = "answer", agent = "a", shown_agent = "a", shown_turn = 4, scrolled_up = true }, 4))
		check("no turn shown yet: nothing to hold", not holds({ state = "answer", agent = "a", shown_agent = "a", shown_turn = nil, scrolled_up = true }, 4))
		check("a draft holds the view even at the bottom", holds({ state = "draft", agent = "a", draft = { agent = "a" }, shown_agent = "a", shown_turn = 3, scrolled_up = false }, 4))
		local pinned = stored({ state = "answer", agent = "a", turn = 2 })
		check("a pinned earlier turn is never replaced", not pinned:follows_latest())
		check("a shown turn behind the latest is flagged as waiting", ConversationScreen.is_behind(2, 4) and not ConversationScreen.is_behind(4, 4) and not ConversationScreen.is_behind(nil, 4))
	end)
end

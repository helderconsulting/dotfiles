local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")

return function(t)
	local test, check = t.test, t.check

	test("a stored conversation screen without the attention fields loads, and another agent's turn switches it", function()
		local root = vim.fn.tempname()
		local writer = t.make_store(root)
		writer:update(ConversationScreen, "w", function(s)
			s.state = "answer"
			s.agent = "c14"
			s.turn = 3
		end)
		local reader = t.make_store(root)
		local screen = reader:get(ConversationScreen, "w")
		check("the old record loads with its agent and turn", screen ~= nil and screen.agent == "c14" and screen.turn == 3, screen)
		local switched = screen:follow_item({ id = "d14", name = "d14", cwd = "/p" }, { turn = 2 }, true)
		check("an incoming turn from another agent switches the screen", switched and screen.agent == "d14", screen and screen.agent)
		vim.fn.delete(root, "rf")
	end)
end

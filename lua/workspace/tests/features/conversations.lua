return function(t)
	local test, check, make_store = t.test, t.check, t.make_store
	local Question = require("workspace.conversations.domain.question")
	local Inquiry = require("workspace.conversations.application.inquiry")
	local Drafting = require("workspace.conversations.application.drafting")
	local Draft = require("workspace.conversations.domain.draft")
	local QuestionRepository = require("workspace.conversations.infrastructure.outbound.filesystem.question_repository")
	local AnswerQuestionCommand = require("workspace.conversations.application.commands.answer_question_command")
	local DecideQuestionCommand = require("workspace.conversations.application.commands.decide_question_command")
	local InquiryDto = require("workspace.conversations.application.dto.inquiry_dto")
	local view_mapper = require("workspace.conversations.presentation.mappers.inquiry_view_mapper")

	local function inquiry_over(store)
		return Inquiry.new({
			questions = QuestionRepository.new(store),
			workspaces = { get = function() end },
			pid_alive = function()
				return true
			end,
			clock = function()
				return 100
			end,
		})
	end

	local Provider = require("workspace.shared.providers").current()
	local function event(moment, fields)
		return Provider.session_event(Provider.raw(moment, fields))
	end

	local asked = {
		tool_name = "AskUserQuestion",
		session_id = "s1",
		cwd = "/p",
		tool_input = {
			questions = {
				{
					question = "which?",
					header = "pick",
					multiSelect = false,
					options = { { label = "a", description = "first" }, { label = "b" } },
				},
			},
		},
	}

	test("answering a question goes through the inquiry service", function()
		local store = make_store(vim.fn.tempname())
		local repo = QuestionRepository.new(store)
		repo:save(Question.from_session_event(event("before_tool", asked), "q1", 7, 90))
		local inquiry = inquiry_over(store)
		local dto = inquiry:open("q1")
		check(
			"an open question comes back as a dto",
			InquiryDto.is(dto) and dto.is_question and dto.session == "s1" and dto.prompts[1].options[1].label == "a"
		)
		check(
			"it is claimed once",
			inquiry:next_for({ "s1" }).unseen and inquiry:claim("q1") ~= nil and not inquiry:next_for({ "s1" }).unseen
		)
		local pages = view_mapper.to_question_pages(dto)
		check("the view model numbers its options", pages[1].header == "pick" and pages[1].options[2].key == "2")
		inquiry:answer(view_mapper.to_answer_command("q1", { ["which?"] = "a" }))
		local q = repo:get("q1")
		check(
			"the answer lands on the question",
			q.state == "answered"
				and q.answers["which?"] == "a"
				and AnswerQuestionCommand.is(view_mapper.to_answer_command("q1", {}))
		)
		check("an answered question is no longer open", inquiry:open("q1") == nil)
		inquiry:answer(view_mapper.to_answer_command("q1", { ["which?"] = "b" }))
		check("a second answer changes nothing", repo:get("q1").answers["which?"] == "a")
	end)

	test("a permission request is decided and dismissed through the service", function()
		local store = make_store(vim.fn.tempname())
		local repo = QuestionRepository.new(store)
		local bash = {
			tool_name = "Bash",
			session_id = "s1",
			cwd = "/p",
			tool_input = { command = "ls" },
		}
		repo:save(Question.from_session_event(event("permission", bash), "p1", 7, 90))
		repo:save(Question.from_session_event(event("permission", bash), "p2", 8, 90))
		local inquiry = inquiry_over(store)
		local dto = inquiry:open("p1")
		local choices = view_mapper.to_permission_choices(dto)
		check(
			"a permission carries its details and choices",
			dto.details[1] == "$ ls" and #choices == 2 and choices[1].decision == "allow"
		)
		inquiry:decide(DecideQuestionCommand.new({ id = "p1", decision = "deny" }))
		check("deny is recorded", repo:get("p1").decision == "deny" and repo:get("p1").state == "answered")
		inquiry:dismiss(view_mapper.to_dismiss_command("p2"))
		check(
			"dismissing answers it in the terminal",
			repo:get("p2").decision == "terminal" and repo:get("p2").state == "dismissed"
		)
	end)

	test("a past question is described for the history view", function()
		local inquiry = inquiry_over(make_store(vim.fn.tempname()))
		local entry = {
			kind = "question",
			session = "s1",
			root = "/p",
			input = asked.tool_input,
			answers = { ["which?"] = "custom" },
		}
		local pages = view_mapper.to_history_pages(inquiry:describe(entry), entry)
		check(
			"free text is added as the chosen answer",
			not pages[1].choices[1].chosen and pages[1].choices[3].label == "custom" and pages[1].choices[3].chosen
		)
	end)

	test("drafts are written, attached and sent through the drafting service", function()
		local dir = vim.fn.tempname()
		local paths = require("workspace.shared.state.paths").new(vim.env.HOME, dir)
		local drafting = Drafting.new({
			drafts = require("workspace.conversations.infrastructure.outbound.filesystem.draft_repository").new(paths),
		})
		local target = { agent = "a1", cwd = "/p" }
		check(
			"no draft yet and nothing to send",
			drafting:load(target) == nil and drafting:outgoing(view_mapper.to_outgoing_command(target, nil)) == nil
		)
		drafting:write(view_mapper.to_write_draft_command(target, "hello [Image #1]"))
		local tag = drafting:attach_image(view_mapper.to_attach_image_command(target, "/tmp/x.png"))
		local dto = drafting:load(target)
		check(
			"the draft comes back as a dto",
			dto.text == "hello [Image #1]"
				and not dto.empty
				and dto.first_line == "hello [Image #1]"
				and tag == "[Image #1]"
		)
		check("the message expands the image", dto.message == "hello [Image: source: /tmp/x.png]")
		local out = drafting:outgoing(view_mapper.to_outgoing_command(target, "review"))
		check("review comments are appended", out.message:find("review", 1, true) ~= nil and out.target == target)
		check(
			"keys follow the domain",
			drafting:key(target) == Draft.key(target) and drafting:starts_session({ cwd = "/p" })
		)
		drafting:discard(target)
		check("discarding removes it", drafting:load(target) == nil)
	end)
end

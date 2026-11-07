local AnswerQuestionCommand = require("workspace.conversations.application.commands.answer_question_command")
local DecideQuestionCommand = require("workspace.conversations.application.commands.decide_question_command")
local DismissQuestionCommand = require("workspace.conversations.application.commands.dismiss_question_command")
local WriteDraftCommand = require("workspace.conversations.application.commands.write_draft_command")
local AttachImageCommand = require("workspace.conversations.application.commands.attach_image_command")
local OutgoingDraftCommand = require("workspace.conversations.application.commands.outgoing_draft_command")
local ChoiceViewModel = require("workspace.conversations.presentation.view_models.choice_view_model")
local QuestionPageViewModel = require("workspace.conversations.presentation.view_models.question_page_view_model")
local HistoryPageViewModel = require("workspace.conversations.presentation.view_models.history_page_view_model")

local M = {}

function M.to_answer_command(id, answers)
	return AnswerQuestionCommand.new({ id = id, answers = answers })
end

function M.to_decide_command(id, decision)
	return DecideQuestionCommand.new({ id = id, decision = decision })
end

function M.to_dismiss_command(id)
	return DismissQuestionCommand.new({ id = id })
end

function M.to_write_draft_command(target, text)
	return WriteDraftCommand.new({ target = target, text = text })
end

function M.to_attach_image_command(target, path)
	return AttachImageCommand.new({ target = target, path = path })
end

function M.to_outgoing_command(target, review)
	return OutgoingDraftCommand.new({ target = target, review = review })
end

function M.to_permission_choices(inquiry)
	local out = {}
	for i, c in ipairs(inquiry.choices) do
		out[i] = ChoiceViewModel.new({ key = c.key, label = c.label, extra = c.extra, decision = c.decision })
	end
	return out
end

local function option_choices(options)
	local out = {}
	for n, option in ipairs(options) do
		out[n] = ChoiceViewModel.new({ key = tostring(n), label = option.label, description = option.description })
	end
	return out
end

function M.to_question_pages(inquiry)
	local pages = {}
	for i, p in ipairs(inquiry.prompts) do
		pages[i] = QuestionPageViewModel.new({
			question = p.question,
			header = p.header or "question",
			multi_select = p.multi_select,
			options = option_choices(p.options),
		})
	end
	return pages
end

local function of_count(i, n)
	return n > 1 and (" · " .. i .. " of " .. n) or ""
end

local function picked_labels(given)
	local picked = {}
	for part in tostring(given or ""):gmatch("[^,]+") do
		picked[vim.trim(part)] = true
	end
	return picked
end

function M.to_history_pages(inquiry, entry)
	if not inquiry.is_question then
		local choices = M.to_permission_choices(inquiry)
		for _, c in ipairs(choices) do
			if c.decision == entry.decision then
				c.chosen, c.extra = true, (c.extra or "") .. " · your answer"
			end
		end
		return {
			HistoryPageViewModel.new({
				heading = " wanted to use " .. tostring(inquiry.tool),
				text = inquiry.details,
				choices = choices,
			}),
		}
	end
	local pages = {}
	for i, p in ipairs(inquiry.prompts) do
		local given = (entry.answers or {})[p.question]
		local picked, matched = picked_labels(given), false
		local choices = option_choices(p.options)
		for _, c in ipairs(choices) do
			c.chosen = picked[c.label] == true
			matched = matched or c.chosen
			c.extra = c.chosen and " · your answer" or nil
		end
		if given and not matched then
			table.insert(
				choices,
				ChoiceViewModel.new({ key = "o", label = given, chosen = true, extra = " · your answer" })
			)
		end
		pages[i] = HistoryPageViewModel.new({
			heading = " asked · " .. (p.header or "question") .. of_count(i, #inquiry.prompts),
			text = { p.question },
			choices = choices,
		})
	end
	return pages
end

function M.question_heading(page, index, count)
	return " asks · " .. page.header .. of_count(index, count)
end

return M

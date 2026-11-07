local InquiryDto = require("workspace.conversations.application.dto.inquiry_dto")
local QuestionPromptDto = require("workspace.conversations.application.dto.question_prompt_dto")
local QuestionOptionDto = require("workspace.conversations.application.dto.question_option_dto")
local PermissionChoiceDto = require("workspace.conversations.application.dto.permission_choice_dto")
local DraftDto = require("workspace.conversations.application.dto.draft_dto")
local TurnDto = require("workspace.conversations.application.dto.turn_dto")
local TranscriptDto = require("workspace.conversations.application.dto.transcript_dto")

local M = {}

local function map(list, fn)
	local out = {}
	for i, item in ipairs(list or {}) do
		out[i] = fn(item)
	end
	return out
end

function M.to_question_option_dto(option)
	return QuestionOptionDto.new({ label = option.label, description = option.description })
end

function M.to_question_prompt_dto(prompt)
	return QuestionPromptDto.new({
		question = prompt.question,
		header = prompt.header,
		multi_select = prompt.multiSelect == true,
		options = map(prompt.options, M.to_question_option_dto),
	})
end

function M.to_permission_choice_dto(choice)
	return PermissionChoiceDto.new({
		key = choice.key,
		label = choice.label,
		extra = choice.extra,
		decision = choice.decision,
	})
end

function M.to_inquiry_dto(question)
	local is_question = question:is_question()
	return InquiryDto.new({
		id = question.id,
		session = question.session,
		cwd = question.cwd,
		tool = question.tool,
		is_question = is_question,
		unseen = question:is_unseen(),
		pending = question:is_pending(),
		decision = question.decision,
		prompts = is_question and map(question:questions(), M.to_question_prompt_dto) or {},
		details = is_question and {} or question:details(),
		choices = is_question and {} or map(question:permission_choices(), M.to_permission_choice_dto),
	})
end

function M.to_draft_dto(draft)
	return DraftDto.new({
		target = draft.target,
		text = draft.text,
		images = draft.images,
		message = draft:message(),
		empty = draft:is_empty(),
		first_line = draft:first_line(),
		mtime = draft.mtime,
		created = draft.created,
	})
end

function M.to_turn_dto(turn)
	return TurnDto.new({
		prompt = turn.prompt,
		from = turn.from,
		reply = turn.reply,
		at = turn.at,
		queued = turn.queued,
	})
end

function M.to_transcript_dto(transcript)
	local turns = {}
	for i = 1, transcript:count() do
		turns[i] = M.to_turn_dto(transcript:turn(i))
	end
	return TranscriptDto.new({ id = transcript.id, count = transcript:count(), turns = turns })
end

return M

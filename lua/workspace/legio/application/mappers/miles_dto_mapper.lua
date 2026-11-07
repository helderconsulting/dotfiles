local MilesDto = require("workspace.legio.application.dto.miles_dto")
local RankDto = require("workspace.legio.application.dto.rank_dto")
local MilesSetupDto = require("workspace.legio.application.dto.miles_setup_dto")
local AgentdStatusDto = require("workspace.legio.application.dto.agentd_status_dto")
local AwaitingTurnDto = require("workspace.legio.application.dto.awaiting_turn_dto")
local HeldMessageDto = require("workspace.legio.application.dto.held_message_dto")
local ModelCatalogDto = require("workspace.legio.application.dto.model_catalog_dto")
local ModelChoiceDto = require("workspace.legio.application.dto.model_choice_dto")
local PermissionModeDto = require("workspace.legio.application.dto.permission_mode_dto")
local QuestionReplyDto = require("workspace.legio.application.dto.question_reply_dto")
local QuestionStateDto = require("workspace.legio.application.dto.question_state_dto")
local QuestionTimingDto = require("workspace.legio.application.dto.question_timing_dto")
local ContuberniumDto = require("workspace.legio.application.dto.contubernium_dto")
local ContuberniumMemberDto = require("workspace.legio.application.dto.contubernium_member_dto")
local ContuberniumMessageSentDto = require("workspace.legio.application.dto.contubernium_message_sent_dto")
local ContuberniumSizesDto = require("workspace.legio.application.dto.contubernium_sizes_dto")
local ContuberniumStartedDto = require("workspace.legio.application.dto.contubernium_started_dto")
local Contubernium = require("workspace.legio.domain.contubernium")
local ContuberniumStackMemberDto = require("workspace.legio.application.dto.contubernium_stack_member_dto")

local M = {}

local function map(list, fn, ...)
	local out = {}
	for i, item in ipairs(list or {}) do
		out[i] = fn(item, ...)
	end
	return out
end

function M.to_held_message_dto(message)
	return HeldMessageDto.new({ id = message.id, text = message.text, at = message.at })
end

function M.to_rank_dto(standing)
	return RankDto.new({ rank = standing.rank, level = standing.level, next = standing.next, done = standing.done, needed = standing.needed, unit = standing.unit })
end

function M.to_miles_dto(miles, now)
	local state, tone = miles:status()
	local progress, progress_tone = miles:progress(now)
	local can_continue, continue_reason = miles:can_continue()
	return MilesDto.new({
		id = miles.id,
		short = miles:short(),
		name = miles:display_name(),
		title = miles.title,
		state = state,
		tone = tone,
		cwd = miles.cwd,
		root = miles.root,
		branch = miles.branch,
		worktree = miles.worktree,
		pane = miles.pane,
		host = miles.host,
		running = miles:is_running(),
		busy = miles:is_busy(),
		needs_you = miles:needs_you(),
		hosted = miles:is_hosted(),
		on_sdk = miles:on_sdk(),
		on_cli = miles:on_cli(),
		channel = miles:channel(),
		unread = miles:unread(),
		activity = miles.activity,
		read_at = miles.read_at,
		updated = miles.updated,
		progress = progress,
		progress_tone = progress_tone,
		provider = miles:provider(),
		model = miles:model_name(),
		model_label = miles:model_label(),
		mode = miles:mode(),
		mode_label = miles:mode_label(),
		context_fraction = miles:context_fraction(),
		plan_label = miles:plan_label(),
		uses_extra = miles:uses_extra(),
		fallback_reason = miles:fallback_reason(),
		can_continue = can_continue,
		continue_reason = continue_reason,
		rank = miles:rank(),
		standing = M.to_rank_dto(miles:standing()),
		role = miles.role,
		legio = miles.legio,
		held = map(miles:held(), M.to_held_message_dto),
		can_release = miles:can_release(),
	})
end

function M.to_milites_dtos(milites, now)
	return map(milites, M.to_miles_dto, now)
end

function M.to_awaiting_turn_dto(turn)
	return AwaitingTurnDto.new({ text = turn.text, at = turn.at, started = turn.started })
end

function M.to_contubernium_member_dto(member, position, miles, todo_title)
	return ContuberniumMemberDto.new({
		name = member.name,
		miles_id = member.miles,
		title = Contubernium.member_title(member.name, miles and miles.title, todo_title),
		decanus = position == 1,
		position = position,
		started = miles ~= nil,
		state = miles and miles.state,
		branch = miles and miles.branch,
		worktree = miles and miles.worktree,
	})
end

function M.to_contubernium_dto(contubernium, miles_of, todo_title)
	local members = {}
	for i, m in ipairs(contubernium.members) do
		members[i] = M.to_contubernium_member_dto(m, i, miles_of(m.miles), todo_title)
	end
	return ContuberniumDto.new({
		id = contubernium.id,
		name = contubernium.name,
		label = contubernium:label(),
		todo = contubernium.todo,
		root = contubernium.root,
		base = contubernium.base,
		created = contubernium.created,
		members = members,
	})
end

function M.to_contubernium_sizes_dto(min, max)
	return ContuberniumSizesDto.new({ min = min, max = max })
end

function M.to_contubernium_started_dto(contubernium, decanus_id, todo_title)
	return ContuberniumStartedDto.new({ contubernium_id = contubernium.id, label = contubernium:label(), decanus_id = decanus_id, size = #contubernium.members, todo_title = todo_title })
end

function M.to_contubernium_message_sent_dto(contubernium, members)
	return ContuberniumMessageSentDto.new({
		contubernium_id = contubernium.id,
		recipients = map(members, function(m)
			return m.name
		end),
	})
end

function M.to_agentd_status_dto(status)
	local health, tone = status:health()
	return AgentdStatusDto.new({ state = status.state, reason = status.reason, since = status.since, health = health, health_tone = tone })
end

function M.to_permission_mode_dtos(modes)
	return map(modes, function(m)
		return PermissionModeDto.new({ value = m.value, description = m.description })
	end)
end

function M.to_model_choice_dto(model)
	return ModelChoiceDto.new({ value = model.value, label = model.label, description = model.description })
end

function M.to_model_catalog_dto(provider, models)
	return ModelCatalogDto.new({ provider = provider, models = map(models, M.to_model_choice_dto) })
end

function M.to_model_catalog_dtos(providers)
	return map(providers, function(p)
		return M.to_model_catalog_dto(p.provider, p.models)
	end)
end

function M.to_miles_setup_dto(provider, model, mode)
	return MilesSetupDto.new({ provider = provider, model = model, mode = mode })
end

function M.to_question_state_dto(question)
	return QuestionStateDto.new({
		id = question.id,
		state = question.state,
		pending = question:is_pending(),
		unseen = question:is_unseen(),
		answered = question.state == "answered",
		output = question.output,
	})
end

function M.to_question_timing_dto(show_within, timeout)
	return QuestionTimingDto.new({ show_within = show_within, timeout = timeout })
end

function M.to_question_reply_dto(question)
	return QuestionReplyDto.new({ id = question.id, result = question:result() })
end

function M.to_contubernium_stack_dtos(contubernium, miles_of)
	local out = {}
	for i, member in ipairs(contubernium.members) do
		local miles = member.miles and miles_of(member.miles)
		local state, tone = "gone", "off"
		if miles then
			state, tone = miles:status()
		end
		out[i] = ContuberniumStackMemberDto.new({
			position = i,
			name = member.name,
			decanus = i == 1,
			branch = miles and miles.branch or nil,
			state = state,
			tone = tone,
		})
	end
	return out
end

return M

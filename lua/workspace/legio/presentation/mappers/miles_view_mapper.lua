local format = require("workspace.shared.lib.format")
local AgentdHealthViewModel = require("workspace.legio.presentation.view_models.agentd_health_view_model")
local MeterViewModel = require("workspace.legio.presentation.view_models.meter_view_model")
local PickEntryViewModel = require("workspace.legio.presentation.view_models.pick_entry_view_model")
local RemovalPlanViewModel = require("workspace.legio.presentation.view_models.removal_plan_view_model")
local SessionRowViewModel = require("workspace.legio.presentation.view_models.session_row_view_model")
local ContuberniumSizesViewModel = require("workspace.legio.presentation.view_models.contubernium_sizes_view_model")
local Commands = {
	deliver = require("workspace.legio.application.commands.deliver_message_command"),
	mark_read = require("workspace.legio.application.commands.mark_read_command"),
	message = require("workspace.legio.application.commands.message_miles_command"),
	resume = require("workspace.legio.application.commands.resume_miles_command"),
	send_now = require("workspace.legio.application.commands.send_held_now_command"),
	set_mode = require("workspace.legio.application.commands.set_mode_command"),
	set_model = require("workspace.legio.application.commands.set_model_command"),
	start = require("workspace.legio.application.commands.start_miles_command"),
	start_contubernium = require("workspace.legio.application.commands.start_contubernium_command"),
	title = require("workspace.legio.application.commands.set_miles_title_command"),
}

local rank_view_mapper = require("workspace.legio.presentation.mappers.rank_view_mapper")

local M = {}

local function map(list, fn, ...)
	local out = {}
	for i, item in ipairs(list or {}) do
		out[i] = fn(item, ...)
	end
	return out
end

function M.to_meter_view_model(dto)
	local parts = {}
	table.insert(parts, dto.plan_label)
	table.insert(parts, dto.model_label)
	table.insert(parts, dto.mode_label)
	local fraction = dto.context_fraction
	if not fraction and #parts == 0 then
		return nil
	end
	return MeterViewModel.new({
		fraction = fraction,
		percent = fraction and ("%d%%"):format(math.floor(fraction * 100 + 0.5)) or nil,
		label = table.concat(parts, " · "),
	})
end

local function word_of(dto)
	local word, kind = dto.state, dto.tone
	if dto.progress then
		word, kind = word .. " · " .. dto.progress, dto.progress_tone or kind
	end
	return word, kind
end

local function move_blocker(dto, name)
	if dto.pane then
		return name .. " runs in a terminal pane, it stays on the cli"
	elseif dto.on_sdk then
		return name .. " is already on the sdk"
	elseif dto.busy then
		return name .. " is " .. dto.state .. ", move it once it's idle"
	end
end

local function continue_blocker(dto, name)
	if not dto.running then
		return name .. " isn't running"
	end
	return not dto.can_continue and dto.continue_reason or nil
end

local chain = {
	["primus pilus"] = { key = "0", mark = "★ ", indent = "", bar = "▌" },
	["pilus prior"] = { key = "0", mark = "★ ", indent = "", bar = "▌" },
	centurio ={ key = "1", mark = "★ ", indent = "", bar = "▌" },
	optio = { key = "2", mark = "☆ ", indent = "", bar = "▌" },
	decanus = { mark = "★ ", indent = "  ", bar = "▎" },
}

local soldier = { mark = "", indent = "    ", bar = "▏" }

local function place_in_chain(dto, label, position)
	if not dto.legio then
		return nil
	end
	local post = chain[dto.role] or soldier
	local key = post.key or ("3 " .. (label or "~") .. " " .. (dto.role == "decanus" and "0" or tostring(position or 9)))
	return post, "0 " .. dto.legio .. " " .. key
end

local function title_of(name)
	return name:match("^(.-) · ") or name
end

function M.to_miles_row(dto, name, contubernium_label, position)
	name = title_of(name or dto.name)
	local word, kind = word_of(dto)
	local place = dto.worktree or format.basename(dto.root)
	local post, sort_key = place_in_chain(dto, contubernium_label, position)
	return SessionRowViewModel.new({
		id = dto.id,
		miles_id = dto.id,
		name = name,
		cwd = dto.root,
		root = dto.root,
		running = true,
		busy = dto.busy,
		state = dto.state,
		word = word,
		kind = kind,
		unread = (not dto.legio or chain[dto.role]) and dto.unread or nil,
		order = 0,
		place = place,
		on_cli = dto.on_cli,
		on_sdk = dto.on_sdk,
		uses_extra = dto.uses_extra,
		meter = M.to_meter_view_model(dto),
		search_word = word,
		search_detail = place,
		target = { agent = dto.id, cwd = dto.root, name = name },
		needs_resume = false,
		toggle = "end",
		cannot_interrupt = not (dto.running and dto.busy) and (name .. " isn't working") or nil,
		cannot_continue = continue_blocker(dto, name),
		cannot_move = move_blocker(dto, name),
		sort_name = sort_key or (contubernium_label and position and (contubernium_label .. " " .. position) or name),
		mark = post and post.mark or nil,
		leader = post and post.mark ~= "" or nil,
		indent = post and post.indent or nil,
		bar = post and post.bar or nil,
		contubernium_label = contubernium_label,
		standing = dto.legio and dto.standing or nil,
		role = dto.role,
	})
end

local function off_row(fields)
	fields.running = false
	fields.kind = fields.kind or "off"
	fields.cannot_interrupt = fields.name .. " isn't working"
	fields.cannot_continue = fields.name .. " isn't running"
	fields.cannot_move = fields.name .. " isn't running"
	fields.sort_name = fields.name
	return SessionRowViewModel.new(fields)
end

function M.to_file_row(file, info, order, now)
	local name = info.title or file.id:sub(1, 8)
	local word = format.age(file.mtime, now)
	local place = format.basename(info.cwd)
	return off_row({
		id = file.id,
		path = file.path,
		name = name,
		cwd = info.cwd,
		mtime = file.mtime,
		word = word,
		order = order,
		place = place,
		search_word = "ended",
		search_detail = place .. " · " .. word,
		target = { agent = file.id, cwd = info.cwd, name = name },
		needs_resume = info.cwd ~= nil,
		toggle = "resume",
		cannot_end = name .. " isn't running",
	})
end

function M.to_draft_row(target, key)
	local word = "drafting · starts on send" .. (target.model and (" · " .. target.model) or "")
	local place = format.basename(target.cwd)
	return off_row({
		id = key,
		name = "new session",
		cwd = target.cwd,
		drafting = true,
		word = word,
		kind = "busy",
		order = -1,
		place = place,
		search_word = "ended",
		search_detail = place .. " · " .. word,
		target = { cwd = target.cwd, name = place },
		needs_resume = false,
		toggle = "resume",
		cannot_end = "the new session starts when you send its draft",
	})
end

local function contubernium_places(contubernia)
	local out = {}
	for _, contubernium in ipairs(contubernia or {}) do
		for _, m in ipairs(contubernium.members) do
			out[m.miles_id] = { title = m.title, label = contubernium.label, position = m.position }
		end
	end
	return out
end

local weight = { bad = 4, limit = 4, busy = 3, ok = 2, off = 1 }

local function strength_word(dtos)
	local counts, order = {}, {}
	for _, dto in ipairs(dtos) do
		if not counts[dto.state] then
			counts[dto.state] = 0
			table.insert(order, dto.state)
		end
		counts[dto.state] = counts[dto.state] + 1
	end
	local parts = {}
	for _, state in ipairs(order) do
		table.insert(parts, counts[state] .. " " .. state)
	end
	return table.concat(parts, " · ")
end

local function contubernium_row(contubernium, by_id, hidden)
	local lead, members = nil, {}
	for _, m in ipairs(contubernium.members) do
		local dto = by_id[m.miles_id]
		if dto and not hidden[dto.id] then
			table.insert(members, dto)
			if m.decanus or not lead then
				lead = m.decanus and dto or lead or dto
			end
		end
	end
	if not lead then
		return nil
	end
	local row = M.to_miles_row(lead, lead.name, contubernium.label, 1)
	local kind = "off"
	for _, dto in ipairs(members) do
		local _, k = word_of(dto)
		if (weight[k] or 0) > (weight[kind] or 0) then
			kind = k
		end
	end
	row.name = contubernium.label
	row.mark = "◆ "
	row.kind = kind
	row.place = "decanus " .. lead.name .. " · " .. (lead.worktree or format.basename(lead.root))
	row.word = strength_word(members)
	row.contubernium_label = nil
	row.role = nil
	row.indent = row.indent and "  " or nil
	row.bar = row.indent and "▎" or nil
	row.leader = false
	return row
end

function M.to_active_rows(dtos, folder, draft, draft_key, contubernia, hidden)
	hidden = hidden or {}
	local members = contubernium_places(contubernia)
	local by_id = {}
	for _, dto in ipairs(dtos) do
		by_id[dto.id] = dto
	end
	local list = {}
	if draft_key and format.inside(folder, draft.cwd) then
		table.insert(list, M.to_draft_row(draft, draft_key))
	end
	for _, contubernium in ipairs(contubernia or {}) do
		local row = contubernium_row(contubernium, by_id, hidden)
		if row then
			table.insert(list, row)
		end
	end
	for _, dto in ipairs(dtos) do
		if not (members[dto.id] or hidden[dto.id]) then
			table.insert(list, M.to_miles_row(dto))
		end
	end
	return list
end

function M.to_session_list(active, files, infos, folder, now)
	local list, live = {}, {}
	for _, e in ipairs(active) do
		live[e.id] = true
		table.insert(list, e)
	end
	for i, f in ipairs(files) do
		local info = infos[f.path]
		if info and info.cwd and not live[f.id] and format.inside(folder, info.cwd) then
			table.insert(list, M.to_file_row(f, info, i, now))
		end
	end
	return list
end

local function card_word(row, counts)
	local word = row.word
	local sent = counts and counts.sent or 0
	local resolved = counts and counts.resolved or 0
	if sent > 0 then
		word = word .. " · " .. sent .. " open"
	end
	if resolved > 0 then
		word = word .. " · " .. resolved .. " resolved"
	end
	return word
end

local function card_place(row)
	local place = row.place
	if row.on_cli then
		place = place .. " · cli"
	end
	if row.running and row.uses_extra then
		place = place .. " · extra usage"
	end
	if row.contubernium_label then
		place = place .. " · " .. row.contubernium_label
	end
	if row.role then
		place = place .. " · " .. row.role
	end
	return place
end

function M.to_card_lines(row, counts, merge_request_lines)
	local title = (row.mark or "") .. row.name
	local lines = { row.leader and { segments = { { title, "lead" } } } or title, card_place(row), card_word(row, counts) }
	if row.standing then
		table.insert(lines, rank_view_mapper.to_rank_row(row.standing))
	end
	for _, line in ipairs(merge_request_lines or {}) do
		table.insert(lines, line)
	end
	lines[#lines + 1] = row.meter
	return lines
end

function M.to_removal_plan(row, found)
	local path = row.path or found
	if not path or path == "" then
		return nil, "no session file for " .. row.name
	end
	return RemovalPlanViewModel.new({ path = path, sidecar = (path:gsub("%.jsonl$", "")), stop_first = row.running })
end

function M.to_new_title(row, name)
	if not row.path then
		return nil, "no session file to rename"
	end
	if not name or name == "" or name == row.name then
		return nil
	end
	return name
end

function M.to_agentd_health_view_model(dto)
	return AgentdHealthViewModel.new({ word = dto.health, tone = dto.health_tone })
end

function M.to_contubernium_sizes_view_model(dto)
	return ContuberniumSizesViewModel.new({ min = dto.min, max = dto.max, prompt = ("how many agents (%d-%d)? "):format(dto.min, dto.max) })
end

function M.to_model_entries(catalogs, setup)
	local out = {}
	for _, p in ipairs(catalogs) do
		for _, m in ipairs(p.models or {}) do
			table.insert(out, PickEntryViewModel.new({
				tag = p.provider,
				provider = p.provider,
				value = m.value,
				label = m.label,
				description = m.description,
				current = setup and setup.provider == p.provider and setup.model == m.value or nil,
			}))
		end
	end
	return out
end

function M.to_mode_entries(modes, current)
	return map(modes, function(m)
		return PickEntryViewModel.new({ tag = "mode", value = m.value, description = m.description, current = m.value == current or nil })
	end)
end

function M.to_new_session_entry()
	return PickEntryViewModel.new({ tag = "new", value = "new session", description = "start one with it right away" })
end

function M.to_miles_pick_entry(dto)
	return PickEntryViewModel.new({ tag = dto.state, value = dto.name, description = dto.worktree or "", miles_id = dto.id })
end

function M.to_start_command(cwd, prompt, launch, id)
	launch = launch or {}
	return Commands.start.new({ cwd = cwd, prompt = prompt, id = id, provider = launch.provider, model = launch.model, mode = launch.mode })
end

function M.to_deliver_command(target, text)
	return Commands.deliver.new({ miles_id = target.agent, cwd = target.cwd, text = text, provider = target.provider, model = target.model, mode = target.mode })
end

function M.to_resume_command(row)
	return Commands.resume.new({ miles_id = row.id, cwd = row.cwd })
end

function M.to_message_command(miles_id, text)
	return Commands.message.new({ miles_id = miles_id, text = text })
end

function M.to_set_mode_command(miles_id, mode)
	return Commands.set_mode.new({ miles_id = miles_id, mode = mode })
end

function M.to_set_model_command(miles_id, model)
	return Commands.set_model.new({ miles_id = miles_id, model = model })
end

function M.to_send_now_command(miles_id, message_id)
	return Commands.send_now.new({ miles_id = miles_id, message_id = message_id })
end

function M.to_mark_read_command(miles_id, at)
	return Commands.mark_read.new({ miles_id = miles_id, at = at })
end

function M.to_title_command(miles_id, title)
	return Commands.title.new({ miles_id = miles_id, title = title })
end

function M.to_start_contubernium_command(todo, root, size, launch)
	launch = launch or {}
	return Commands.start_contubernium.new({ todo_id = todo.id, todo_text = todo.text, todo_title = todo.title, root = root, size = size, provider = launch.provider, model = launch.model, mode = launch.mode })
end

function M.to_contubernium_stack_rows(dtos)
	return map(dtos, function(dto)
		return {
			segments = {
				{ ("%d. %s%s"):format(dto.position, dto.name, dto.decanus and " (lead)" or "") },
				{ " · " .. (dto.branch or "no branch") },
				{ " · " .. dto.state, dto.tone },
			},
		}
	end)
end

return M

local format = require("workspace.shared.lib.format")
local ExpeditioEntryViewModel = require("workspace.workflow.presentation.view_models.expeditio_entry_view_model")
local ExpeditioThreadViewModel = require("workspace.workflow.presentation.view_models.expeditio_thread_view_model")
local MandatumItemViewModel = require("workspace.workflow.presentation.view_models.mandatum_item_view_model")
local DocumentViewModel = require("workspace.workflow.presentation.view_models.document_view_model")

local M = {}

local marks = { done = "[x]", ["in progress"] = "[~]", open = "[ ]" }

local function sender(from, name_of)
	return from and from ~= "you" and name_of(from) or "you"
end

function M.who(mandatum, name_of)
	if mandatum.state == "open" then
		return "from " .. sender(mandatum.from, name_of)
	elseif mandatum.state == "assigned" then
		return "sending to " .. name_of(mandatum.assignee)
	end
	return name_of(mandatum.assignee)
end

local function since(mandatum)
	local at = { done = mandatum.done_at, sent = mandatum.sent_at, assigned = mandatum.assigned_at }
	return at[mandatum.state] or mandatum.created
end

function M.to_mandatum_card(mandatum, name_of, now, stack)
	local detail = M.who(mandatum, name_of) .. " · " .. format.age(since(mandatum), now)
	if mandatum.state ~= "done" and not mandatum.specified then
		detail = detail .. " · needs details"
	end
	if mandatum.state == "done" and mandatum.note then
		detail = detail .. " · " .. mandatum.note
	end
	local card = { mandatum.status, mandatum.title, detail }
	for _, row in ipairs(stack or {}) do
		table.insert(card, row)
	end
	return card
end

function M.to_expeditio_card(expeditio, name_of, now)
	local p = expeditio.progress
	local counts = {}
	for _, part in ipairs({ { p.in_progress, "in progress" }, { p.open, "open" } }) do
		if part[1] > 0 then
			table.insert(counts, part[1] .. " " .. part[2])
		end
	end
	return {
		expeditio.title,
		"expeditio · from " .. sender(expeditio.from, name_of) .. " · " .. format.age(expeditio.created, now),
		expeditio.status .. " · " .. p.done .. " of " .. p.total .. " done",
		{ fraction = p.fraction, percent = ("%d%%"):format(math.floor(p.fraction * 100 + 0.5)), label = table.concat(counts, " · ") },
	}
end

function M.to_expeditio_entry(expeditio, order, name_of, now)
	return ExpeditioEntryViewModel.new({
		id = expeditio.id,
		name = expeditio.title,
		kind = expeditio.tone,
		order = order,
		card = M.to_expeditio_card(expeditio, name_of, now),
		root = expeditio.root,
		waiting = expeditio.waiting,
		expeditio = expeditio,
	})
end

function M.to_thread(expeditio, name_of, now, stack_of)
	local items = {}
	for _, m in ipairs(expeditio.mandata) do
		table.insert(items, MandatumItemViewModel.new({ id = m.id, mandatum = m, kind = m.tone, card = M.to_mandatum_card(m, name_of, now, stack_of and stack_of(m.id)) }))
	end
	return ExpeditioThreadViewModel.new({ items = items, unread = 0, entry_id = expeditio.next_up })
end

function M.to_expeditio_document(expeditio, name_of, now)
	local card = M.to_expeditio_card(expeditio, name_of, now)
	local lines = { "# " .. expeditio.title, "" }
	for _, m in ipairs(expeditio.mandata) do
		local c = M.to_mandatum_card(m, name_of, now)
		table.insert(lines, ("- %s %s  _%s · %s_"):format(marks[m.status] or "[ ]", m.title, c[1], c[3]))
	end
	if #expeditio.mandata == 0 then
		table.insert(lines, "_no mandata yet_")
	end
	return DocumentViewModel.new({ header = card[2] .. " · " .. card[3], lines = lines })
end

function M.to_mandatum_document(mandatum, name_of, now, done_command)
	local card = M.to_mandatum_card(mandatum, name_of, now)
	local lines = {}
	for line in ((mandatum.text or "") .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	if not mandatum.specified then
		table.insert(lines, "")
		table.insert(lines, "_needs a description and acceptance criteria, amend it with `" .. done_command .. " amend " .. mandatum.id .. "`_")
	end
	if mandatum.state == "done" and mandatum.note then
		table.insert(lines, "")
		table.insert(lines, "done: " .. mandatum.note)
	end
	return DocumentViewModel.new({ header = "mandatum · " .. card[1] .. " · " .. card[3], lines = lines })
end

function M.to_mandatum_header(mandatum, name_of, now)
	local card = M.to_mandatum_card(mandatum, name_of, now)
	return "mandatum · " .. card[1] .. " · " .. card[3]
end

function M.titles(mandata)
	return #mandata == 1 and mandata[1].title or (#mandata .. " mandata")
end

return M

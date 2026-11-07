local app = require("workspace.workbench.presentation.nvim.app")
local view_mapper = require("workspace.workflow.presentation.mappers.expeditio_view_mapper")
local miles_view_mapper = require("workspace.legio.presentation.mappers.miles_view_mapper")
local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")

local M = {}

local function mandata()
	return app.services().mandatum_process
end

local function runner()
	return app.services().miles_runner
end

function M.names()
	local by_id = {}
	for _, a in ipairs(app.services().roster:all()) do
		by_id[a.id] = a.name
	end
	return function(id)
		return by_id[id] or (id and id:sub(1, 8)) or "an agent"
	end
end

function M.listed(folder)
	return mandata():expeditiones_in(folder)
end

function M.expeditio(id)
	return mandata():expeditio(id)
end

function M.mandatum(id)
	return mandata():mandatum(id)
end

function M.create_expeditio(root, title, from)
	return mandata():add_expeditio({ root = root, title = title, from = from or "you" })
end

function M.save(target, text)
	text = vim.trim(text or "")
	if text == "" then
		return
	end
	if target.expeditio == true then
		return M.create_expeditio(target.cwd, text:match("[^\n]+"), "you")
	elseif target.expeditio then
		return mandata():rename_expeditio({ expeditio_id = target.expeditio, title = text:match("[^\n]+") })
	end
	local ok, why = mandata():check(text)
	if not ok then
		return false, why
	end
	if target.mandatum == true then
		local id, why = mandata():add_mandatum({ root = target.cwd, expeditio_id = target.in_expeditio, text = text, from = "you" })
		if id then
			app.services().legio_process:offer_mandatum(id)
		end
		return id, why
	end
	return mandata():edit({ mandatum_id = target.mandatum, text = text })
end

local function compose(target, text)
	local drafts = require("workspace.conversations.presentation.nvim.drafts")
	if text and not drafts.load(target) then
		drafts.write(target, text)
	end
	drafts.compose(target)
end

function M.new_expeditio(folder)
	compose({ expeditio = true, cwd = folder, name = "a new expeditio" })
end

function M.add_to(expeditio_id, folder, text)
	compose({ mandatum = true, in_expeditio = expeditio_id, cwd = folder, name = "a new mandatum" }, text or mandata().template)
end

function M.add_from_review(folder, quote, text, images)
	M.add_to(nil, folder, mandata():from_review({ quote = quote, text = text, images = images }))
end

function M.edit_expeditio(expeditio)
	compose({ expeditio = expeditio.id, cwd = expeditio.root, name = "expeditio " .. expeditio.title }, expeditio.title)
end

function M.finish(mandatum_id)
	local ok = mandata():finish({ mandatum_id = mandatum_id, note = "" })
	if ok and app.services().legio_process then
		app.services().legio_process:credit_finished()
	end
	return ok
end

function M.drop(mandatum_id)
	return mandata():drop(mandatum_id)
end

function M.drop_expeditio(expeditio)
	return mandata():drop_expeditio(expeditio.id)
end

local documents = {
	mandatum = function(id)
		local m = M.mandatum(id)
		return m and view_mapper.to_mandatum_document(m, M.names(), app.now(), mandata().done_command)
	end,
	expeditio = function(id)
		local e = M.expeditio(id)
		return e and view_mapper.to_expeditio_document(e, M.names(), app.now())
	end,
}

function M.document(entry)
	local render = entry and documents[entry.kind]
	return render and render(entry.id)
end

function M.request_send(ids, cwd)
	app.update_screen(ConversationScreen, function(v)
		v:request_pick({ kind = "send_mandata", mandata = ids, cwd = cwd }, app.now())
	end)
	app.focus("conversation")
end

local function follow(id)
	app.update_screen(ConversationScreen, function(v)
		return v:select(id)
	end)
end

local function ids_of(list)
	return vim.tbl_map(function(m)
		return m.id
	end, list)
end

local function hand_over(list, root, agent, launch)
	local what = view_mapper.titles(list)
	local assignee = agent and agent.id or runner():new_miles_id()
	list = vim.tbl_filter(function(m)
		return mandata():assign({ mandatum_id = m.id, miles_id = assignee })
	end, list)
	if #list == 0 then
		return vim.notify(what .. " was just sent from somewhere else", vim.log.levels.WARN)
	end
	local ids = ids_of(list)
	local orders = mandata():orders(ids)
	local function sent(ok, id)
		for _, m in ipairs(list) do
			if ok then
				mandata():send({ mandatum_id = m.id, miles_id = id or assignee, assigned_as = assignee })
			else
				mandata():release({ mandatum_id = m.id, miles_id = assignee })
			end
		end
		if not ok then
			return
		end
		if id then
			runner():set_title(miles_view_mapper.to_title_command(id, mandata():session_title(ids)))
			if not agent then
				follow(id)
			end
		end
		vim.notify("sent " .. what .. " to " .. (agent and agent.name or "a new session"))
	end
	if agent then
		runner():deliver(miles_view_mapper.to_deliver_command({ agent = agent.id, cwd = agent.root or agent.cwd }, orders), function(ok)
			sent(ok, agent.id)
		end)
	else
		runner():start(miles_view_mapper.to_start_command(root, orders, launch, assignee), sent)
	end
end

local function nothing_free()
	vim.notify("nothing left to send there, an agent already has it", vim.log.levels.WARN)
end

function M.send_picker(p, picker)
	local list = mandata():free(p.mandata or { p.mandatum })
	if #list == 0 then
		return nothing_free()
	end
	local root = p.cwd or list[1].root
	local entries, agents = { miles_view_mapper.to_new_session_entry() }, {}
	for _, dto in ipairs(app.services().roster:running_in(root)) do
		agents[dto.id] = dto
		table.insert(entries, miles_view_mapper.to_miles_pick_entry(dto))
	end
	picker.pick(entries, { prompt = "send", header = "Enter sends " .. view_mapper.titles(list) }, function(choice)
		hand_over(list, root, choice.miles_id and agents[choice.miles_id])
	end)
end

function M.start_new(ids, root, launch)
	local list = mandata():free(ids)
	if #list == 0 then
		return nothing_free()
	end
	hand_over(list, root or list[1].root, nil, launch)
end

function M.titles(ids)
	local list = {}
	for _, id in ipairs(ids) do
		table.insert(list, M.mandatum(id))
	end
	return view_mapper.titles(list)
end

return M

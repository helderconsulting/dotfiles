local app = require("workspace.workbench.presentation.nvim.app")
local view_mapper = require("workspace.legio.presentation.mappers.legio_view_mapper")
local miles = require("workspace.legio.presentation.nvim.miles_panel")
local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")

local M = {}

M.name = "legio"

local raised = false

local function legiones()
	return app.services().legio_process
end

local function contubernium_lookups()
	local services = app.services()
	local roster = services.roster
	local process = services.mandatum_process
	local todo_of, names = {}, {}
	if roster and roster.all_contubernia then
		for _, contubernium in ipairs(roster:all_contubernia()) do
			todo_of[contubernium.id] = contubernium.todo
			for _, member in ipairs(contubernium.members or {}) do
				if member.miles_id then
					names[member.miles_id] = member.name
				end
			end
		end
	end
	local function mandatum_of(unit)
		local todo = todo_of[unit.id]
		local mandatum = todo and process and process:mandatum(todo)
		return mandatum and mandatum.title or nil
	end
	local function names_of(miles_id)
		return names[miles_id]
	end
	return mandatum_of, names_of
end

function M.entries_on_refresh(_, done)
	local service = legiones()
	if not service then
		return done({})
	end
	if not raised then
		service:raise_legiones()
		raised = true
	end
	service:credit_finished()
	service:revive_waiting()
	local list = {}
	for _, legio in ipairs(service:legiones()) do
		if legio.deployed then
			table.insert(list, legio)
		end
	end
	local entries = {}
	local mandatum_of, names_of = contubernium_lookups()
	for i, legio_entry in ipairs(view_mapper.to_legio_entries(list)) do
		table.insert(entries, legio_entry)
		for _, line in ipairs(view_mapper.to_hierarchy_entries(list[i], legio_entry.order, function(post)
			return miles.dto(post.miles_id)
		end, mandatum_of, names_of)) do
			table.insert(entries, line)
		end
	end
	for _, e in ipairs(entries) do
		e.component = M
	end
	done(entries)
end

function M.card_on_render(e)
	local row = e.live and e.miles_id and miles.live_row(e.miles_id, e.label, e.position)
	if not row then
		return e.card
	end
	local lines = miles.card_lines(row)
	if e.summary then
		return view_mapper.unit_card(lines, e.summary)
	end
	return lines
end

function M.show_conversation_on_select(e)
	if not (e and e.miles_id) then
		return
	end
	local screen = app.screen(ConversationScreen)
	if screen.agent ~= e.miles_id then
		app.update_screen(ConversationScreen, function(v)
			return v:select(e.miles_id)
		end)
	end
end

function M.open_on_enter() end

function M.handled_on_escape()
	return false
end

local function deploy(service, pick, epic)
	if pick.deployed then
		return vim.notify(("%s is already on %s; queueing a second campaign isn't built yet"):format(pick.name, pick.expeditio or "a campaign"), vim.log.levels.WARN)
	end
	local DeployLegioCommand = require("workspace.legio.application.commands.deploy_legio_command")
	service:deploy(DeployLegioCommand.new({ legio_id = pick.legio_id, expeditio_id = epic.id }), function(ok, result)
		if not ok then
			return vim.notify(pick.name .. ": " .. tostring(result), vim.log.levels.WARN)
		end
		vim.notify(("%s deployed on %s · %d milites"):format(pick.name, epic.title, result.size or 0))
	end)
end

function M.deploy_on(epic)
	local service = legiones()
	if not service then
		return vim.notify("no legiones yet", vim.log.levels.WARN)
	end
	local picks = view_mapper.to_deploy_picks(service:legiones())
	require("workspace.legio.presentation.nvim.model_picker").pick(picks, { prompt = "deploy on " .. epic.title, header = "enter deploys that legio" }, function(pick)
		deploy(service, pick, epic)
	end)
end

return M

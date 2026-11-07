local app = require("workspace.workbench.presentation.nvim.app")
local mandata = require("workspace.workflow.presentation.nvim.mandatum_actions")
local view_mapper = require("workspace.workflow.presentation.mappers.expeditio_view_mapper")
local miles_view_mapper = require("workspace.legio.presentation.mappers.miles_view_mapper")
local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")

local M = {}

M.name = "expeditio"

function M.entries_on_refresh(folder, done)
	local name_of, now = mandata.names(), app.now()
	local list = {}
	for i, expeditio in ipairs(mandata.listed(folder)) do
		local entry = view_mapper.to_expeditio_entry(expeditio, 100 + i, name_of, now)
		entry.component = M
		table.insert(list, entry)
	end
	done(list)
end

function M.card_on_render(e)
	return e.card
end

local function contubernium_stack(mandatum_id)
	local rows = miles_view_mapper.to_contubernium_stack_rows(app.services().roster:contubernium_stack(mandatum_id))
	return #rows > 0 and rows or nil
end

function M.thread_on_select(e)
	return view_mapper.to_thread(e.expeditio, mandata.names(), app.now(), contubernium_stack)
end

local function show(kind, id)
	if app.screen(ConversationScreen):show_entry(kind, id) then
		app.update_screen(ConversationScreen, function(v)
			return v:show_entry(kind, id)
		end)
	end
end

function M.show_conversation_on_select(e, item)
	if item and item.mandatum then
		return show("mandatum", item.mandatum.id)
	end
	show("expeditio", e.id)
end

function M.open_on_enter() end

function M.handled_on_escape()
	return false
end

local function warn(ui, why)
	if not ui.batch then
		vim.notify(why, vim.log.levels.WARN)
	end
end

local function selected(e)
	return e and e.component == M and e.expeditio or nil
end

local function add(e, ui)
	local expeditio = selected(e)
	mandata.add_to(expeditio and expeditio.id, ui.folder())
end

local function new_expeditio(_, ui)
	mandata.new_expeditio(ui.folder())
end

local function send(e, _, item)
	if item and item.mandatum then
		return mandata.request_send({ item.mandatum.id }, e.root)
	end
	if #e.waiting == 0 then
		return vim.notify("nothing in " .. e.name .. " is waiting to be picked up", vim.log.levels.WARN)
	end
	mandata.request_send(e.waiting, e.root)
end

local function edit(e, _, item)
	if item and item.mandatum then
		show("mandatum", item.mandatum.id)
		return app.focus("conversation")
	end
	mandata.edit_expeditio(e.expeditio)
end

local function complete(e, ui, item)
	if not (item and item.mandatum) then
		return warn(ui, "open " .. e.name .. " and pick the mandatum that's done")
	end
	mandata.finish(item.mandatum.id)
end

local function drop(e, ui, item)
	if item and item.mandatum then
		if ui.batch or ui.confirm("drop mandatum " .. item.mandatum.title .. "?") then
			mandata.drop(item.mandatum.id)
		end
		return
	end
	if ui.batch or ui.confirm("drop expeditio " .. e.name .. " and its mandata?") then
		mandata.drop_expeditio(e.expeditio)
	end
end

local function deploy(e)
	require("workspace.legio.presentation.nvim.legio_panel").deploy_on(e.expeditio)
end

M.groups = {
	{ "<leader>t", "mandatum" },
	{ "<leader>x", "expeditio" },
	{ "<leader>l", "legio" },
}

M.actions = {
	{ "<leader>ta", add, "add a mandatum", always = true },
	{ "<leader>ts", send, "send a mandatum", single = true },
	{ "<leader>te", edit, "edit a mandatum or expeditio", single = true },
	{ "<leader>tc", complete, "complete a mandatum", single = true },
	{ "<leader>td", drop, "drop a mandatum or expeditio" },
	{ "<leader>xn", new_expeditio, "new expeditio", always = true },
	{ "<leader>ld", deploy, "deploy a legio", single = true },
}

return M

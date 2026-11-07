local wezterm = require("wezterm")

local runtime
local miles_view_mapper = require("workspace.legio.presentation.mappers.miles_view_mapper")
local workspace_view_mapper = require("workspace.workbench.presentation.mappers.workspace_view_mapper")
local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")
local InfraScreen = require("workspace.infra.presentation.infra_screen")
local SidebarScreen = require("workspace.workbench.presentation.sidebar_screen")

local M = {}

function M.use(host)
	runtime = host
	M.paths, M.log = host.paths, host.log
end

local snapshot = { version = false, cache = {} }

function M.snapshot()
	local version = runtime.version()
	if version ~= snapshot.version then
		snapshot = { version = version, cache = {} }
	end
	return snapshot
end

local function cached(key, load)
	local s = M.snapshot()
	if s.cache[key] == nil then
		s.cache[key] = load() or false
	end
	return s.cache[key] or nil
end

local function services()
	return runtime.services()
end

local function roster()
	return services().roster
end

function M.milites()
	return cached("milites", function()
		return roster():all()
	end)
end

function M.milites_in(folder)
	return cached("milites_in" .. tostring(folder), function()
		return roster():running_in(folder)
	end)
end

function M.daemon()
	return cached("daemon", function()
		local dto = roster():agentd_status()
		return dto and miles_view_mapper.to_agentd_health_view_model(dto)
	end)
end

local screen_classes = { conversation = ConversationScreen, sidebar = SidebarScreen, infra = InfraScreen }

function M.screens(workspace)
	return cached("screens" .. tostring(workspace), function()
		local out = {}
		for name, cls in pairs(screen_classes) do
			out[name] = runtime.screen(cls, workspace)
		end
		return out
	end)
end

function M.remove_screens(workspace)
	for _, cls in pairs(screen_classes) do
		runtime.remove_screen(cls, workspace)
	end
end

function M.screen_workspaces()
	local ids = {}
	for _, cls in pairs(screen_classes) do
		for _, id in ipairs(runtime.screen_ids(cls)) do
			ids[id] = true
		end
	end
	return ids
end

function M.workspace(tab_id)
	return cached("workspace" .. tostring(tab_id), function()
		local dto = services().workspace_process:find(tostring(tab_id))
		return dto and workspace_view_mapper.to_workspace_view_model(dto)
	end)
end

function M.workspaces()
	return cached("workspaces", function()
		return workspace_view_mapper.to_workspace_view_models(services().workspace_process:list())
	end)
end

function M.save_workspace(w)
	services().workspace_process:save(workspace_view_mapper.to_save_command(w))
end

function M.remove_workspace(id)
	services().workspace_process:remove(tostring(id))
end

function M.workbench()
	return services().workspace_process
end

function M.pane(id)
	if not id then
		return nil
	end
	local ok, pane = pcall(wezterm.mux.get_pane, id)
	return ok and pane or nil
end

function M.write_file(name, text)
	runtime.write_file(name, text)
end

return M

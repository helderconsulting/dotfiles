local wezterm = require("wezterm")

local shared = wezterm.config_dir .. "/../lua"
package.path = shared .. "/?.lua;" .. shared .. "/?/init.lua;" .. package.path

local paths = require("workspace.paths").new(wezterm.home_dir, os.getenv("XDG_STATE_HOME"))
local store_mod = require("workspace.store")
local models = require("workspace.models")

local M = { paths = paths, models = models }

local made = {}

local fs = {}

function fs.read(path)
	local f = io.open(path)
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	return text
end

function fs.mkdirp(path)
	if not made[path] then
		wezterm.run_child_process({ "/bin/mkdir", "-p", path })
		made[path] = true
	end
end

function fs.write(path, data)
	fs.mkdirp(path:match("^(.*)/[^/]+$"))
	local tmp = path .. ".tmp-wezterm"
	local f = io.open(tmp, "w")
	if f then
		f:write(data)
		f:close()
		os.rename(tmp, path)
	end
end

function fs.append(path, data)
	local f = io.open(path, "a")
	if f then
		f:write(data)
		f:close()
	end
end

function fs.remove(path)
	os.remove(path)
end

function fs.list(dir)
	local ok, entries = pcall(wezterm.read_dir, dir)
	local names = {}
	for _, path in ipairs(ok and entries or {}) do
		table.insert(names, path:match("([^/]+)$"))
	end
	return names
end

M.log = require("workspace.log").new({
	source = "wezterm",
	context = { pid = wezterm.procinfo and wezterm.procinfo.pid() or nil },
	level = os.getenv("WORKSPACE_LOG") or "info",
	path = paths.trace,
	clock = os.time,
	json = { encode = wezterm.serde.json_encode },
	fs = fs,
})

M.store = store_mod.new({
	logger = M.log,
	paths = paths,
	fs = fs,
	json = { encode = wezterm.serde.json_encode, decode = wezterm.serde.json_decode },
	clock = os.time,
	random = math.random,
	locking = false,
})

local snapshot = { version = false, cache = {} }

function M.snapshot()
	local version = fs.read(paths.version)
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

function M.agents()
	return cached("agents", function()
		return require("workspace.agents").all(M.store)
	end)
end

function M.daemon()
	return cached("daemon", function()
		return M.store:get(models.Daemon, models.Daemon.id)
	end)
end

function M.view(workspace)
	return cached("view" .. tostring(workspace), function()
		return M.store:get(models.View, tostring(workspace))
	end)
end

function M.workspace(tab_id)
	return cached("workspace" .. tostring(tab_id), function()
		return M.store:get(models.Workspace, tostring(tab_id))
	end)
end

function M.workspaces()
	return cached("workspaces", function()
		return M.store:all(models.Workspace)
	end)
end

function M.views()
	return cached("views", function()
		return M.store:all(models.View)
	end)
end

function M.review(root)
	return cached("review" .. tostring(root), function()
		return root and M.store:get(models.Review, models.Review.key(root))
	end)
end

function M.save_workspace(w)
	M.store:update(models.Workspace, w.id, function(model)
		for _, f in ipairs(models.Workspace.fields) do
			model[f] = w[f]
		end
	end)
end

function M.remove_workspace(id)
	M.store:remove(models.Workspace, tostring(id))
end

function M.pane(id)
	if not id then
		return nil
	end
	local ok, pane = pcall(wezterm.mux.get_pane, id)
	return ok and pane or nil
end

function M.write_file(name, text)
	fs.write(paths.root .. "/" .. name, text)
end

return M

local wezterm = require("wezterm")

local paths = require("workspace.shared.state.paths").new(wezterm.home_dir, os.getenv("XDG_STATE_HOME"))
local store_mod = require("workspace.shared.state.store")
local composition_root = require("workspace.composition_root")

local M = { paths = paths }

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

M.log = require("workspace.shared.lib.log").new({
	source = "wezterm",
	context = { pid = wezterm.procinfo and wezterm.procinfo.pid() or nil },
	level = os.getenv("WORKSPACE_LOG") or "info",
	path = paths.trace,
	clock = os.time,
	json = { encode = wezterm.serde.json_encode },
	fs = fs,
})

local store = store_mod.new({
	logger = M.log,
	paths = paths,
	fs = fs,
	json = { encode = wezterm.serde.json_encode, decode = wezterm.serde.json_decode },
	clock = os.time,
	random = math.random,
	locking = false,
})

function M.version()
	return fs.read(paths.version)
end

function M.services()
	return composition_root.build(store, { clock = os.time })
end

function M.screen(cls, id)
	return store:get(cls, tostring(id))
end

function M.remove_screen(cls, id)
	store:remove(cls, tostring(id))
end

function M.screen_ids(cls)
	return store:ids(cls)
end

function M.write_file(name, text)
	fs.write(paths.root .. "/" .. name, text)
end

return M

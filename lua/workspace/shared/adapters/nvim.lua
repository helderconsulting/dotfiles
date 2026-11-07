local uv = vim.uv
local paths_mod = require("workspace.shared.state.paths")
local store_mod = require("workspace.shared.state.store")

local M = {}

local function decode(text)
	return vim.json.decode(text, { luanil = { object = true, array = true } })
end

M.json = { encode = vim.json.encode, decode = decode }

M.fs = {}

function M.fs.read(path)
	local fd = uv.fs_open(path, "r", 420)
	if not fd then
		return nil
	end
	local stat = uv.fs_fstat(fd)
	local data = stat and uv.fs_read(fd, stat.size, 0)
	uv.fs_close(fd)
	return data
end

function M.fs.mkdirp(path)
	if uv.fs_stat(path) then
		return
	end
	local parent = vim.fs.dirname(path)
	if parent ~= path then
		M.fs.mkdirp(parent)
	end
	uv.fs_mkdir(path, 493)
end

function M.fs.write(path, data)
	M.fs.mkdirp(vim.fs.dirname(path))
	local tmp = path .. ".tmp" .. uv.os_getpid() .. "-" .. uv.hrtime()
	local fd = assert(uv.fs_open(tmp, "w", 420))
	uv.fs_write(fd, data, 0)
	uv.fs_close(fd)
	assert(uv.fs_rename(tmp, path))
end

function M.fs.append(path, data)
	M.fs.mkdirp(vim.fs.dirname(path))
	local fd = assert(uv.fs_open(path, "a", 420))
	uv.fs_write(fd, data)
	uv.fs_close(fd)
end

function M.fs.remove(path)
	uv.fs_unlink(path)
end

function M.fs.mkdir(path)
	return uv.fs_mkdir(path, 493) == true
end

function M.fs.rmdir(path)
	uv.fs_rmdir(path)
end

function M.fs.list(dir)
	local names = {}
	local handle = uv.fs_scandir(dir)
	while handle do
		local name, kind = uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if kind == "file" then
			table.insert(names, name)
		end
	end
	return names
end

function M.fs.mtime(path)
	local stat = uv.fs_stat(path)
	return stat and (stat.mtime.sec + stat.mtime.nsec / 1e9) or nil
end

function M.fs.sleep(ms)
	uv.sleep(ms)
end

function M.clock()
	local sec, usec = uv.gettimeofday()
	return sec + usec / 1e6
end

math.randomseed(uv.hrtime() % 2147483647 + uv.os_getpid())

M.paths = paths_mod.new(vim.env.HOME, vim.env.XDG_STATE_HOME)

local function rotate()
	local stat = uv.fs_stat(M.paths.trace)
	if stat and stat.size > 5 * 1024 * 1024 then
		uv.fs_rename(M.paths.trace, M.paths.trace .. ".1")
	end
end

function M.logger(source, context)
	rotate()
	return require("workspace.shared.lib.log").new({
		source = source,
		context = context,
		level = vim.env.WORKSPACE_LOG or "info",
		path = M.paths.trace,
		clock = M.clock,
		json = M.json,
		fs = M.fs,
	})
end

function M.new_store(on_change, logger)
	return store_mod.new({
		logger = logger,
		paths = M.paths,
		fs = M.fs,
		json = M.json,
		clock = M.clock,
		random = math.random,
		on_change = on_change,
	})
end

function M.read_log(limit)
	local text = M.fs.read(M.paths.log) or ""
	local lines = {}
	for line in text:gmatch("[^\n]+") do
		table.insert(lines, line)
	end
	local out = {}
	for i = math.max(1, #lines - (limit or 2000) + 1), #lines do
		local ok, entry = pcall(decode, lines[i])
		if ok and type(entry) == "table" then
			table.insert(out, entry)
		end
	end
	return out
end

return M

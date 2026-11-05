local uv = vim.uv
local paths_mod = require("workspace.paths")
local store_mod = require("workspace.store")
local events = require("workspace.events")
local models = require("workspace.models")

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
	return require("workspace.log").new({
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

function M.locate(cwd)
	local function git(...)
		local res = vim.system({ "git", "-C", cwd, ... }, { text = true }):wait()
		return res.code == 0 and vim.trim(res.stdout or "") or nil
	end
	local root = git("rev-parse", "--show-toplevel") or cwd
	local branch = git("branch", "--show-current")
	if not branch or branch == "" then
		branch = git("rev-parse", "--short", "HEAD")
	end
	local dir, common = git("rev-parse", "--path-format=absolute", "--git-dir"), git("rev-parse", "--path-format=absolute", "--git-common-dir")
	return { cwd = cwd, root = root, branch = branch, worktree = dir ~= common and vim.fs.basename(root) or nil }
end

function M.code_tree(root)
	local index = os.tmpname()
	os.remove(index)
	local function git(...)
		return vim.system({ "git", "-C", root, ... }, { text = true, env = { GIT_INDEX_FILE = index } }):wait()
	end
	local ok = git("read-tree", "HEAD").code == 0 and git("add", "-A").code == 0
	local res = ok and git("write-tree") or nil
	os.remove(index)
	return res and res.code == 0 and vim.trim(res.stdout or "") or nil
end

local live

function M.live()
	if live then
		return live
	end
	local logger = M.logger("nvim", {
		role = vim.env.WORKSPACE_ROLE or "editor",
		workspace = vim.env.WORKSPACE_ID,
		pane = tonumber(vim.env.WEZTERM_PANE or ""),
		pid = uv.os_getpid(),
	})
	local bus = events.new(function(topic, err)
		logger.error("bus.handler", { topic = topic, error = tostring(err) })
		vim.schedule(function()
			vim.notify("workspace " .. topic .. ": " .. tostring(err), vim.log.levels.ERROR)
		end)
	end)
	local seen = {}
	local function emit(cls, id, model, transitions, deleted)
		local key = cls.kind .. "/" .. id
		local text = deleted and "" or vim.json.encode(model:to_table())
		if seen[key] == text then
			return
		end
		local old = seen[key]
		seen[key] = text
		bus.emit(cls.kind, { id = id, model = (not deleted) and model or nil, transitions = transitions, deleted = deleted, created = old == nil })
	end
	local store = M.new_store(function(cls, model, transitions, deleted)
		emit(cls, model.id, model, transitions, deleted)
	end, logger)

	local function rescan(cls)
		local present = {}
		for _, id in ipairs(store:ids(cls)) do
			present[id] = true
			local model = store:get(cls, id)
			if model then
				local key = cls.kind .. "/" .. id
				local before = seen[key]
				local prev = before and before ~= "" and cls:new(decode(before)) or nil
				local transitions = {}
				if prev and prev.state ~= model.state then
					table.insert(transitions, { from = prev.state, to = model.state })
				end
				emit(cls, id, model, transitions, false)
			end
		end
		for key, text in pairs(seen) do
			local kind, id = key:match("^([^/]+)/(.+)$")
			if kind == cls.kind and not present[id] and text ~= "" then
				emit(cls, id, nil, {}, true)
			end
		end
	end

	local handles = {}
	local function watch(path, fn)
		M.fs.mkdirp(path)
		local watcher, timer = uv.new_fs_event(), uv.new_timer()
		watcher:start(path, {}, function()
			timer:start(25, 0, vim.schedule_wrap(fn))
		end)
		table.insert(handles, watcher)
		table.insert(handles, timer)
	end

	for _, cls in ipairs(models.stored) do
		for _, id in ipairs(store:ids(cls)) do
			local model = store:get(cls, id)
			if model then
				seen[cls.kind .. "/" .. id] = vim.json.encode(model:to_table())
			end
		end
		watch(M.paths.dir(cls.kind), function()
			rescan(cls)
		end)
	end

	local offset = uv.fs_stat(M.paths.log) and uv.fs_stat(M.paths.log).size or 0
	watch(M.paths.root, function()
		local stat = uv.fs_stat(M.paths.log)
		if not stat or stat.size <= offset then
			offset = stat and stat.size or 0
			return
		end
		local fd = uv.fs_open(M.paths.log, "r", 420)
		local data = fd and uv.fs_read(fd, stat.size - offset, offset) or ""
		if fd then
			uv.fs_close(fd)
		end
		local last = data:match(".*\n()") or 1
		offset = offset + last - 1
		for line in data:sub(1, last - 1):gmatch("[^\n]+") do
			local ok, entry = pcall(decode, line)
			if ok and type(entry) == "table" then
				bus.emit("log", entry)
			end
		end
	end)

	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			for _, h in ipairs(handles) do
				if not h:is_closing() then
					h:close()
				end
			end
		end,
	})

	logger.info("start", { workspace = vim.env.WORKSPACE_ID, pane = vim.env.WEZTERM_PANE, cwd = uv.cwd() })
	live = { store = store, bus = bus, models = models, paths = M.paths, log = logger }
	return live
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

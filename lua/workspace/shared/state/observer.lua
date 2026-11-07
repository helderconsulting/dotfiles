local uv = vim.uv
local nvim = require("workspace.shared.adapters.nvim")
local events = require("workspace.shared.lib.event_bus")

local M = {}

local live

function M.start(kinds)
	if live then
		return live
	end
	local logger = nvim.logger("nvim", {
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
	local class_of = {}
	for _, cls in ipairs(kinds) do
		class_of[cls.kind] = cls
	end
	local function emit(kind, id, record, transitions, deleted)
		local key = kind .. "/" .. id
		local text = deleted and "" or vim.json.encode(record)
		if seen[key] == text then
			return
		end
		local old = seen[key]
		seen[key] = text
		local cls = class_of[kind]
		local model = not deleted and cls and cls:new(record) or nil
		bus.emit(kind, { id = id, record = record, model = model, transitions = transitions, deleted = deleted, created = old == nil })
	end
	local store = nvim.new_store(emit, logger)

	local function rescan(kind)
		local present = {}
		for _, id in ipairs(store:record_ids(kind)) do
			present[id] = true
			local record = store:get_record(kind, id)
			if record then
				local before = seen[kind .. "/" .. id]
				local prev = before and before ~= "" and nvim.json.decode(before) or nil
				local transitions = {}
				if prev and prev.state ~= record.state then
					table.insert(transitions, { from = prev.state, to = record.state })
				end
				emit(kind, id, record, transitions, false)
			end
		end
		for key, text in pairs(seen) do
			local k, id = key:match("^([^/]+)/(.+)$")
			if k == kind and not present[id] and text ~= "" then
				emit(kind, id, nil, {}, true)
			end
		end
	end

	local handles = {}
	local function watch(path, fn)
		nvim.fs.mkdirp(path)
		local watcher, timer = uv.new_fs_event(), uv.new_timer()
		watcher:start(path, {}, function()
			timer:start(25, 0, vim.schedule_wrap(fn))
		end)
		table.insert(handles, watcher)
		table.insert(handles, timer)
	end

	for _, cls in ipairs(kinds) do
		for _, id in ipairs(store:record_ids(cls.kind)) do
			local record = store:get_record(cls.kind, id)
			if record then
				seen[cls.kind .. "/" .. id] = vim.json.encode(record)
			end
		end
		watch(nvim.paths.dir(cls.kind), function()
			rescan(cls.kind)
		end)
	end

	local offset = uv.fs_stat(nvim.paths.log) and uv.fs_stat(nvim.paths.log).size or 0
	watch(nvim.paths.root, function()
		local stat = uv.fs_stat(nvim.paths.log)
		if not stat or stat.size <= offset then
			offset = stat and stat.size or 0
			return
		end
		local fd = uv.fs_open(nvim.paths.log, "r", 420)
		local data = fd and uv.fs_read(fd, stat.size - offset, offset) or ""
		if fd then
			uv.fs_close(fd)
		end
		local last = data:match(".*\n()") or 1
		offset = offset + last - 1
		for line in data:sub(1, last - 1):gmatch("[^\n]+") do
			local ok, entry = pcall(nvim.json.decode, line)
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
	live = { store = store, bus = bus, paths = nvim.paths, log = logger }
	return live
end

return M

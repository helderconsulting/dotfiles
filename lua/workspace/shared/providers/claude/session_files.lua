local nvim = require("workspace.shared.adapters.nvim")

local M = {}

function M.entries()
	local dir = nvim.paths.provider.sessions
	local entries = {}
	for _, name in ipairs(nvim.fs.list(dir)) do
		local text = name:match("%.json$") and nvim.fs.read(dir .. "/" .. name)
		local ok, entry = pcall(nvim.json.decode, text or "")
		if ok and type(entry) == "table" then
			table.insert(entries, entry)
		end
	end
	return entries
end

function M.alive(pid)
	return vim.uv.kill(pid, 0) == 0
end

local function gone(id)
	local alive = false
	for _, entry in ipairs(M.entries()) do
		if entry.sessionId == id and not entry.parkedJobId then
			alive = entry.pid ~= nil and M.alive(entry.pid)
		end
	end
	return not alive
end

function M.when_gone(id, deadline_ms, done)
	if gone(id) then
		return done(true)
	end
	local finished = false
	local watcher, timer = vim.uv.new_fs_event(), vim.uv.new_timer()
	local function finish(ok)
		if finished then
			return
		end
		finished = true
		watcher:close()
		timer:close()
		done(ok)
	end
	watcher:start(nvim.paths.provider.sessions, {}, vim.schedule_wrap(function()
		if gone(id) then
			finish(true)
		end
	end))
	timer:start(deadline_ms, 0, vim.schedule_wrap(function()
		finish(gone(id))
	end))
end

function M.rename(path, id, name)
	local f = io.open(path, "a")
	if f then
		f:write(vim.json.encode({ type = "custom-title", customTitle = name, sessionId = id }), "\n")
		f:close()
	end
end

return M

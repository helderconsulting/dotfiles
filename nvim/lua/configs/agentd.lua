local app = require("configs.app")

local M = {}

local dir = vim.env.HOME .. "/.config/agentd"
local socket = app.paths.root .. "/agentd.sock"
local log_file = app.paths.root .. "/agentd.log"
local log_limit = 1024 * 1024
local launch_wait = 8000
local starting
local holding = false
local drops = {}

local function health(event, reason)
	app.store():update(app.models.Daemon, app.models.Daemon.id, function(d)
		return d:observe(event, reason, app.now())
	end)
end

local function connect(req, on_reply, on_close, on_event)
	local pipe = vim.uv.new_pipe(false)
	pipe:connect(socket, function(err)
		if err then
			pipe:close()
			return vim.schedule(function()
				on_reply(false, { error = err, down = true })
			end)
		end
		local buf, replied = "", false
		pipe:read_start(function(rerr, data)
			if data then
				buf = buf .. data
				local lines = vim.split(buf, "\n", { plain = true })
				buf = table.remove(lines)
				for _, line in ipairs(lines) do
					local ok, msg = pcall(vim.json.decode, line)
					if not replied then
						replied = true
						vim.schedule(function()
							on_reply(ok and msg.ok == true, ok and msg or { error = "bad reply from agentd" })
						end)
					elseif ok and on_event then
						vim.schedule(function()
							on_event(msg)
						end)
					end
				end
				return
			end
			if not pipe:is_closing() then
				pipe:close()
			end
			vim.schedule(function()
				if not replied then
					on_reply(false, { error = rerr or "agentd closed the connection" })
				elseif on_close then
					on_close()
				end
			end)
		end)
		pipe:write(vim.json.encode(req) .. "\n")
	end)
end

function M.installed()
	return vim.uv.fs_stat(dir .. "/node_modules/@anthropic-ai/claude-agent-sdk") ~= nil
end

local function rotate_log()
	local stat = vim.uv.fs_stat(log_file)
	if stat and stat.size > log_limit then
		vim.uv.fs_rename(log_file, log_file .. ".1")
	end
end

local function finish_launch(ok, why)
	if not ok then
		health("fail", why)
	end
	local waiting = starting
	starting = nil
	for _, cb in ipairs(waiting or {}) do
		cb(ok, why)
	end
end

local function launch(done)
	if starting then
		return table.insert(starting, done)
	end
	if not M.installed() then
		return done(false, "agentd isn't installed, run npm install in ~/.config/agentd")
	end
	starting = { done }
	health("launch")
	vim.fn.mkdir(app.paths.root, "p")
	rotate_log()
	local watcher, deadline = vim.uv.new_fs_event(), vim.uv.new_timer()
	local function stop_waiting()
		for _, h in ipairs({ watcher, deadline }) do
			if not h:is_closing() then
				h:close()
			end
		end
	end
	watcher:start(app.paths.root, {}, function(_, name)
		if name ~= "agentd.sock" then
			return
		end
		vim.schedule(function()
			connect({ op = "ping" }, function(ok)
				if ok and starting then
					stop_waiting()
					finish_launch(true)
				end
			end)
		end)
	end)
	deadline:start(launch_wait, 0, vim.schedule_wrap(function()
		stop_waiting()
		connect({ op = "ping" }, function(ok)
			if starting then
				finish_launch(ok, not ok and ("agentd didn't start, see " .. log_file) or nil)
			end
		end)
	end))
	local fd = vim.uv.fs_open(log_file, "a", 420)
	local env = vim.fn.environ()
	env.WEZTERM_PANE, env.WORKSPACE_ROLE, env.WORKSPACE_ID = nil, nil, nil
	local env_list = {}
	for k, v in pairs(env) do
		table.insert(env_list, k .. "=" .. v)
	end
	local handle = vim.uv.spawn("node", { args = { dir .. "/agentd.mjs" }, cwd = dir, detached = true, env = env_list, stdio = { nil, fd, fd } }, function() end)
	if fd then
		vim.uv.fs_close(fd)
	end
	if handle then
		handle:unref()
	end
end

function M.call(req, done)
	connect(req, function(ok, res)
		if ok or not res.down then
			return done(ok, res)
		end
		launch(function(up, why)
			if not up then
				return done(false, { error = why, down = true })
			end
			connect(req, done)
		end)
	end)
end

local function dropped_too_often()
	local now = vim.uv.now()
	drops = vim.tbl_filter(function(t)
		return now - t < 60000
	end, drops)
	table.insert(drops, now)
	return #drops > 3
end

local keep

local function after_old_daemon()
	local watcher = vim.uv.new_fs_event()
	watcher:start(app.paths.root, {}, function(_, name)
		if name == "agentd.sock" and not vim.uv.fs_stat(socket) then
			watcher:close()
			vim.schedule(keep)
		end
	end)
end

local bridge_events = {
	up = { "bridge_back" },
	lost = { "bridge_lost", "the bridge restarted" },
	failed = { "bridge_lost", "the bridge gave up, restart agentd" },
}

function keep()
	local legacy, stopped = false, false
	connect({ op = "hold" }, function(ok, res)
		if ok and not res.keep then
			legacy = true
			return after_old_daemon()
		elseif ok then
			health("connect")
			local b = bridge_events[res.bridge or "up"]
			if b and res.bridge ~= "up" then
				health(b[1], b[2])
			end
			return
		end
		if not res.down then
			holding = false
			return
		end
		launch(function(up)
			if up then
				keep()
			else
				holding = false
			end
		end)
	end, function()
		if legacy then
			return
		end
		if not stopped then
			health("drop")
		end
		if dropped_too_often() then
			holding = false
			health("give_up", "agentd keeps dropping, see " .. log_file)
			return vim.notify("agentd keeps dropping, see " .. log_file, vim.log.levels.WARN)
		end
		keep()
	end, function(msg)
		if msg.event == "bridge" and bridge_events[msg.state] then
			local b = bridge_events[msg.state]
			health(b[1], b[2])
		elseif msg.event == "shutdown" then
			stopped = true
			health("stop", msg.reason)
		end
	end)
end

function M.hold()
	if holding then
		return
	end
	holding = true
	keep()
end

return M

local M = {}

local links = {}
local idle_ms = 30000

local builtin = {
	"add-dir", "agents", "bug", "clear", "compact", "config", "context", "cost", "doctor", "exit", "export",
	"hooks", "ide", "init", "login", "logout", "mcp", "memory", "model", "output-style", "permissions",
	"plugin", "pr-comments", "release-notes", "resume", "review", "rewind", "security-review", "settings",
	"status", "statusline", "terminal-setup", "theme", "todos", "usage", "vim",
}
local quiet = { clear = true, compact = true, init = true }

local function short(session)
	return session:sub(1, 8)
end

local function fire(l, ok)
	local waiting = l.waiting or {}
	l.waiting = {}
	for _, cb in ipairs(waiting) do
		cb(ok and l or nil)
	end
end

local function open(session, on_ready)
	local l = links[session]
	if l and l.job then
		if l.ready then
			return on_ready(l)
		end
		return table.insert(l.waiting, on_ready)
	end
	l = { waiting = { on_ready } }
	links[session] = l
	l.job = vim.fn.jobstart({ "claude", "attach", short(session) }, {
		pty = true,
		width = 120,
		height = 40,
		on_stdout = function(_, data)
			if l.ready or (l.settle and #table.concat(data, "") < 256) then
				return
			end
			l.settle = l.settle or vim.uv.new_timer()
			l.settle:stop()
			l.settle:start(700, 0, vim.schedule_wrap(function()
				if not l.ready then
					l.ready = true
					fire(l, true)
				end
			end))
		end,
		on_exit = function()
			if links[session] == l then
				links[session] = nil
			end
			fire(l, false)
		end,
	})
	if l.job <= 0 then
		links[session] = nil
		return fire(l, false)
	end
	vim.defer_fn(function()
		if not l.ready then
			pcall(vim.fn.jobstop, l.job)
		end
	end, 10000)
end

function M.close(session)
	local l = links[session]
	if l then
		links[session] = nil
		if l.timer then
			l.timer:stop()
		end
		pcall(vim.fn.jobstop, l.job)
	end
end

local function touch(session, l)
	l.timer = l.timer or vim.uv.new_timer()
	l.timer:stop()
	l.timer:start(idle_ms, 0, vim.schedule_wrap(function()
		M.close(session)
	end))
end

function M.keys(session, keys, done)
	open(session, function(l)
		if not l then
			vim.notify("couldn't reach the agent", vim.log.levels.WARN)
			return done and done(false)
		end
		vim.fn.chansend(l.job, keys)
		touch(session, l)
		if done then
			done(true)
		end
	end)
end

function M.send(session, text, done)
	M.keys(session, "\27[200~" .. text .. "\27[201~", function(ok)
		if not ok then
			return done and done(false)
		end
		vim.defer_fn(function()
			M.keys(session, "\r", done)
		end, 300)
	end)
end

function M.commands()
	local names = vim.deepcopy(builtin)
	local home = vim.env.HOME .. "/.claude"
	for _, path in ipairs(vim.fn.glob(home .. "/commands/**/*.md", false, true)) do
		table.insert(names, vim.fn.fnamemodify(path, ":t:r"))
	end
	for _, path in ipairs(vim.fn.glob(home .. "/skills/*/SKILL.md", false, true)) do
		table.insert(names, vim.fs.basename(vim.fs.dirname(path)))
	end
	table.sort(names)
	return vim.fn.uniq(names)
end

function M.is_command(name)
	return vim.fn.exists(":" .. name) ~= 2 and vim.list_contains(M.commands(), name)
end

function M.terminal(win, session, command, on_close)
	M.close(session)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(win, buf)
	local job
	local function close()
		pcall(vim.fn.jobstop, job)
	end
	job = vim.fn.jobstart({ "claude", "attach", short(session) }, {
		term = true,
		on_exit = vim.schedule_wrap(function()
			require("workspace.workbench.presentation.nvim.bufs").wipe(buf)
			on_close()
		end),
	})
	vim.keymap.set("t", "<C-q>", close, { buffer = buf, desc = "back to the conversation" })
	vim.keymap.set("n", "<C-q>", close, { buffer = buf, desc = "back to the conversation" })
	vim.cmd.startinsert()
	if command then
		vim.defer_fn(function()
			vim.fn.chansend(job, command .. "\r")
		end, 1500)
	end
	return buf
end

function M.run(session, line, win, on_close)
	local name = line:match("^(%S+)")
	if name == "exit" then
		M.close(session)
		vim.system({ "claude", "stop", short(session) }, { text = true }, function(res)
			vim.schedule(function()
				vim.notify(res.code == 0 and "agent stopped, it stays resumable from the sidebar" or ("couldn't stop the agent: " .. (res.stderr or "")), res.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
			end)
		end)
		return nil
	end
	if quiet[name] then
		M.send(session, "/" .. line, function(ok)
			if ok then
				vim.notify("/" .. line .. " sent")
			end
		end)
		return nil
	end
	return M.terminal(win, session, "/" .. line, on_close)
end

return M

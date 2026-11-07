local here = vim.fs.dirname(vim.fs.abspath(arg[0]))
local config = vim.fs.dirname(vim.fs.dirname(here))
package.path = config .. "/nvim/lua/?.lua;" .. config .. "/lua/?.lua;" .. config .. "/lua/?/init.lua;" .. package.path

local state = vim.fn.tempname()
vim.env.XDG_STATE_HOME = state
vim.env.WORKSPACE_ID = "test"
vim.env.WORKSPACE_ROLE = "conversation"

local app = require("workspace.workbench.presentation.nvim.app")
local AgentdStatus = require("workspace.legio.domain.agentd_status")
local socket = app.paths.root .. "/agentd.sock"
vim.fn.mkdir(app.paths.root, "p")

local failures, count = {}, 0
local function check(name, cond, detail)
	count = count + 1
	if not cond then
		table.insert(failures, name .. (detail ~= nil and (": " .. vim.inspect(detail)) or ""))
	end
end

local notes = {}
vim.notify = function(msg)
	table.insert(notes, msg)
end

local function wait(cond, ms)
	return vim.wait(ms or 2000, cond, 10)
end

local function health()
	local d = app.store():get(AgentdStatus, AgentdStatus.id)
	return d and d.state, d and d.reason
end

local current

local function fresh()
	if current then
		current.stop_holding()
	end
	package.loaded["workspace.legio.infrastructure.outbound.agentd_client"] = nil
	app.store():remove(AgentdStatus, AgentdStatus.id)
	notes = {}
	local agentd = require("workspace.legio.infrastructure.outbound.agentd_client")
	agentd.installed = function()
		return true
	end
	agentd.command = function()
		return "true", {}, here
	end
	agentd.launch_wait = 300
	current = agentd
	return agentd
end

local Fake = {}
Fake.__index = Fake

function Fake.start(opts)
	local self = setmetatable({ opts = opts or {}, holders = {}, holds = 0, requests = {} }, Fake)
	os.remove(socket)
	self.server = vim.uv.new_pipe(false)
	self.server:bind(socket)
	self.server:listen(16, function()
		local client = vim.uv.new_pipe(false)
		self.server:accept(client)
		local buf = ""
		client:read_start(function(_, data)
			if not data then
				self.holders[client] = nil
				if not client:is_closing() then
					client:close()
				end
				return
			end
			buf = buf .. data
			local line = buf:match("^(.-)\n")
			if not line then
				return
			end
			buf = ""
			local req = vim.json.decode(line)
			table.insert(self.requests, req.op)
			if req.op == "hold" then
				self.holds = self.holds + 1
				if self.opts.legacy then
					return client:write(vim.json.encode({ ok = true }) .. "\n", function()
						client:close()
					end)
				end
				self.holders[client] = true
				client:write(vim.json.encode({ ok = true, keep = true, bridge = self.opts.bridge or "up" }) .. "\n")
			else
				client:write(vim.json.encode({ ok = true, op = req.op }) .. "\n", function()
					client:close()
				end)
			end
		end)
	end)
	return self
end

function Fake:push(event)
	for client in pairs(self.holders) do
		client:write(vim.json.encode(event) .. "\n")
	end
end

function Fake:drop()
	for client in pairs(self.holders) do
		self.holders[client] = nil
		client:close()
	end
end

function Fake:stop()
	self:drop()
	if not self.server:is_closing() then
		self.server:close()
	end
	os.remove(socket)
end

local function test(name, fn)
	local ok, err = pcall(fn)
	check(name, ok, err)
end

test("a call to a running daemon gets its reply", function()
	local fake = Fake.start()
	local agentd = fresh()
	local reply
	agentd.call({ op = "ping" }, function(ok, res)
		reply = { ok = ok, res = res }
	end)
	check("the reply comes back", wait(function()
		return reply ~= nil
	end) and reply.ok and reply.res.op == "ping", reply)
	fake:stop()
end)

test("holding marks the daemon up and follows the bridge", function()
	local fake = Fake.start()
	local agentd = fresh()
	agentd.hold()
	check("the hold reaches the daemon", wait(function()
		return fake.holds == 1
	end))
	check("health is up", wait(function()
		return health() == "up"
	end), health())
	fake:push({ event = "bridge", state = "failed" })
	check("a failed bridge degrades it", wait(function()
		return health() == "degraded"
	end), { health() })
	check("with the reason", select(2, health()) == "the bridge gave up, agentd retries it in a minute")
	fake:push({ event = "bridge", state = "up" })
	check("a returning bridge clears it", wait(function()
		return health() == "up"
	end), health())
	agentd.hold()
	wait(function()
		return false
	end, 100)
	check("holding twice keeps one connection", fake.holds == 1, fake.holds)
	fake:stop()
end)

test("a dropped hold reconnects", function()
	local fake = Fake.start()
	local agentd = fresh()
	agentd.hold()
	wait(function()
		return health() == "up"
	end)
	fake:drop()
	check("it holds again", wait(function()
		return fake.holds == 2
	end), fake.holds)
	check("and is up again", wait(function()
		return health() == "up"
	end), health())
	fake:stop()
end)

test("a shutdown isn't a drop", function()
	local fake = Fake.start()
	local agentd = fresh()
	agentd.hold()
	wait(function()
		return health() == "up"
	end)
	local states = {}
	local off = app.on("daemons", function(change)
		table.insert(states, change.model and change.model.state)
	end)
	fake:push({ event = "shutdown", reason = "code changed" })
	wait(function()
		return health() == "stopped"
	end)
	fake:drop()
	check("it reconnects after the shutdown", wait(function()
		return fake.holds == 2 and health() == "up"
	end), { fake.holds, health() })
	check("without passing through down", not vim.tbl_contains(states, "down"), states)
	off()
	fake:stop()
end)

test("a hold that keeps dropping gives up", function()
	local fake = Fake.start()
	local agentd = fresh()
	agentd.drop_limit = 2
	agentd.hold()
	for i = 1, 3 do
		wait(function()
			return fake.holds == i
		end)
		fake:drop()
	end
	check("it gives up", wait(function()
		return health() == "failed"
	end), { health() })
	check("and says so", vim.iter(notes):any(function(n)
		return n:match("keeps dropping")
	end), notes)
	fake:stop()
end)

test("an old daemon is waited out, not hammered", function()
	local old = Fake.start({ legacy = true })
	local agentd = fresh()
	agentd.hold()
	wait(function()
		return old.holds == 1
	end)
	wait(function()
		return false
	end, 150)
	check("the old daemon is asked once", old.holds == 1, old.holds)
	old:stop()
	local new = Fake.start()
	check("the new daemon is held once the old one's socket goes", wait(function()
		return new.holds >= 1
	end), new.holds)
	new:stop()
end)

test("a down daemon is launched and the call retried", function()
	os.remove(socket)
	local agentd = fresh()
	agentd.command = function()
		return "nvim", { "--clean", "-l", here .. "/fake_agentd.lua", socket }, here
	end
	local reply
	agentd.call({ op = "catalog" }, function(ok, res)
		reply = { ok = ok, res = res }
	end)
	check("the call goes through after the launch", wait(function()
		return reply ~= nil
	end, 8000) and reply.ok and reply.res.op == "catalog", reply)
	check("the launch connects", health() == "up", { health() })
	check("the log file is created", vim.uv.fs_stat(app.paths.root .. "/agentd.log") ~= nil)
	local f = io.open(socket .. ".pid")
	local pid = f and tonumber(f:read("*a"))
	if f then
		f:close()
	end
	check("the fake daemon recorded its pid", pid ~= nil and pid ~= vim.uv.os_getpid())
	if pid and pid ~= vim.uv.os_getpid() then
		vim.uv.kill(pid, "sigterm")
	end
	os.remove(socket)
	os.remove(socket .. ".pid")
end)

test("a launch that never comes up fails with a reason", function()
	os.remove(socket)
	local agentd = fresh()
	agentd.launch_wait = 300
	agentd.command = function()
		return "true", {}, here
	end
	local reply
	agentd.call({ op = "ping" }, function(ok, res)
		reply = { ok = ok, res = res }
	end)
	check("the call fails", wait(function()
		return reply ~= nil
	end) and not reply.ok and reply.res.down, reply)
	check("health records the failure", health() == "failed" and (select(2, health()) or ""):match("didn't start"), { health() })
end)

test("a missing install isn't launched", function()
	os.remove(socket)
	local agentd = fresh()
	agentd.installed = function()
		return false
	end
	local reply
	agentd.call({ op = "ping" }, function(ok, res)
		reply = { ok = ok, res = res }
	end)
	check("it says how to install", wait(function()
		return reply ~= nil
	end) and not reply.ok and reply.res.error:match("npm install"), reply)
end)

test("a big log is rotated on launch", function()
	os.remove(socket)
	local log = app.paths.root .. "/agentd.log"
	local f = io.open(log, "w")
	f:write(string.rep("x", 1024 * 1024 + 10))
	f:close()
	local agentd = fresh()
	agentd.launch_wait = 200
	agentd.command = function()
		return "true", {}, here
	end
	local done = false
	agentd.call({ op = "ping" }, function()
		done = true
	end)
	wait(function()
		return done
	end)
	check("the old log moved aside", vim.uv.fs_stat(log .. ".1") ~= nil and (vim.uv.fs_stat(log) or { size = 0 }).size < 1024)
end)

vim.fn.delete(state, "rf")
if #failures > 0 then
	io.write(("%d/%d checks failed\n"):format(#failures, count))
	for _, f in ipairs(failures) do
		io.write("  ✗ " .. f .. "\n")
	end
	os.exit(1)
end
io.write(("%d checks passed\n"):format(count))
os.exit(0)

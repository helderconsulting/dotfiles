-- The docker view's ports section (configs/docker.lua): the TCP ports this Mac listens on, from your
-- own processes (lsof shows no one else's without root), each named after the container publishing it
-- or else the process holding it. A port reads "local" when only this Mac can reach it and "network"
-- when other machines can too. The content shows who holds it and follows the container's logs; the
-- inspect mode lists its connections.
local M = {}

local function local_only(addr)
	return addr:match("^127%.") or addr:match("^%[::1%]") or addr:match("^localhost")
end

-- Host ports the running containers publish, by port: "0.0.0.0:5432->5432/tcp, [::]:5432->...".
local function published(done)
	if vim.fn.executable("docker") == 0 then
		return done({})
	end
	vim.system({ "docker", "ps", "--format", "{{.Names}}\t{{.Ports}}" }, { text = true }, function(res)
		local out = {}
		for _, line in ipairs(vim.split(res.code == 0 and res.stdout or "", "\n", { trimempty = true })) do
			local name, ports = line:match("^([^\t]+)\t(.*)$")
			for port in (ports or ""):gmatch(":(%d+)%->") do
				out[port] = name
			end
		end
		done(out)
	end)
end

function M.fetch(done)
	published(function(containers)
		vim.system({ "lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn" }, { text = true }, function(res)
			vim.schedule(function()
				local by_port, pid, command = {}, nil, nil
				for line in (res.stdout or ""):gmatch("[^\n]+") do
					local field, value = line:sub(1, 1), line:sub(2)
					if field == "p" then
						pid = tonumber(value)
					elseif field == "c" then
						command = value
					elseif field == "n" then
						local addr, port = value:match("^(.*):(%d+)$")
						if port then
							local e = by_port[port]
							if not e then
								e = { id = port, port = port, pid = pid, process = command, addrs = {} }
								by_port[port] = e
							end
							if not vim.list_contains(e.addrs, addr) then
								table.insert(e.addrs, addr)
							end
						end
					end
				end
				local list = {}
				for port, e in pairs(by_port) do
					e.container = containers[port]
					e.name = port .. " " .. (e.container or e.process or "?")
					local open = vim.iter(e.addrs):any(function(a)
						return not local_only(a)
					end)
					e.word, e.kind = open and "network" or "local", "ok"
					table.insert(list, e)
				end
				done(list)
			end)
		end)
	end)
end

function M.show(e, mode)
	if mode == "inspect" then
		return { "", " connections on " .. e.port, "" }, { "lsof", "-nP", "-iTCP:" .. e.port }
	end
	local lines = { "" }
	local function row(label, value)
		if value and value ~= "" then
			table.insert(lines, (" %-10s %s"):format(label, value))
		end
	end
	row("port", e.port)
	row("listens on", table.concat(e.addrs, "  "))
	row("reachable", e.word == "network" and "from other machines too" or "from this mac only")
	row("container", e.container)
	row("process", e.process and (e.process .. " (pid " .. tostring(e.pid) .. ")"))
	local cmd = e.pid and vim.system({ "ps", "-o", "command=", "-p", tostring(e.pid) }, { text = true }):wait()
	row("command", cmd and cmd.code == 0 and vim.trim(cmd.stdout) or nil)
	table.insert(lines, "")
	if e.container then
		return lines, { "docker", "logs", "--tail", "200", "--follow", e.container }
	end
	return lines
end

M.actions = {
	{
		"<leader>o",
		function(e)
			vim.ui.open("http://localhost:" .. e.port)
		end,
		"open in browser",
	},
	{
		"<leader>y",
		function(e)
			vim.fn.setreg("+", "http://localhost:" .. e.port)
			vim.notify("copied http://localhost:" .. e.port)
		end,
		"copy url",
	},
	{
		"<leader>i",
		function(_, view)
			view.toggle_mode()
		end,
		"toggle details and connections",
	},
	{
		"<leader>s",
		function(e, view)
			-- A container's port goes with the container; otherwise the process holding it ends.
			local what = e.container and ("container " .. e.container) or (e.process .. " (pid " .. e.pid .. ")")
			if not view.confirm("stop " .. what .. "?") then
				return
			end
			if e.container then
				view.run({ "docker", "stop", e.container })
			else
				view.run({ "kill", tostring(e.pid) })
			end
		end,
		"stop what holds the port",
	},
}

return M

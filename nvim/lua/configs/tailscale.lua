-- The docker view's vpn devices section (configs/docker.lua), the devices on the Tailscale VPN: this
-- Mac first, its tab labeled with whether Tailscale is connected, then the tailnet's other devices,
-- online ones before offline ones. Their details fill the content, and the inspect mode pings them.
-- Connecting and disconnecting work from any tab, and whichever tab is current the bar's label is this
-- Mac's VPN state (M.badge): green connected, purple getting there, grey stopped like everything
-- stopped, orange waiting on a login.
local M = {}

local cli = "tailscale"

local function short(dns, host)
	return dns and dns ~= "" and dns:match("^[^.]+") or host or "?"
end

local function seen(time)
	if not time or time:match("^0001") then
		return nil
	end
	return time:gsub("T", " "):gsub("%..*$", ""):gsub("Z$", "")
end

local backend = {
	Running = { "connected", "ok" },
	Starting = { "connecting", "busy" },
	NeedsLogin = { "needs login", "bad" },
	NeedsMachineAuth = { "needs approval", "bad" },
	Stopped = { "stopped", "off" },
}

-- The word while tailscale up or down runs, kept over the refreshes until it finishes.
local pending

-- This Mac's VPN state as of the last fetch.
local mine = { "stopped", "off" }

local function device(p, self)
	return {
		id = p.ID or p.PublicKey or p.HostName,
		name = short(p.DNSName, p.HostName),
		dns = p.DNSName and p.DNSName:gsub("%.$", "") or nil,
		ips = p.TailscaleIPs or {},
		os = p.OS,
		online = p.Online,
		last_seen = seen(p.LastSeen),
		-- A direct connection has an address; otherwise traffic goes through a DERP relay.
		path = p.CurAddr and p.CurAddr ~= "" and ("direct " .. p.CurAddr)
			or (p.Relay and p.Relay ~= "" and ("relay " .. p.Relay)),
		exit_node = p.ExitNode,
		exit_option = p.ExitNodeOption,
		ssh = p.sshHostKeys ~= nil and p.sshHostKeys ~= vim.NIL,
		self = self,
		-- This Mac sorts first, then the devices online, then the rest.
		order = self and 0 or p.Online and 1 or 2,
	}
end

-- The status of the last fetch, for this Mac's details.
local status = {}

function M.fetch(done)
	if vim.fn.executable(cli) == 0 then
		return done({})
	end
	vim.system({ cli, "status", "--json" }, { text = true }, function(res)
		vim.schedule(function()
			local ok, st = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true, array = true } })
			if not ok or type(st) ~= "table" then
				return done({})
			end
			status = st
			local list = {}
			if st.Self then
				local me = device(st.Self, true)
				mine = pending and { pending, "busy" }
					or backend[st.BackendState]
					or { (st.BackendState or "unknown"):lower(), "busy" }
				me.word, me.kind = mine[1], mine[2]
				table.insert(list, me)
			end
			for _, p in pairs(st.Peer or {}) do
				local d = device(p, false)
				if d.exit_node then
					d.word, d.kind = "exit node", "ok"
				elseif d.online then
					d.word, d.kind = "online", "ok"
				else
					d.word, d.kind = "offline", "off"
				end
				table.insert(list, d)
			end
			done(list)
		end)
	end)
end

-- The bar's label for the section: this Mac's VPN state, not the current device's.
function M.badge()
	return mine[1], mine[2]
end

-- For the desktops (configs/desktops.lua) -----------------------------------------------------------

function M.connected()
	return status.BackendState == "Running"
end

local function ipv4(text)
	local a, b, c, d = (text or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if a then
		return ((tonumber(a) * 256 + tonumber(b)) * 256 + tonumber(c)) * 256 + tonumber(d)
	end
end

local function within(ip, cidr)
	local net, bits = cidr:match("^([%d.]+)/(%d+)$")
	net, bits = ipv4(net), tonumber(bits)
	if not (ip and net and bits) then
		return false
	end
	local size = 2 ^ (32 - bits)
	return math.floor(ip / size) == math.floor(net / size)
end

-- How a host is reached over the VPN, or nil when it isn't: a MagicDNS name, a tailnet address, or
-- an address in a subnet a device routes (the route, like 10.10.1.0/24). Known from the last fetch,
-- which lists the routes even while the VPN is stopped.
function M.route(host)
	host = (host or ""):gsub(":%d+$", "")
	if host:match("%.ts%.net$") then
		return "tailnet"
	end
	local ip = ipv4(host)
	if not ip then
		return nil
	end
	if within(ip, "100.64.0.0/10") then
		return "tailnet"
	end
	for _, p in pairs(status.Peer or {}) do
		for _, route in ipairs(p.PrimaryRoutes or {}) do
			if within(ip, route) then
				return route
			end
		end
	end
end

-- Connect this Mac, then done(ok). A login it needs happens in the app, so that opens instead.
function M.up(view, done)
	local state = status.BackendState
	if state == "NeedsLogin" or state == "NeedsMachineAuth" then
		vim.system({ "open", "-a", "Tailscale" })
		vim.notify("log in to tailscale first", vim.log.levels.WARN)
		return done and done(false)
	end
	if pending then
		return done and done(false)
	end
	pending = "connecting"
	view.refresh()
	view.run({ cli, "up" }, {
		done = function(res)
			pending = nil
			if res.code == 0 then
				status.BackendState = "Running"
			end
			if done then
				done(res.code == 0)
			end
		end,
	})
end

function M.show(e, mode)
	if mode == "inspect" and not e.self then
		return { "", " ping " .. e.name, "" }, { cli, "ping", "--c", "10", e.ips[1] or e.name }
	end
	local lines = { "" }
	local function row(label, value)
		if value and value ~= "" then
			table.insert(lines, (" %-10s %s"):format(label, value))
		end
	end
	if e.self then
		row("state", (status.BackendState or ""):lower())
		row("tailnet", status.CurrentTailnet and status.CurrentTailnet.Name)
		for _, p in pairs(status.Peer or {}) do
			if p.ExitNode then
				row("exit node", short(p.DNSName, p.HostName))
			end
		end
		row("login", status.AuthURL)
	end
	row("dns", e.dns)
	row("ips", table.concat(e.ips, "  "))
	row("os", e.os)
	if not e.self then
		row("last seen", not e.online and e.last_seen or nil)
		row("path", e.online and e.path or nil)
		row("ssh", e.ssh and "tailscale ssh" or nil)
		row("exit node", e.exit_node and "in use" or e.exit_option and "offered" or nil)
	end
	for _, warning in ipairs(e.self and status.Health or {}) do
		table.insert(lines, "")
		table.insert(lines, " " .. warning)
	end
	return lines
end

M.actions = {
	{
		"<leader>s",
		function(_, view)
			local state = status.BackendState
			if pending then
				return
			elseif state == "Running" or state == "Starting" then
				pending = "disconnecting"
				view.refresh()
				view.run({ cli, "down" }, {
					done = function()
						pending = nil
					end,
				})
			else
				M.up(view)
			end
		end,
		"connect or disconnect this mac from the vpn",
		always = true,
	},
	{
		"<leader>e",
		function(e, view)
			if e.self then
				return
			end
			-- Tailscale SSH where the device offers it, plain ssh to its MagicDNS name otherwise.
			view.split(e.ssh and { cli, "ssh", e.name } or { "ssh", e.dns or e.ips[1] })
		end,
		"ssh into device",
	},
	{
		"<leader>i",
		function(e, view)
			if not e.self then
				view.toggle_mode()
			end
		end,
		"toggle details and ping",
	},
	{
		"<leader>x",
		function(e, view)
			if e.exit_node then
				view.run({ cli, "set", "--exit-node=" })
			elseif e.exit_option then
				view.run({ cli, "set", "--exit-node=" .. (e.ips[1] or e.name) })
			else
				vim.notify(e.name .. " doesn't offer to be an exit node", vim.log.levels.WARN)
			end
		end,
		"use or stop exit node",
	},
	{
		"<leader>y",
		function(e)
			local ip = e.ips[1]
			if ip then
				vim.fn.setreg("+", ip)
				vim.notify("copied " .. ip)
			end
		end,
		"copy ip",
	},
}

return M

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
			local function toggle(word, cmd)
				pending = word
				view.refresh()
				view.run(cmd, {
					done = function()
						pending = nil
					end,
				})
			end
			if pending then
				return
			elseif state == "Running" or state == "Starting" then
				toggle("disconnecting", { cli, "down" })
			elseif state == "NeedsLogin" or state == "NeedsMachineAuth" then
				-- Logging in happens in the browser, which the app opens.
				vim.system({ "open", "-a", "Tailscale" })
			else
				toggle("connecting", { cli, "up" })
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

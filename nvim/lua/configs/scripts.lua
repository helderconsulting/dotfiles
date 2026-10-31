-- The docker view's scripts section (configs/docker.lua): the scripts of the package.json nearest to
-- Neovim's folder, run with the project's package manager (its packageManager field, else its
-- lockfile, else npm). A script runs in a Neovim terminal the view shows in its content window
-- (view.adopt), so it takes input like in any terminal, and its output stays a buffer to search and
-- yank from. Scripts belong to the view's Neovim and stop with it. Green runs, purple stopping, grey
-- stopped or finished fine or never ran, orange exited with an error.
local M = {}

-- The terminal of each script started in this Neovim, by id: { buf, job, code, stopped, after }.
local terms = {}

local function read(file)
	local f = io.open(file, "r")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	return text
end

local function manager(root, pkg)
	local declared = type(pkg.packageManager) == "string" and pkg.packageManager:match("^(%a+)@")
	if declared then
		return declared
	end
	for _, lock in ipairs({
		{ "pnpm-lock.yaml", "pnpm" },
		{ "bun.lock", "bun" },
		{ "bun.lockb", "bun" },
		{ "yarn.lock", "yarn" },
	}) do
		if vim.fs.find(lock[1], { upward = true, path = root, type = "file" })[1] then
			return lock[2]
		end
	end
	return "npm"
end

-- Look up the ports a running script's processes listen on (configs/ports.lua lists them all) into
-- t.ports, off the main loop; the next refresh shows them. A terminal's job leads its own session, so
-- its processes share its pid as their group.
local function update_ports(t)
	if t.looking then
		return
	end
	t.looking = true
	local pid = t.pid
	vim.system({ "ps", "-axo", "pid=,pgid=" }, { text = true }, function(ps)
		local group = {}
		for line in (ps.stdout or ""):gmatch("[^\n]+") do
			local p, g = line:match("(%d+)%s+(%d+)")
			if tonumber(g) == pid then
				table.insert(group, p)
			end
		end
		if #group == 0 then
			t.looking = false
			return
		end
		local cmd = { "lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", table.concat(group, ","), "-F", "n" }
		vim.system(cmd, { text = true }, function(res)
			local out = {}
			for port in (res.stdout or ""):gmatch("\nn[^\n]*:(%d+)") do
				if not vim.list_contains(out, ":" .. port) then
					table.insert(out, ":" .. port)
				end
			end
			t.ports = #out > 0 and table.concat(out, " ") or nil
			t.looking = false
		end)
	end)
end

local current -- { root, name, pm } of the last fetch

function M.place()
	return current and current.name or "no package.json"
end

function M.fetch(done)
	local file = vim.fs.find("package.json", { upward = true, path = vim.fn.getcwd(), type = "file" })[1]
	local ok, pkg = pcall(vim.json.decode, file and read(file) or "")
	if not ok or type(pkg) ~= "table" then
		current = nil
		return done({})
	end
	local root = vim.fs.dirname(file)
	current = {
		root = root,
		name = type(pkg.name) == "string" and pkg.name or vim.fs.basename(root),
		pm = manager(root, pkg),
	}
	local list = {}
	for script, command in pairs(type(pkg.scripts) == "table" and pkg.scripts or {}) do
		local id = root .. ":" .. script
		local t = terms[id]
		local word, kind = "not run", "off"
		if t and not t.code then
			word, kind = t.stopped and "stopping" or "running", t.stopped and "busy" or "ok"
		elseif t and (t.code == 0 or t.stopped) then
			word, kind = t.stopped and "stopped" or "done", "off"
		elseif t then
			word, kind = "exited " .. t.code, "bad"
		end
		if t and not t.code and not t.stopped then
			update_ports(t)
		end
		local ports = t and not t.code and t.ports or nil
		table.insert(list, {
			id = id,
			name = script,
			ports = ports,
			word = word,
			kind = kind,
			running = t ~= nil and not t.code,
			-- The status line above the terminal follows its state and ports.
			view_key = t and (tostring(t.buf) .. word .. (ports or "")) or "",
			root = root,
			command = tostring(command),
			pm = current.pm,
		})
	end
	done(list)
end

function M.show(e)
	local t = terms[e.id]
	if t and vim.api.nvim_buf_is_valid(t.buf) then
		local bar = { " " .. e.pm .. " run " .. e.name }
		if e.ports then
			table.insert(bar, e.ports)
		end
		table.insert(bar, e.word)
		return {}, nil, { buf = t.buf, bar = table.concat(bar, "  ·  ") }
	end
	return {
		"",
		(" %-10s %s"):format("script", e.command),
		(" %-10s %s"):format("runs", e.pm .. " run " .. e.name),
		(" %-10s %s"):format("in", vim.fn.fnamemodify(e.root, ":~")),
		"",
		" <leader>s starts it here, in a terminal you can type into",
	}
end

local function start(e, view)
	local old = terms[e.id]
	local buf = vim.api.nvim_create_buf(false, true)
	local t = { buf = buf }
	local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
		t.job = vim.fn.jobstart({ e.pm, "run", e.name }, {
			term = true,
			cwd = e.root,
			on_exit = function(_, code)
				t.code = code
				vim.schedule(function()
					if t.after then
						local after = t.after
						t.after = nil
						after()
					end
					view.refresh()
				end)
			end,
		})
	end)
	if not ok or not t.job or t.job <= 0 then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		return vim.notify(e.pm .. " didn't start: " .. tostring(err or t.job), vim.log.levels.ERROR)
	end
	-- Kept: once the job ends Neovim no longer answers for its pid.
	t.pid = vim.fn.jobpid(t.job)
	terms[e.id] = t
	view.adopt(buf)
	if old then
		view.release(old.buf)
	end
	view.refresh()
end

-- Stopping hangs up the terminal, which ends the script with everything it started.
local function stop(e, view, after)
	local t = terms[e.id]
	if not t or t.code then
		return after and after()
	end
	t.stopped, t.after = true, after
	vim.fn.jobstop(t.job)
	view.refresh()
end

M.actions = {
	{
		"<leader>s",
		function(e, view)
			if e.word == "stopping" then
				return
			elseif e.running then
				stop(e, view)
			else
				start(e, view)
			end
		end,
		"start or stop script",
	},
	{
		"<leader>r",
		function(e, view)
			if e.word ~= "stopping" then
				stop(e, view, function()
					start(e, view)
				end)
			end
		end,
		"restart script",
	},
}

return M

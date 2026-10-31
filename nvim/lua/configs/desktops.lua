-- The docker view's desktops section (configs/docker.lua): remote desktops opened with FreeRDP's SDL
-- client (brew install freerdp). Every desktop is an .rdp file in ~/.config/desktops (gitignored), the
-- format Windows App exports its PCs to (select them, Export) and FreeRDP reads, so the settings stay
-- in one place either app can use. Windows App leaves the passwords out of its exports, so they live
-- in the keychain under the nvim-desktops service, one per user like Windows App's user accounts:
-- the desktops logging in as the same user share it, and a desktop without a user has its own. They
-- reach FreeRDP on its stdin (/args-from:stdin), so never in a file or a command line.
-- Sessions run detached with their output in a log under Neovim's state folder, and outlive the view.
local M = {}

M.dir = vim.fs.normalize("~/.config/desktops")
local runs = vim.fn.stdpath("state") .. "/desktops"
local service = "nvim-desktops"

-- Whether the keychain has an account's password, looked up once.
local passwords = {}

-- The desktops of the last fetch.
local desktops = {}

-- The keychain account for a desktop's password: its user, or the desktop itself when it has none.
local function account(user, name)
	user = user and vim.trim(user) or ""
	return user ~= "" and user:lower() or "desktop:" .. name
end

local function path(name, ext)
	return runs .. "/" .. name .. "." .. ext
end

local function read(file)
	local f = io.open(file, "r")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	return text
end

-- An .rdp file's settings by key, lines like "full address:s:host". Windows writes them in UTF-16,
-- which reads as ASCII once the zero bytes and the byte order mark are gone.
local function settings(file)
	local text = (read(file) or ""):gsub("%z", ""):gsub("^\239\187\191", ""):gsub("^\255\254", "")
	local out = {}
	for line in text:gmatch("[^\r\n]+") do
		local key, value = line:match("^([^:]+):%a:(.*)$")
		if key then
			out[key:lower()] = value
		end
	end
	return out
end

-- A session runs while its process group does (FreeRDP can outlive the sh that started it) and
-- it hasn't written its exit code yet.
local function alive(pid)
	return vim.uv.kill(-pid, 0) == 0
end

local function session(name)
	local pid = tonumber(read(path(name, "pid")) or "")
	local code = tonumber(read(path(name, "exit")) or "")
	if pid and not code and alive(pid) then
		return pid
	end
	return nil, code
end

local function check_password(name, done)
	vim.system({ "security", "find-generic-password", "-s", service, "-a", name }, {}, function(res)
		vim.schedule(function()
			passwords[name] = res.code == 0
			done()
		end)
	end)
end

function M.fetch(done)
	local list, missing = {}, {}
	vim.fn.mkdir(M.dir, "p")
	for file, kind in vim.fs.dir(M.dir) do
		local name = file:match("^(.+)%.rdp$")
		if kind == "file" and name then
			local s = settings(M.dir .. "/" .. file)
			local pid, code = session(name)
			local word, state = "closed", "off"
			if pid then
				word, state = "connected", "ok"
			elseif code and code >= 128 then
				-- FreeRDP's exit codes from 128 are connection errors (a refused login, an unreachable
				-- host); the lower ones are ways a session ends.
				word, state = "failed", "bad"
			end
			local key = account(s["username"], name)
			table.insert(list, {
				id = name,
				name = name,
				account = key,
				word = word,
				kind = state,
				pid = pid,
				file = M.dir .. "/" .. file,
				host = s["full address"],
				user = s["username"],
				gateway = s["gatewayhostname"],
			})
			if passwords[key] == nil and not vim.list_contains(missing, key) then
				table.insert(missing, key)
			end
		end
	end
	desktops = list
	if #missing == 0 then
		return done(list)
	end
	local left = #missing
	for _, key in ipairs(missing) do
		check_password(key, function()
			left = left - 1
			if left == 0 then
				done(list)
			end
		end)
	end
end

function M.show(entry)
	local lines = { "" }
	local function row(label, value)
		if value and value ~= "" then
			table.insert(lines, (" %-10s %s"):format(label, value))
		end
	end
	row("host", entry.host)
	row("user", entry.user)
	row("gateway", entry.gateway)
	local shared = 0
	for _, d in ipairs(desktops) do
		shared = shared + (d.account == entry.account and d.name ~= entry.name and 1 or 0)
	end
	local where = shared > 0 and (" (shared with %d other desktop%s)"):format(shared, shared > 1 and "s" or "") or ""
	row("password", (passwords[entry.account] and "in keychain" or "not set") .. where)
	row("file", vim.fn.fnamemodify(entry.file, ":~"))
	table.insert(lines, "")
	vim.fn.mkdir(runs, "p")
	local log = path(entry.name, "log")
	if not vim.uv.fs_stat(log) then
		io.open(log, "w"):close()
	end
	return lines, { "tail", "-n", "200", "-F", log }
end

-- Keychain writes go through security's own prompt on stdin with the password in hex, which keeps it
-- out of every command line.
local function store_password(name, password, done)
	local hex = password:gsub(".", function(c)
		return ("%02x"):format(c:byte())
	end)
	-- In security's quotes a backslash escapes, as in domain\user.
	local quoted = name:gsub("\\", "\\\\"):gsub('"', '\\"')
	local line = ('add-generic-password -U -s %s -a "%s" -X %s\n'):format(service, quoted, hex)
	vim.system({ "security", "-i" }, { stdin = line }, function(res)
		vim.schedule(function()
			passwords[name] = res.code == 0
			if res.code ~= 0 then
				vim.notify("couldn't store the password for " .. name, vim.log.levels.ERROR)
			end
			if done then
				done()
			end
		end)
	end)
end

-- Asks for an account's password, naming the user, or the desktop when it has none.
local function ask_password(key, done)
	local password = vim.fn.inputsecret("password for " .. key:gsub("^desktop:", "") .. ": ")
	if password == "" then
		return
	end
	store_password(key, password, function()
		done(password)
	end)
end

local function connect(e, view, password)
	vim.fn.mkdir(runs, "p")
	os.remove(path(e.name, "exit"))
	local args = { e.file, "/cert:tofu", "+dynamic-resolution", "+clipboard", "/t:" .. e.name }
	if password then
		table.insert(args, "/p:" .. password)
	end
	-- sh stays around to write FreeRDP's exit code; detached, it leads its own process group, which
	-- disconnecting ends whole.
	local ok, proc = pcall(vim.system, {
		"sh",
		"-c",
		'sdl-freerdp /args-from:stdin >"$1" 2>&1; echo $? >"$2"',
		"sh",
		path(e.name, "log"),
		path(e.name, "exit"),
	}, { stdin = true, detach = true })
	if not ok then
		return vim.notify("sdl-freerdp didn't start: " .. proc, vim.log.levels.ERROR)
	end
	proc:write(table.concat(args, "\n") .. "\n")
	proc:write(nil)
	local f = io.open(path(e.name, "pid"), "w")
	f:write(tostring(proc.pid))
	f:close()
	view.refresh()
end

local function open(e, view)
	if vim.fn.executable("sdl-freerdp") == 0 then
		return vim.notify("sdl-freerdp is missing: brew install freerdp", vim.log.levels.ERROR)
	end
	if not passwords[e.account] then
		return ask_password(e.account, function(password)
			connect(e, view, password)
		end)
	end
	vim.system(
		{ "security", "find-generic-password", "-s", service, "-a", e.account, "-w" },
		{ text = true },
		function(res)
			vim.schedule(function()
				connect(e, view, res.code == 0 and res.stdout:gsub("\n$", "") or nil)
			end)
		end
	)
end

-- The .rdp file in a float over the view; writing it refreshes the list, q closes it.
local function edit(file, view)
	local buf = vim.fn.bufadd(file)
	vim.fn.bufload(buf)
	vim.bo[buf].filetype = "dosini"
	local width, height = math.min(80, vim.o.columns - 4), math.min(24, vim.o.lines - 4)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		title = " " .. vim.fn.fnamemodify(file, ":t") .. " ",
		border = "solid",
	})
	vim.keymap.set("n", "q", function()
		pcall(vim.api.nvim_win_close, win, false)
	end, { buffer = buf, nowait = true })
	vim.api.nvim_create_autocmd("BufWritePost", { buffer = buf, callback = view.refresh })
end

local function add(view)
	vim.ui.input({ prompt = "name: " }, function(name)
		name = name and vim.trim(name):gsub('[/\\"]', "") or ""
		if name == "" then
			return
		end
		vim.ui.input({ prompt = "host: " }, function(host)
			if not host or vim.trim(host) == "" then
				return
			end
			vim.ui.input({ prompt = "user (domain\\user): " }, function(user)
				vim.fn.mkdir(M.dir, "p")
				local file = M.dir .. "/" .. name .. ".rdp"
				local lines = { "full address:s:" .. vim.trim(host), "screen mode id:i:1", "prompt for credentials:i:0" }
				if user and vim.trim(user) ~= "" then
					table.insert(lines, "username:s:" .. vim.trim(user))
				end
				vim.fn.writefile(lines, file)
				view.select(name)
				-- A user that already has a password needs none asked.
				local key = account(user, name)
				check_password(key, function()
					if not passwords[key] then
						ask_password(key, view.refresh)
					end
				end)
			end)
		end)
	end)
end

M.actions = {
	{
		"<leader>s",
		function(e, view)
			if e.pid then
				-- FreeRDP ignores the term signal while it is still connecting.
				local pid = e.pid
				vim.uv.kill(-pid, "sigterm")
				vim.defer_fn(function()
					if alive(pid) then
						vim.uv.kill(-pid, "sigkill")
					end
					view.refresh()
				end, 2000)
				vim.defer_fn(view.refresh, 300)
			else
				open(e, view)
			end
		end,
		"connect or disconnect",
	},
	{
		"<leader>a",
		function(_, view)
			add(view)
		end,
		"add desktop",
		always = true,
	},
	{
		"<leader>c",
		function(e, view)
			edit(e.file, view)
		end,
		"edit .rdp settings",
	},
	{
		"<leader>p",
		function(e, view)
			ask_password(e.account, view.refresh)
		end,
		"set password (shared by the user's desktops)",
	},
	{
		"<leader>o",
		function()
			vim.fn.mkdir(M.dir, "p")
			vim.system({ "open", M.dir })
		end,
		"open folder (for windows app exports)",
		always = true,
	},
	{
		"<leader>d",
		function(e, view)
			if vim.fn.confirm("remove desktop " .. e.name .. "?", "&yes\n&no", 2) ~= 1 then
				return
			end
			os.remove(e.file)
			for _, ext in ipairs({ "log", "pid", "exit" }) do
				os.remove(path(e.name, ext))
			end
			-- The password stays while other desktops log in as the same user.
			local shared = false
			for _, d in ipairs(desktops) do
				shared = shared or (d.account == e.account and d.name ~= e.name)
			end
			if not shared then
				vim.system({ "security", "delete-generic-password", "-s", service, "-a", e.account })
				passwords[e.account] = nil
			end
			view.refresh()
		end,
		"remove desktop",
	},
}

return M

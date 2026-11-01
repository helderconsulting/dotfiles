-- The sidebar's agents section (configs/sidebar.lua): the Claude sessions running in WezTerm
-- first, with their state, then the most recent earlier ones from ~/.claude/projects. With a folder
-- (the sidebar's workspace) only the sessions in it or below it (its worktrees) count. A running one
-- switches to its pane; an earlier one opens a workspace in its folder that resumes it (both through
-- WezTerm, configs/workspaces.lua). Earlier sessions can be renamed (a custom-title line, like
-- /rename) and deleted.
local workspaces = require("configs.workspaces")

local M = {}

local projects = vim.env.HOME .. "/.claude/projects"
local count = 20

-- What a session file says about itself, cached until it changes: its title (the /rename one, else
-- Claude's own, else the last prompt), last prompt and folder.
local cache = {}

local function parse(text, mtime)
	local info = { mtime = mtime }
	local custom, ai
	for line in (text or ""):gmatch("[^\n]+") do
		if not info.cwd and line:sub(1, 7) == '"cwd":"' then
			info.cwd = line:match('^"cwd":"(.*)"$')
		elseif line:sub(1, 1) == "{" then
			local ok, entry = pcall(vim.json.decode, line)
			if ok and type(entry) == "table" then
				custom = entry.customTitle or custom
				ai = entry.aiTitle or ai
				info.prompt = entry.lastPrompt or info.prompt
			end
		end
	end
	info.title = custom or ai or info.prompt
	return info
end

local function inside(folder, path)
	return not folder or path == folder or (path or ""):sub(1, #folder + 1) == folder .. "/"
end

-- The newest session files, with the ones that changed read again (one grep each, C locale: they run
-- to megabytes). For a folder only its own project directories: Claude names them after the folder
-- with everything but letters and digits as dashes, so its worktrees' start the same way (a
-- neighbour like ceuz-other does too, which the folder check in fetch leaves out).
local function recent(done, folder)
	local files = {}
	local dirs = folder and (folder:gsub("[^%w]", "-") .. "*") or "*"
	for _, path in ipairs(vim.fn.glob(projects .. "/" .. dirs .. "/*.jsonl", false, true)) do
		local st = vim.uv.fs_stat(path)
		if st then
			table.insert(files, { path = path, mtime = st.mtime.sec })
		end
	end
	table.sort(files, function(a, b)
		return a.mtime > b.mtime
	end)
	files = vim.list_slice(files, 1, count)
	local stale = vim.tbl_filter(function(f)
		return not cache[f.path] or cache[f.path].mtime ~= f.mtime
	end, files)
	local function finish()
		done(files)
	end
	if #stale == 0 then
		return finish()
	end
	local left = #stale
	for _, f in ipairs(stale) do
		vim.system({
			"/usr/bin/grep",
			"-o",
			"-E",
			'"cwd":"[^"]*"|^\\{"type":"(custom-title|ai-title|last-prompt)".*',
			f.path,
		}, { text = true, env = { LC_ALL = "C" } }, function(res)
			vim.schedule(function()
				cache[f.path] = parse(res.stdout, f.mtime)
				left = left - 1
				if left == 0 then
					finish()
				end
			end)
		end)
	end
end

function M.fetch(done, opts)
	local folder = opts and opts.folder
	recent(function(files)
		local list, live = {}, {}
		for _, w in ipairs(workspaces.running()) do
			for _, a in ipairs(inside(folder, w.root) and w.agents or {}) do
				local id = a.session ~= "" and a.session or ("pane " .. a.pane)
				live[id] = true
				table.insert(list, {
					id = id,
					session = a.session ~= "" and a.session or nil,
					name = a.title ~= "" and a.title or a.agent,
					host = workspaces.short(w.root or ""),
					cwd = w.root,
					pane = a.pane,
					agent = a.agent,
					state = a.state,
					word = a.state,
					kind = workspaces.kinds[a.state] or "ok",
					order = 0,
				})
			end
		end
		for i, f in ipairs(files) do
			local info = cache[f.path]
			local id = vim.fn.fnamemodify(f.path, ":t:r")
			if info and info.title and not live[id] and (not folder or (info.cwd and inside(folder, info.cwd))) then
				table.insert(list, {
					id = id,
					session = id,
					path = f.path,
					name = info.title,
					host = info.cwd and workspaces.short(info.cwd) or nil,
					cwd = info.cwd,
					prompt = info.prompt,
					mtime = f.mtime,
					word = workspaces.age(f.mtime),
					kind = "off",
					-- Newest first, which sorting by name would lose.
					order = i,
				})
			end
		end
		-- The running ones' prompts come from their files too, when they are among the newest.
		for _, e in ipairs(list) do
			if e.pane then
				for _, f in ipairs(files) do
					if e.session and f.path:find(e.session, 1, true) then
						e.path, e.mtime = f.path, f.mtime
						e.prompt = cache[f.path] and cache[f.path].prompt
					end
				end
			end
		end
		done(list)
	end, folder)
end


function M.enter(e)
	if e.pane then
		workspaces.request("pane", e.pane)
	elseif e.cwd and vim.fn.isdirectory(e.cwd) == 1 then
		workspaces.request("open", "session:" .. e.session, e.cwd, "here")
	else
		vim.notify("can't resume " .. e.name .. ": " .. (e.cwd and "its folder is gone" or "its session names no folder"), vim.log.levels.WARN)
	end
end

M.actions = {
	{
		"<leader>o",
		M.enter,
		"go to agent, or resume session in a workspace",
		single = true,
	},
	{
		"<leader>n",
		function(e, view)
			if not e.path then
				return vim.notify("no session file to rename", vim.log.levels.WARN)
			end
			vim.ui.input({ prompt = "rename session: ", default = e.name }, function(name)
				if not name or name == "" or name == e.name then
					return
				end
				local line = vim.json.encode({ type = "custom-title", customTitle = name, sessionId = e.session })
				local f = io.open(e.path, "a")
				if f then
					f:write(line, "\n")
					f:close()
				end
				view.refresh()
			end)
		end,
		"rename session",
	},
	{
		"<leader>y",
		function(e)
			if e.session then
				vim.fn.setreg("+", "claude --resume " .. e.session)
				vim.notify("copied claude --resume " .. e.session)
			end
		end,
		"copy resume command",
	},
	{
		"<leader>s",
		function(e, view)
			if not e.pane then
				M.enter(e)
			elseif view.confirm("stop " .. e.name .. "? it stays resumable") then
				view.run({ "wezterm", "cli", "kill-pane", "--pane-id", tostring(e.pane) })
			end
		end,
		"resume or stop session",
	},
	{
		"<leader>d",
		function(e, view)
			local path = e.path or (e.session and vim.fn.glob(projects .. "/*/" .. e.session .. ".jsonl")) or ""
			if path == "" then
				return vim.notify("no session file for " .. e.name, vim.log.levels.WARN)
			end
			if not view.confirm((e.pane and "stop and delete session " or "delete session ") .. e.name .. "?") then
				return
			end
			-- The transcript, and the folder beside it with its subagents and tool output.
			local function remove()
				vim.fs.rm(path, { force = true })
				local dir = path:gsub("%.jsonl$", "")
				if vim.fn.isdirectory(dir) == 1 then
					vim.fs.rm(dir, { recursive = true, force = true })
				end
				cache[path] = nil
				view.refresh()
			end
			-- A running one stops first, and gets a moment to stop writing to its file.
			if e.pane then
				view.run({ "wezterm", "cli", "kill-pane", "--pane-id", tostring(e.pane) }, {
					done = function()
						vim.defer_fn(remove, 500)
					end,
				})
			else
				remove()
			end
		end,
		"delete session",
	},
}

return M

-- The sidebar's workspaces section (configs/sidebar.lua): the projects in ~/Code, like :Projects,
-- plus any other folder a workspace runs in. A workspace is a WezTerm tab holding a project's agents
-- and Neovim (CTRL|ALT w, wezterm/agents.lua); WezTerm lists the running ones in the agent state
-- folder, and a project with one reads as its most pressing agent's state. The actions switch to it,
-- open one, or close it, by asking WezTerm through the workspace user var (M.request).
local M = {}

local projects_root = vim.g.projects_dir or (vim.env.HOME .. "/Code")
local state_dir = (vim.env.XDG_STATE_HOME or (vim.env.HOME .. "/.local/state")) .. "/agent-status"

-- Ask WezTerm for a switch, an open or a close (wezterm/agents.lua lists them); the clock at the end
-- makes a repeat a change.
function M.request(...)
	if not vim.env.WEZTERM_PANE then
		return vim.notify("not running in wezterm", vim.log.levels.WARN)
	end
	local value = table.concat({ ... }, "\t") .. "\t" .. vim.uv.hrtime()
	vim.api.nvim_ui_send(("\27]1337;SetUserVar=workspace=%s\7"):format(vim.base64.encode(value)))
end

function M.short(path)
	if path:sub(1, #projects_root + 1) == projects_root .. "/" then
		return path:sub(#projects_root + 2)
	end
	return vim.fn.fnamemodify(path, ":~")
end

-- The running workspaces: { window, tab, root, editor, docker, panes, agents = { pane, agent,
-- state, title, session } }.
function M.running()
	local f = io.open(state_dir .. "/workspaces")
	if not f then
		return {}
	end
	local text = f:read("*a")
	f:close()
	local ok, list = pcall(vim.json.decode, text)
	return ok and type(list) == "table" and list or {}
end

-- Agent states as the sections' kinds, the most pressing first.
local rank = { message = 5, waiting = 4, working = 3, done = 2, idle = 1 }
M.kinds = { message = "bad", waiting = "bad", working = "busy", done = "ok", idle = "ok" }

function M.age(seconds)
	seconds = os.time() - seconds
	if seconds < 3600 then
		return math.max(1, math.floor(seconds / 60)) .. "m"
	elseif seconds < 86400 then
		return math.floor(seconds / 3600) .. "h"
	end
	return math.floor(seconds / 86400) .. "d"
end

local function in_folder(root, dir)
	return root == dir or root:sub(1, #dir + 1) == dir .. "/"
end

function M.fetch(done)
	local cmd = vim.fn.executable("fd") == 1 and { "fd", "-t", "d", "-d", "2", ".", projects_root }
		or { "find", projects_root, "-mindepth", "1", "-maxdepth", "2", "-type", "d", "-not", "-path", "*/.*" }
	vim.system(cmd, { text = true }, function(res)
		vim.schedule(function()
			local me = tonumber(vim.env.WEZTERM_PANE or "")
			local running = M.running()
			local dirs = {}
			for _, line in ipairs(vim.split(res.stdout or "", "\n", { trimempty = true })) do
				table.insert(dirs, (line:gsub("/$", "")))
			end
			-- A workspace belongs to the deepest project holding its folder (an agent's worktree sits
			-- inside its project); one outside them all is listed under its own folder.
			local by_dir = {}
			for _, w in ipairs(running) do
				local best
				for _, dir in ipairs(dirs) do
					if in_folder(w.root or "", dir) and (not best or #dir > #best) then
						best = dir
					end
				end
				if not best then
					best = w.root or "?"
					table.insert(dirs, best)
				end
				by_dir[best] = by_dir[best] or {}
				table.insert(by_dir[best], w)
			end
			local list = {}
			for _, dir in ipairs(dirs) do
				local e = { id = dir, dir = dir, name = M.short(dir), workspaces = by_dir[dir] or {} }
				local top
				for _, w in ipairs(e.workspaces) do
					e.here = e.here or vim.list_contains(w.panes or {}, me)
					for _, a in ipairs(w.agents or {}) do
						if not top or (rank[a.state] or 0) > (rank[top.state] or 0) then
							top = a
						end
					end
				end
				if #e.workspaces > 0 then
					e.word, e.kind = top and top.state or "open", top and M.kinds[top.state] or "ok"
					e.order = e.here and 0 or 1
					e.host = e.here and "this workspace" or "running"
				else
					e.word, e.kind, e.order = "closed", "off", 2
				end
				table.insert(list, e)
			end
			done(list)
		end)
	end)
end


-- The workspace to act on: the first running one (the one this view is in, when it is).
local function first(e)
	for _, w in ipairs(e.workspaces) do
		if vim.list_contains(w.panes or {}, tonumber(vim.env.WEZTERM_PANE or "")) then
			return w
		end
	end
	return e.workspaces[1]
end

local how = { claude = "a new claude session", resume = "an earlier claude session", nvim = "just nvim" }

local function choose(e)
	vim.ui.select({ "claude", "resume", "nvim" }, {
		prompt = "open " .. e.name .. " with",
		format_item = function(mode)
			return how[mode]
		end,
	}, function(mode)
		if mode then
			M.request("open", mode, e.dir)
		end
	end)
end

-- Enter in the sidebar: go there, or start it with a new claude session.
function M.enter(e)
	local w = first(e)
	if w then
		M.request("tab", w.tab)
	else
		M.request("open", "claude", e.dir)
	end
end

M.actions = {
	{
		"<leader>o",
		function(e)
			local w = first(e)
			if w then
				M.request("tab", w.tab)
			else
				choose(e)
			end
		end,
		"go to workspace, or choose how to open it",
		single = true,
	},
	{
		"<leader>s",
		function(e, view)
			local w = first(e)
			if not w then
				M.request("open", "claude", e.dir)
			elseif view.confirm("close the " .. e.name .. " workspace?") then
				M.request("close", w.tab)
			end
		end,
		"open or close workspace",
	},
	{
		"<leader>a",
		function()
			vim.ui.input({ prompt = "new project in " .. vim.fn.fnamemodify(projects_root, ":~") .. "/" }, function(name)
				if not name or name == "" then
					return
				end
				local dir = projects_root .. "/" .. name
				vim.fn.mkdir(dir, "p")
				M.request("open", "claude", dir)
			end)
		end,
		"add project",
		always = true,
	},
}

return M

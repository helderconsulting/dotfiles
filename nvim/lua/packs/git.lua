-- Returns helpers for leaving git views (the diff view, Neogit) for normal editing; used by the
-- buffer picker and close keys.
local M = {}

vim.pack.add({
	"https://github.com/NeogitOrg/neogit",
	"https://github.com/esmuellert/codediff.nvim",
	"https://github.com/nvim-lua/plenary.nvim",
	"https://github.com/nvim-tree/nvim-web-devicons",
})
local ok_codediff, codediff = pcall(require, "codediff")
if ok_codediff then
	-- Explorer styled like oil: plain tree, every icon in the theme's string green.
	local formatters = require("codediff.ui.explorer.formatters")
	local function oil_icons(format)
		return function(ctx)
			ctx.icon_hl = "String"
			return format(ctx)
		end
	end

	-- Line colors come from DiffAdd/DiffDelete (packs.theme); characters get a stronger tint.
	codediff.setup({
		highlights = {
			line_insert = "DiffAdd",
			line_delete = "DiffDelete",
			char_insert = "#1F5A26",
			char_delete = "#5C3418",
		},
		-- Hunks run on into the next file and stop at the ends, so ALT up / down can step through all
		-- changes and leave Neovim past the first or last one (configs/keymaps.lua).
		diff = {
			cycle_hunks_across_files = true,
			cycle_next_hunk = false,
			cycle_next_file = false,
		},
		explorer = {
			position = "right",
			view_mode = "tree",
			indent_markers = false,
			formatters = {
				file = oil_icons(formatters.file),
				folder = oil_icons(formatters.folder),
			},
			width = 35,
			initial_focus = "modified",
			focus_on_select = true,
		},
	})

	-- An empty buffer instead of codediff's logo page when a working tree has no changes. codediff
	-- recognizes that page by an extmark in its welcome namespace, so the empty buffer keeps one.
	local welcome_ns = vim.api.nvim_create_namespace("codediff-welcome")
	require("codediff.ui.welcome").create_buffer = function()
		local buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].bufhidden = "wipe"
		vim.api.nvim_buf_set_extmark(buf, welcome_ns, 0, 0, {})
		vim.bo[buf].modifiable = false
		-- codediff's own q isn't set on this page; close the view like everywhere else in it.
		vim.keymap.set("n", "q", function()
			require("codediff.ui.lifecycle").close(vim.api.nvim_get_current_tabpage())
		end, { buffer = buf, desc = "close diff view" })
		return buf
	end

	-- codediff only knows "left" and "bottom" panels. The split itself opens on the right fine, but
	-- layout.arrange sizes any non-left panel as a bottom one, so let it size a right panel as left.
	local layout = require("codediff.ui.layout")
	local arrange = layout.arrange
	layout.arrange = function(tabpage)
		local explorer = require("codediff.config").options.explorer
		if explorer.position ~= "right" then
			return arrange(tabpage)
		end
		explorer.position = "left"
		local ok, err = pcall(arrange, tabpage)
		explorer.position = "right"
		if not ok then
			error(err, 0)
		end
	end

	local function wrap(win)
		if win and vim.api.nvim_win_is_valid(win) then
			vim.wo[win].wrap = true
			vim.wo[win].linebreak = true
			vim.wo[win].breakindent = true
		end
	end
	local render = require("codediff.ui.view.render")
	local scrollbind = render.establish_scrollbind
	render.establish_scrollbind = function(orig_win, mod_win, ...)
		scrollbind(orig_win, mod_win, ...)
		wrap(orig_win)
		wrap(mod_win)
	end
	local inline = require("codediff.ui.view.inline_view.render")
	local render_inline = inline.compute_and_render_inline
	inline.compute_and_render_inline = function(...)
		local result = render_inline(...)
		wrap(select(7, ...))
		return result
	end
end

local ok_neogit, neogit = pcall(require, "neogit")
if ok_neogit then
	neogit.setup({})
end
vim.keymap.set("n", "<leader>gp", function()
	if ok_neogit then
		neogit.open()
	else
		vim.notify("neogit not available", vim.log.levels.WARN)
	end
end, { desc = "open git panel" })
-- The live diff of a repo's working tree. Unlike :CodeDiff it also opens when there are no changes
-- yet (codediff's "working tree is clean" page), so it can follow an agent that just started; its
-- auto refresh fills it in as files change. It uses codediff's view directly, falling back to the
-- command if that ever breaks.
local function same_path(a, b)
	return (vim.uv.fs_realpath(a) or a) == (vim.uv.fs_realpath(b) or b)
end

local function git_sync(root, ...)
	local out = vim.system({ "git", "-C", root, ... }, { text = true }):wait()
	return out.code == 0 and vim.trim(out.stdout) or nil
end

local defaults = {}
local function default_branch(root)
	if defaults[root] ~= nil then
		return defaults[root] or nil
	end
	local base = git_sync(root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
	if not base then
		for _, ref in ipairs({ "origin/main", "origin/master", "main", "master" }) do
			if not base and git_sync(root, "rev-parse", "--verify", "--quiet", ref) then
				base = ref
			end
		end
	end
	defaults[root] = base or false
	return base
end

local trunks = { main = true, master = true, development = true, develop = true, dev = true, staging = true, trunk = true }
local function is_trunk(branch, default)
	return trunks[branch] or default ~= nil and (branch == default or default:match("^[^/]+/(.+)$") == branch)
end

local bases = {}
local function base_branch(root, branch)
	branch = branch or git_sync(root, "symbolic-ref", "--short", "-q", "HEAD")
	local rev = branch or git_sync(root, "rev-parse", "HEAD") or "HEAD"
	local key = root .. "\t" .. rev
	if bases[key] ~= nil then
		return bases[key] or nil
	end
	local default = default_branch(root)
	if branch and is_trunk(branch, default) then
		local upstream = git_sync(root, "rev-parse", "--abbrev-ref", branch .. "@{upstream}")
		bases[key] = upstream or false
		return upstream
	end
	local main = (git_sync(root, "worktree", "list", "--porcelain") or ""):match("^worktree ([^\n]+)")
	local out = git_sync(
		root,
		"for-each-ref",
		"--format=%(refname)%09%(refname:short)%09%(ahead-behind:" .. rev .. ")%09%(worktreepath)%09%(symref)",
		"refs/heads",
		"refs/remotes"
	)
	local best
	for line in vim.gsplit(out or "", "\n") do
		local ref, name, ahead, behind, rest = line:match("^([^\t]+)\t([^\t]+)\t(%d+) (%d+)\t?(.*)$")
		local worktree, symref = (rest or ""):match("^([^\t]*)\t?(.*)$")
		local short = ref and (ref:match("^refs/heads/(.+)$") or ref:match("^refs/remotes/[^/]+/(.+)$"))
		local remote = ref and ref:match("^refs/remotes/") ~= nil
		local trunk = short and is_trunk(short, default)
		local skip = not ref or symref ~= "" or short == branch
			or not remote and not trunk and worktree ~= "" and not (main and same_path(worktree, main))
			or not remote and not trunk and behind == "0" and ahead ~= "0"
		if not skip then
			local c = {
				name = name,
				behind = tonumber(behind),
				rank = name == default and 0 or trunk and 1 or remote and 2 or 3,
				ahead = tonumber(ahead),
			}
			if not best or c.behind < best.behind
				or c.behind == best.behind and (c.rank < best.rank or c.rank == best.rank and c.ahead < best.ahead) then
				best = c
			end
		end
	end
	local base = best and best.name or default
	bases[key] = base or false
	return base
end

local function commits_ahead(root, base)
	local out = vim.system({ "git", "-C", root, "rev-list", "--count", base .. "..HEAD" }, { text = true }):wait()
	return out.code == 0 and tonumber(vim.trim(out.stdout)) or 0
end

local opening_branch = false
local function open_diff(root)
	local base = base_branch(root)
	opening_branch = base ~= nil and commits_ahead(root, base) > 0
	if opening_branch then
		vim.cmd("CodeDiff --repo " .. vim.fn.fnameescape(root) .. " " .. base .. "...")
		return
	end
	local ok = pcall(function()
		local path = require("codediff.core.path")
		require("codediff.core.git").get_status_with_line_stats(root, function(err, status)
			vim.schedule(function()
				if err then
					vim.notify(err, vim.log.levels.ERROR)
					return
				end
				if #status.unstaged + #status.staged == 0 and #(status.conflicts or {}) == 0 then
					vim.api.nvim_create_autocmd("User", {
						pattern = "CodeDiffOpen",
						once = true,
						callback = function()
							require("codediff.ui.view").show_welcome(vim.api.nvim_get_current_tabpage())
						end,
					})
				end
				require("codediff.ui.view").create({
					panel = { name = "explorer", data = { status_result = status } },
					git_root = root,
					original = path.empty(),
					modified = path.empty(),
				}, "")
			end)
		end)
	end)
	if not ok then
		vim.cmd("CodeDiff --repo " .. vim.fn.fnameescape(root))
	end
end

vim.api.nvim_create_user_command("CodeDiffLive", function(opts)
	local root = vim.fs.root(opts.args ~= "" and opts.args or vim.fn.getcwd(), ".git")
	if root then
		open_diff(root)
	else
		vim.notify("not in a git repository", vim.log.levels.WARN)
	end
end, { nargs = "?", complete = "dir", desc = "Live diff of a repo, also when it has no changes yet" })

vim.keymap.set("n", "<leader>gd", ":CodeDiffLive<cr>", { desc = "open git diff" })
vim.keymap.set("n", "<leader>gh", ":CodeDiff history %<cr>", { desc = "file history" })
vim.keymap.set("n", "<leader>gH", ":CodeDiff history<cr>", { desc = "repo history" })

-- Follow the focused agent: WezTerm writes the worktree of the last focused agent pane to this
-- file (see wezterm/agents.lua), which may be another worktree or another project. Neovim's cwd
-- follows it, and CodeDiff and Neogit views move to it, but only in the tab on screen: rebuilding a
-- hidden view would flash it over the current one, so other tabs catch up when entered.
local state_dir = (vim.env.XDG_STATE_HOME or (vim.env.HOME .. "/.local/state")) .. "/agent-status"

local target -- worktree root of the last focused agent
local switching = {} -- tabs whose view is being reopened; their tab events must not start another

-- Git views that follow the focused agent. Each tab showing one records the root it shows in
-- vim.t.git_view_root when the view opens (the cwd moves with the agent, so it can't be derived
-- later). switch(tab) replaces the tab's view with one on target and calls done once it is up.
local views = {
	codediff = {
		-- codediff opens asynchronously: open the new view, close the old one once it is up.
		switch = function(tab, done, root)
			vim.api.nvim_create_autocmd("User", {
				pattern = "CodeDiffOpen",
				once = true,
				callback = function()
					require("codediff.ui.lifecycle").close(tab)
					done()
				end,
			})
			open_diff(root or target)
		end,
	},
	neogit = {
		-- Delete the old status buffer (a new one takes its name), open Neogit on target in a new tab,
		-- then close the old tab, all in one step so nothing is redrawn in between.
		switch = function(tab, done)
			for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
				local buf = vim.api.nvim_win_get_buf(win)
				if vim.bo[buf].filetype == "NeogitStatus" then
					vim.api.nvim_buf_delete(buf, { force = true })
				end
			end
			neogit.open({ cwd = target })
			if vim.api.nvim_tabpage_is_valid(tab) then
				vim.cmd(vim.api.nvim_tabpage_get_number(tab) .. "tabclose")
			end
			done()
		end,
	},
}

local group = vim.api.nvim_create_augroup("FollowAgent", { clear = true })
vim.api.nvim_create_autocmd("User", {
	group = group,
	pattern = "CodeDiffOpen",
	callback = function()
		local tab = vim.api.nvim_get_current_tabpage()
		local session = require("codediff.ui.lifecycle").get_session(tab)
		if session and session.git_root then
			vim.t[tab].git_view, vim.t[tab].git_view_root = "codediff", session.git_root
			vim.t[tab].git_view_branch = opening_branch
			M.refresh_info(tab)
		end
	end,
})
-- Recorded once the status buffer is shown: its filetype is set before Neogit opens its tab.
vim.api.nvim_create_autocmd("BufWinEnter", {
	group = group,
	callback = function(ev)
		if vim.bo[ev.buf].filetype == "NeogitStatus" then
			vim.t.git_view, vim.t.git_view_root = "neogit", vim.fs.root(vim.fn.getcwd(), ".git")
			M.refresh_info(vim.api.nvim_get_current_tabpage())
		end
	end,
})

local function git_async(root, args, done)
	vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }, function(res)
		vim.schedule(function()
			done(res.code == 0 and vim.trim(res.stdout) or nil)
		end)
	end)
end

function M.refresh_info(tab)
	local root = vim.api.nvim_tabpage_is_valid(tab) and vim.t[tab].git_view_root
	if not root then
		return
	end
	local base = base_branch(root)
	git_async(root, { "branch", "--show-current" }, function(branch)
		git_async(root, { "rev-list", "--left-right", "--count", (base or "HEAD") .. "...HEAD" }, function(counts)
			local behind, ahead = (counts or ""):match("(%d+)%s+(%d+)")
			git_async(root, { "merge-base", base or "HEAD", "HEAD" }, function(mb)
				git_async(root, { "diff", "--shortstat", mb or "HEAD" }, function(stat)
					git_async(root, { "status", "--porcelain" }, function(porcelain)
						if not vim.api.nvim_tabpage_is_valid(tab) or vim.t[tab].git_view_root ~= root then
							return
						end
						stat = stat or ""
						vim.t[tab].git_info = {
							branch = branch ~= "" and branch or "detached",
							base = base and base:gsub("^origin/", "") or nil,
							ahead = tonumber(ahead) or 0,
							behind = tonumber(behind) or 0,
							files = tonumber(stat:match("(%d+) files? changed")) or 0,
							added = tonumber(stat:match("(%d+) insertions?")) or 0,
							removed = tonumber(stat:match("(%d+) deletions?")) or 0,
							uncommitted = porcelain and porcelain ~= "" and #vim.split(porcelain, "\n") or 0,
						}
						vim.api.nvim_exec_autocmds("User", { pattern = "GitInfo" })
						if vim.t[tab].git_view == "codediff" and not vim.t[tab].git_view_branch and (tonumber(ahead) or 0) > 0
							and tab == vim.api.nvim_get_current_tabpage() and not switching[tab] then
							switching[tab] = true
							views.codediff.switch(tab, function()
								switching[tab] = nil
							end, root)
						end
					end)
				end)
			end)
		end)
	end)
end

vim.uv.new_timer():start(3000, 3000, vim.schedule_wrap(function()
	local tab = vim.api.nvim_get_current_tabpage()
	if vim.t[tab].git_view then
		M.refresh_info(tab)
	end
end))

local function follow_in_current_tab()
	if not target or vim.fn.isdirectory(target) == 0 then
		return
	end
	local tab = vim.api.nvim_get_current_tabpage()
	local view, root = views[vim.t[tab].git_view or ""], vim.t[tab].git_view_root
	if not view or not root or switching[tab] or same_path(root, target) then
		return
	end
	switching[tab] = true
	view.switch(tab, function()
		switching[tab] = nil
	end)
end

local function read_focus()
	local f = io.open(state_dir .. "/focus")
	if not f then
		return nil
	end
	local root = (f:read("*l") or ""):match("^([^\t]+)")
	f:close()
	return root
end

-- Which Neovims follow. Each one belongs to the project it was opened in (by git common dir, so a
-- repo's worktrees are one project) and registers it in nvim-<pane>. An agent attaches to the
-- Neovims of its own project; an agent in a project without one moves only the Neovim used last
-- (the editor file, written on focus), which with a single Neovim is always that one. The sidebar
-- (configs/sidebar.lua, started before this loads) is no editor and stays out of it.
local self_pane = not vim.g.sidebar and vim.env.WEZTERM_PANE or nil
local self_file = self_pane and (state_dir .. "/nvim-" .. self_pane)
local common_dirs = {}

local function common_dir(path)
	if common_dirs[path] == nil then
		local out = vim.system({ "git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir" }, { text = true })
			:wait()
		common_dirs[path] = out.code == 0 and vim.trim(out.stdout) or false
	end
	return common_dirs[path] or nil
end

local function read_line(path)
	local f = io.open(path)
	if not f then
		return nil
	end
	local line = f:read("*l")
	f:close()
	return line
end

local function write_line(path, line)
	local f = io.open(path, "w")
	if f then
		f:write(line, "\n")
		f:close()
	end
end

-- Make this Neovim belong to the project at path (on start, and when a project is opened).
function M.set_home(path)
	if self_file then
		write_line(self_file, (common_dir(path) or "") .. "\t" .. vim.fn.getpid())
	end
end

local function follows(root)
	if not self_pane then
		return true
	end
	local project = common_dir(root)
	local claimed, mine = false, false
	for name, kind in vim.fs.dir(state_dir) do
		local pane = kind == "file" and name:match("^nvim%-(%d+)$")
		if pane then
			local home, pid = (read_line(state_dir .. "/" .. name) or ""):match("^(.*)\t(%d+)$")
			-- A Neovim that crashed left its file behind; its process is gone.
			if home ~= "" and home == project and vim.uv.kill(tonumber(pid), 0) == 0 then
				claimed = true
				mine = mine or pane == self_pane
			end
		end
	end
	if claimed then
		return mine
	end
	local last = read_line(state_dir .. "/editor")
	return not last or last == self_pane
end

-- This file loads during startup (VimEnter), so register right away; a new Neovim is also the one
-- in use. The project is where Neovim was opened: $PWD from the shell that started it, which :cd
-- and :restart leave alone (its cwd and the pane's directory may already follow an agent).
local function mark_used()
	if self_pane then
		write_line(state_dir .. "/editor", self_pane)
	end
end
M.set_home(vim.env.PWD or vim.fn.getcwd())
mark_used()
vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = mark_used })
vim.api.nvim_create_autocmd("VimLeavePre", {
	group = group,
	callback = function()
		if self_file then
			os.remove(self_file)
		end
	end,
})

-- Editing windows of the current tab that show a file of the project left behind (or the empty
-- placeholder of an earlier switch) switch to the new project's files, most recently used first, or
-- an empty placeholder. Other files stay; the old buffers stay loaded for switching back.
local function swap_editor_windows(old_root)
	if vim.t.git_view then
		return
	end
	local files = {}
	for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
		if info.name ~= "" and vim.bo[info.bufnr].buftype == "" and vim.fs.relpath(target, info.name) then
			table.insert(files, info)
		end
	end
	table.sort(files, function(a, b)
		return a.lastused > b.lastused
	end)
	local next_file = 1
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local shown = vim.api.nvim_win_get_buf(win)
		local name = vim.api.nvim_buf_get_name(shown)
		local left_behind = name ~= "" and vim.fs.relpath(old_root, name) and not vim.fs.relpath(target, name)
		if left_behind or vim.b[shown].project_placeholder then
			local buf = files[next_file] and files[next_file].bufnr
			next_file = next_file + 1
			if not buf then
				-- Marked so the next switch replaces it like a file of the project left behind.
				buf = vim.api.nvim_create_buf(false, true)
				vim.bo[buf].bufhidden = "wipe"
				vim.b[buf].project_placeholder = true
			end
			vim.api.nvim_win_set_buf(win, buf)
		end
	end
end

-- Point Neovim at a worktree: its cwd, the editing windows and the git view on screen.
local function go_to(root)
	target = root
	-- Neovim's cwd moves too, so pickers, grep and new files work in that project.
	local old = vim.fn.getcwd()
	if not same_path(old, target) then
		vim.cmd.cd(vim.fn.fnameescape(target))
		swap_editor_windows(old)
	end
	follow_in_current_tab()
end

-- Only focus changes made while Neovim runs count; a stale file must not move a fresh session.
vim.fn.mkdir(state_dir, "p")
-- One write fires several events; act once it settles.
local watcher, debounce = vim.uv.new_fs_event(), vim.uv.new_timer()
watcher:start(state_dir, {}, function(_, filename)
	if filename and vim.fs.basename(filename) == "focus" then
		debounce:start(
			100,
			0,
			vim.schedule_wrap(function()
				local root = read_focus()
				if not root or vim.fn.isdirectory(root) == 0 or not follows(root) then
					return
				end
				go_to(root)
			end)
		)
	end
end)
vim.api.nvim_create_autocmd("TabEnter", {
	group = group,
	callback = function()
		-- Tab switches inside a command (CodeDiff opening its tab) settle first.
		vim.schedule(follow_in_current_tab)
	end,
})

-- The other way round, from Neovim: <leader>gw picks one of the project's worktrees (its branch and
-- the agent working there). Neovim moves right away and tells WezTerm (wezterm/agents.lua, "follow"),
-- which records it as the followed worktree as if its agent was focused, so other Neovims of the
-- project come along and focusing an agent moves them all again.

-- The running agents by worktree (real path): the panes WezTerm lists in workspaces, each with the
-- worktree from its state file (wezterm/bin/agent-status).
local function agents_by_root()
	local by_root = {}
	local f = io.open(state_dir .. "/workspaces")
	local ok, list = pcall(vim.json.decode, f and f:read("*a") or "")
	if f then
		f:close()
	end
	for _, w in ipairs(ok and type(list) == "table" and list or {}) do
		for _, a in ipairs(type(w.agents) == "table" and w.agents or {}) do
			local agent, state, root = (read_line(state_dir .. "/" .. a.pane) or ""):match("^([^\t]*)\t([^\t]*)\t([^\t]*)")
			if root and root ~= "" then
				by_root[vim.uv.fs_realpath(root) or root] = { pane = a.pane, agent = agent, state = state }
			end
		end
	end
	return by_root
end

local function switch_worktree(root)
	go_to(root)
	if vim.env.WEZTERM_PANE then
		local agent = agents_by_root()[vim.uv.fs_realpath(root) or root]
		local branch = vim.trim(vim.system({ "git", "-C", root, "branch", "--show-current" }, { text = true }):wait().stdout or "")
		require("configs.workspaces").request("follow", root, agent and tostring(agent.pane) or "", branch)
	end
end

vim.keymap.set("n", "<leader>gw", function()
	local here = vim.fs.root(target or vim.fn.getcwd(), ".git")
	local out = here and vim.system({ "git", "-C", here, "worktree", "list", "--porcelain" }, { text = true }):wait()
	if not out or out.code ~= 0 then
		return vim.notify("not in a git repository", vim.log.levels.WARN)
	end
	local list = {}
	for line in vim.gsplit(out.stdout, "\n") do
		local path = line:match("^worktree (.+)$")
		if path then
			table.insert(list, { root = path, branch = "" })
		elseif list[#list] then
			list[#list].branch = line:match("^branch refs/heads/(.+)$") or line == "detached" and "detached" or list[#list].branch
		end
	end
	local agents = agents_by_root()
	vim.ui.select(list, {
		prompt = "worktree",
		format_item = function(wt)
			local agent = agents[vim.uv.fs_realpath(wt.root) or wt.root]
			return ("%s %-24s %s%s"):format(
				same_path(wt.root, here) and "●" or " ",
				wt.branch,
				vim.fn.fnamemodify(wt.root, ":~"),
				agent and ("  " .. agent.agent .. " " .. agent.state) or ""
			)
		end,
	}, function(wt)
		if wt then
			switch_worktree(wt.root)
		end
	end)
end, { desc = "switch worktree" })

-- <leader>gb previews a branch the way a GitHub or GitLab merge request shows it: its commits since
-- it left the branch it was cut from (base...branch, from their merge base), nothing checked out.
vim.keymap.set("n", "<leader>gb", function()
	local root = vim.fs.root(target or vim.fn.getcwd(), ".git")
	local default = root and default_branch(root)
	if not default then
		return vim.notify(root and "no default branch found" or "not in a git repository", vim.log.levels.WARN)
	end
	local out = vim.system({
		"git", "-C", root, "for-each-ref", "--sort=-committerdate",
		"--format=%(refname:short)%09%(committerdate:relative)%09%(worktreepath)", "refs/heads",
	}, { text = true }):wait()
	local list = {}
	for line in vim.gsplit(vim.trim(out.stdout or ""), "\n") do
		local branch, age, worktree = line:match("^([^\t]+)\t([^\t]*)\t?(.*)$")
		if branch and branch ~= default and "origin/" .. branch ~= default then
			table.insert(list, { branch = branch, age = age, worktree = worktree })
		end
	end
	if #list == 0 then
		return vim.notify("no branches besides " .. default, vim.log.levels.INFO)
	end
	vim.ui.select(list, {
		prompt = "preview branch",
		format_item = function(b)
			return ("%-32s %-16s %s"):format(b.branch, b.age, b.worktree ~= "" and vim.fn.fnamemodify(b.worktree, ":~") or "")
		end,
	}, function(b)
		if b then
			local base = is_trunk(b.branch, default) and default or base_branch(root, b.branch) or default
			vim.cmd("CodeDiff --repo " .. vim.fn.fnameescape(root) .. " " .. base .. "..." .. b.branch)
		end
	end)
end, { desc = "preview branch" })

-- Leaving git views. Tabs showing the diff view or Neogit are marked in vim.t.git_view (above);
-- every other tab is for editing.

local function last_file_buffer()
	local cwd, best = vim.fn.getcwd(), nil
	for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
		if info.name ~= "" and vim.bo[info.bufnr].buftype == "" and vim.fs.relpath(cwd, info.name) then
			if not best or info.lastused > best.lastused then
				best = info
			end
		end
	end
	return best and best.bufnr
end

-- Go to an editing tab, creating one when every tab is a git view.
function M.editor_tab()
	for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
		if not vim.t[tab].git_view then
			vim.api.nvim_set_current_tabpage(tab)
			return
		end
	end
	vim.cmd("tabnew")
end

-- Close the git view in the current tab. Returns false when the tab is not one.
function M.close_view()
	local tab = vim.api.nvim_get_current_tabpage()
	if vim.t[tab].git_view == "codediff" then
		require("codediff.ui.lifecycle").close(tab)
	elseif vim.t[tab].git_view == "neogit" then
		if #vim.api.nvim_list_tabpages() == 1 then
			vim.cmd("tabnew")
		end
		vim.cmd(vim.api.nvim_tabpage_get_number(tab) .. "tabclose")
	else
		return false
	end
	return true
end

-- ALT up / down in the diff view: step to the next or previous change, running on into the next
-- file. Returns false at the very first or last change, so the move can go on to the window or pane
-- beyond (configs/keymaps.lua). codediff's own next/prev file report success even at the ends, so
-- the edge is worked out here from its explorer and the current file's changes.
function M.step_hunk(direction)
	local lifecycle = require("codediff.ui.lifecycle")
	local tab = vim.api.nvim_get_current_tabpage()
	local session, panel = lifecycle.get_session(tab), lifecycle.get_panel(tab)
	local explorer = panel and panel.view
	if not (session and explorer and explorer.tree) then
		return false
	end
	local files = require("codediff.ui.explorer.tree").get_all_files(explorer.tree)
	local index = 0
	for i, file in ipairs(files) do
		if file.data.path == explorer.data.current_file_path and file.data.group == explorer.data.current_file_group then
			index = i
		end
	end
	local down = direction == "Down"
	local last_file = down and index >= #files or not down and index <= 1

	-- Is there a change past the cursor in this file?
	local changes = session.stored_diff_result and session.stored_diff_result.changes or {}
	local buf = vim.api.nvim_get_current_buf()
	local original = buf == session.original_bufnr and session.layout ~= "inline"
	local win = (buf == session.original_bufnr or buf == session.modified_bufnr) and 0 or session.modified_win
	local line = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_cursor(win)[1] or 1
	local more = false
	for _, change in ipairs(changes) do
		local start = (original and change.original or change.modified).start_line
		if down and start > line or not down and start < line then
			more = true
		end
	end

	if not more and last_file then
		return false
	end
	local codediff = require("codediff")
	if down then
		codediff.next_hunk()
	else
		codediff.prev_hunk()
	end
	return true
end

-- Closing the last git view leaves an empty buffer; show the last used file of the project instead.
vim.api.nvim_create_autocmd("User", {
	group = group,
	pattern = "CodeDiffClose",
	callback = function()
		vim.schedule(function()
			local buf = vim.api.nvim_get_current_buf()
			local empty = vim.api.nvim_buf_get_name(buf) == "" and vim.bo[buf].buftype == ""
				and vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
			local file = empty and not vim.t.git_view and last_file_buffer()
			if file then
				vim.api.nvim_set_current_buf(file)
			end
		end)
	end,
})

return M

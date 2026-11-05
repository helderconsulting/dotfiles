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

	local badges = {
		{ "draft", "ReviewNoteSign" },
		{ "sent", "ReviewSentSign" },
		{ "resolved", "ReviewResolvedSign" },
	}
	local seen_marks = { done = "DiffSeenDone", partly = "DiffSeenPartly", changed = "DiffSeenChanged" }
	local function with_comments(format)
		return function(ctx)
			local row = format(ctx)
			local seen = vim.t.git_view_root and require("configs.diff_progress").badge(vim.t.git_view_root, ctx.path)
			if seen then
				table.insert(row.right, 1, { segments = { { text = seen[1] .. " ", hl = seen_marks[seen[2]] } }, truncate_priority = 5 })
			end
			local ok, review = pcall(require, "configs.review")
			local n = ok and vim.t.git_view_root and review.file_counts(vim.t.git_view_root)[ctx.path]
			if n then
				local segments = {}
				for _, b in ipairs(badges) do
					if n[b[1]] > 0 then
						table.insert(segments, { text = "● " .. n[b[1]] .. " ", hl = b[2] })
					end
				end
				table.insert(row.right, 1, { segments = segments, truncate_priority = 4 })
			end
			return row
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
			layout = require("workspace.models.workspace").diff_layout(vim.o.columns),
			cycle_hunks_across_files = true,
			cycle_next_hunk = false,
			cycle_next_file = false,
		},
		explorer = {
			position = "right",
			view_mode = "tree",
			indent_markers = false,
			formatters = {
				file = with_comments(oil_icons(formatters.file)),
				folder = oil_icons(formatters.folder),
			},
			width = require("workspace.models.workspace").panel_width(vim.o.columns),
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
	render.establish_scrollbind = function(orig_win, mod_win, orig_buf, mod_buf, lines_diff, orig_cursor, mod_cursor)
		orig_cursor, mod_cursor = require("configs.diff_progress").landing(mod_win, lines_diff, orig_cursor, mod_cursor)
		scrollbind(orig_win, mod_win, orig_buf, mod_buf, lines_diff, orig_cursor, mod_cursor)
		wrap(orig_win)
		wrap(mod_win)
	end
	local function track(tabpage)
		vim.schedule(function()
			local ok, err = pcall(require("configs.diff_progress").rendered, tabpage)
			if not ok then
				vim.notify_once("diff progress: " .. tostring(err), vim.log.levels.WARN)
			end
		end)
	end
	local update = render.update
	render.update = function(session, ...)
		local result = update(session, ...)
		track(session.tabpage)
		return result
	end
	local refresh = require("codediff.ui.refresh")
	local ready = refresh.ready
	refresh.ready = function(tabpage, ...)
		local result = ready(tabpage, ...)
		track(tabpage)
		return result
	end
	local inline = require("codediff.ui.view.inline_view.render")
	local render_inline = inline.compute_and_render_inline
	inline.compute_and_render_inline = function(...)
		local result = render_inline(...)
		local win = select(7, ...)
		wrap(win)
		require("configs.diff_progress").land_inline(win)
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

local watch_root

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
			require("configs.diff_progress").restore(tab, session.git_root, M.show_in_diff)
		end
	end,
})
vim.api.nvim_create_autocmd("CursorMoved", {
	group = group,
	callback = function()
		if vim.t.git_view == "codediff" then
			require("configs.diff_progress").moved()
		end
	end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
	group = group,
	callback = function()
		require("configs.diff_progress").flush()
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
	if tab == vim.api.nvim_get_current_tabpage() then
		watch_root(root)
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

local watched = { root = nil, watcher = nil, debounce = vim.uv.new_timer() }

function watch_root(root)
	if watched.root == root then
		return
	end
	if watched.watcher and not watched.watcher:is_closing() then
		watched.watcher:close()
	end
	watched.root, watched.watcher = root, nil
	if not root then
		return
	end
	watched.watcher = vim.uv.new_fs_event()
	watched.watcher:start(root, { recursive = true }, function()
		watched.debounce:start(300, 0, vim.schedule_wrap(function()
			local tab = vim.api.nvim_get_current_tabpage()
			if vim.t[tab].git_view and vim.t[tab].git_view_root == root then
				M.refresh_info(tab)
			end
		end))
	end)
end

local function watch_current_tab()
	local tab = vim.api.nvim_get_current_tabpage()
	watch_root(vim.t[tab].git_view and vim.t[tab].git_view_root or nil)
end

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

vim.api.nvim_create_autocmd("TabEnter", {
	group = group,
	callback = function()
		vim.schedule(follow_in_current_tab)
		vim.schedule(watch_current_tab)
	end,
})

local app = require("configs.app")
local followed, revealed

local function follow_agent(id)
	local agent = app.agent(id)
	local root = agent and agent.root
	if root and root ~= followed and vim.fn.isdirectory(root) == 1 then
		followed = root
		go_to(root)
	end
end

if app.role == "editor" and app.workspace then
	app.on("agents", function(change)
		if change.model and change.id == app.view().agent then
			follow_agent(change.id)
		end
	end)
	app.on("views", function(change)
		if change.id ~= app.workspace or not change.model then
			return
		end
		follow_agent(change.model.agent)
		local reveal = change.model.reveal
		if reveal and reveal.at ~= revealed then
			revealed = reveal.at
			require("configs.review").reveal(reveal)
		end
	end)
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
	local function agent_in(root)
		for _, a in ipairs(app.agents()) do
			if a:is_running() and same_path(a.root, root) then
				return a
			end
		end
	end
	vim.ui.select(list, {
		prompt = "worktree",
		format_item = function(wt)
			local agent = agent_in(wt.root)
			return ("%s %-24s %s%s"):format(same_path(wt.root, here) and "●" or " ", wt.branch, vim.fn.fnamemodify(wt.root, ":~"), agent and ("  " .. agent:display_name() .. " " .. agent:status()) or "")
		end,
	}, function(wt)
		if not wt then
			return
		end
		go_to(wt.root)
		local agent = agent_in(wt.root)
		if agent then
			app.update_view(function(v)
				v:select(agent.id)
			end)
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

function M.show_in_diff(path, line)
	local lifecycle = require("codediff.ui.lifecycle")
	local tab = vim.api.nvim_get_current_tabpage()
	local session, panel = lifecycle.get_session(tab), lifecycle.get_panel(tab)
	local explorer = panel and panel.view
	if not (session and explorer and explorer.tree) then
		return false
	end
	local file_node
	for _, file in ipairs(require("codediff.ui.explorer.tree").get_all_files(explorer.tree)) do
		if file.data.path == path and not file_node then
			file_node = file
		end
	end
	if not file_node then
		return false
	end
	explorer.on_file_select(file_node.data)
	local tries = 0
	local function land()
		local s = lifecycle.get_session(tab)
		local win = s and s.modified_win
		local buf = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
		if buf and vim.api.nvim_buf_get_name(buf):sub(-#path) == path then
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_win_set_cursor(win, { math.min(line, vim.api.nvim_buf_line_count(buf)), 0 })
			return vim.cmd("normal! zz")
		end
		tries = tries + 1
		if tries < 30 then
			vim.defer_fn(land, 50)
		end
	end
	land()
	return true
end

vim.api.nvim_create_autocmd("User", {
	group = group,
	pattern = "ReviewChanged",
	callback = function()
		local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
		local panel = ok and lifecycle.get_panel(vim.api.nvim_get_current_tabpage())
		local tree = panel and panel.view and panel.view.tree
		if tree then
			pcall(tree.render, tree)
		end
	end,
})

-- Closing the last git view leaves an empty buffer; show the last used file of the project instead.
vim.api.nvim_create_autocmd("User", {
	group = group,
	pattern = "CodeDiffClose",
	callback = function(ev)
		require("configs.diff_progress").closed(ev.data and ev.data.tabpage)
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

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
local function open_diff(root)
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

local function same_path(a, b)
	return (vim.uv.fs_realpath(a) or a) == (vim.uv.fs_realpath(b) or b)
end

-- Git views that follow the focused agent. Each tab showing one records the root it shows in
-- vim.t.git_view_root when the view opens (the cwd moves with the agent, so it can't be derived
-- later). switch(tab) replaces the tab's view with one on target and calls done once it is up.
local views = {
	codediff = {
		-- codediff opens asynchronously: open the new view, close the old one once it is up.
		switch = function(tab, done)
			vim.api.nvim_create_autocmd("User", {
				pattern = "CodeDiffOpen",
				once = true,
				callback = function()
					require("codediff.ui.lifecycle").close(tab)
					done()
				end,
			})
			open_diff(target)
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
		end
	end,
})
-- Recorded once the status buffer is shown: its filetype is set before Neogit opens its tab.
vim.api.nvim_create_autocmd("BufWinEnter", {
	group = group,
	callback = function(ev)
		if vim.bo[ev.buf].filetype == "NeogitStatus" then
			vim.t.git_view, vim.t.git_view_root = "neogit", vim.fs.root(vim.fn.getcwd(), ".git")
		end
	end,
})

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
	if f then
		target = (f:read("*l") or ""):match("^([^\t]+)")
		f:close()
	end
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
				read_focus()
				-- Neovim's cwd moves too, so pickers, grep and new files work in that project.
				if target and vim.fn.isdirectory(target) == 1 and not same_path(vim.fn.getcwd(), target) then
					vim.cmd.cd(vim.fn.fnameescape(target))
				end
				follow_in_current_tab()
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

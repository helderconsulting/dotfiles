vim.keymap.set("n", "Q", "<nop>")
vim.keymap.set({ "n" }, "<C-space>i", vim.lsp.buf.hover, { desc = "more info" })
vim.keymap.set({ "n" }, "<C-space>d", vim.diagnostic.open_float, { desc = "show diagnostics" })
vim.keymap.set({ "n" }, "<C-space>r", vim.lsp.buf.rename, { desc = "rename variable" })
vim.keymap.set({ "n", "x" }, "<C-space>a", function()
	local ok, fzf = pcall(require, "fzf-lua")
	local function filter(action)
		return action and action.disabled == nil
	end
	if ok then
		fzf.lsp_code_actions({
			filter = filter,
			winopts = {
				height = 0.35,
				width = 1.00,
				row = 1.00,
				border = "none",
				preview = { hidden = "hidden" },
			},
		})
	else
		vim.lsp.buf.code_action({ filter = filter })
	end
end, { desc = "show code actions" })

vim.keymap.set("n", "<leader>W", ":wa<cr>", { desc = "save all" })
vim.keymap.set("n", "<leader>w", ":w<cr>", { desc = "save file" })
-- Move between windows; at the edge of Neovim hand the move to WezTerm, which continues into the
-- next pane or AeroSpace window (see wezterm/navigate.lua). The counter makes a repeated direction
-- still a change for WezTerm's user-var-changed event. Left and right page through the buffers
-- first, and in the diff view up and down step through the changes first, across files. Past the
-- first or last one they move on to the next window, then out of Neovim.
local nav_count = 0
local function hand_off(direction)
	if vim.env.WEZTERM_PANE then
		nav_count = nav_count + 1
		local value = vim.base64.encode(direction .. ":" .. nav_count)
		vim.api.nvim_ui_send(("\27]1337;SetUserVar=nav=%s\7"):format(value))
	end
end

-- Listed file buffers of the current project, in the order the WezTerm bar shows them
-- (configs/statusbar.lua).
local function project_buffers()
	local list, cwd = {}, vim.fn.getcwd()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local name = vim.api.nvim_buf_get_name(buf)
		if vim.bo[buf].buflisted and vim.bo[buf].buftype == "" and name ~= "" and vim.fs.relpath(cwd, name) then
			table.insert(list, buf)
		end
	end
	return list
end

-- The previous or next buffer from the current one; nil past the first or last, and in a window
-- that isn't showing one of them (oil, help), which moves on to the next window instead.
local function adjacent_buffer(direction)
	local list, current = project_buffers(), vim.api.nvim_get_current_buf()
	for i, buf in ipairs(list) do
		if buf == current then
			return list[direction == "Right" and i + 1 or i - 1]
		end
	end
end

vim.keymap.set("n", "<leader>-", function()
	-- In the diff view or Neogit this closes the view (packs/git.lua) instead of a buffer.
	local ok, git = pcall(require, "packs.git")
	if ok and git.close_view() then
		return
	end
	-- Close the buffer but keep its windows, like closing a tab in an editor: they show the next
	-- buffer of the project that isn't already in another window of the tab (the previous ones past
	-- the last). With none left the windows close, and the last window of the tab gets an empty
	-- buffer. Unsaved changes still ask first ('confirm'). A buffer that is also open in another
	-- window of the tab only loses the current window.
	local buf = vim.api.nvim_get_current_buf()
	-- Open in another window of this tab too (on purpose): close just this window.
	local here = vim.tbl_filter(function(win)
		return vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
	end, vim.fn.win_findbuf(buf))
	if #here > 1 then
		vim.api.nvim_win_close(0, false)
		return
	end
	local others = vim.tbl_filter(function(b)
		return b ~= buf
	end, project_buffers())
	local index = 1
	for i, b in ipairs(project_buffers()) do
		if b == buf then
			index = math.min(i, #others)
		end
	end
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		local wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))
		local shown = {}
		for _, w in ipairs(wins) do
			shown[vim.api.nvim_win_get_buf(w)] = true
		end
		-- From the closed buffer's place onward, then back before it.
		local replacement
		for i = index, #others do
			replacement = replacement or (not shown[others[i]] and others[i])
		end
		for i = index - 1, 1, -1 do
			replacement = replacement or (not shown[others[i]] and others[i])
		end
		if replacement then
			vim.api.nvim_win_set_buf(win, replacement)
		elseif #wins > 1 then
			vim.api.nvim_win_close(win, false)
		else
			vim.api.nvim_win_set_buf(win, others[index] or vim.api.nvim_create_buf(true, false))
		end
	end
	pcall(vim.cmd.bdelete, buf)
end, { desc = "close buffer" })

local function move(wincmd, direction)
	return function()
		if
			vim.t.git_view == "codediff"
			and (direction == "Up" or direction == "Down")
			and require("packs.git").step_hunk(direction)
		then
			return
		end
		-- Left and right page through the buffers first, like up and down step through changes in the
		-- diff view; past the first or last one they move to the next window, then out of Neovim.
		local buf = not vim.t.git_view and (direction == "Left" or direction == "Right") and adjacent_buffer(direction)
		if buf then
			vim.api.nvim_set_current_buf(buf)
			return
		end
		local win = vim.api.nvim_get_current_win()
		vim.cmd.wincmd(wincmd)
		if vim.api.nvim_get_current_win() ~= win then
			return
		end
		-- A window outside the buffer list (oil, help) sits before it: right enters it at the first.
		local first = direction == "Right" and not vim.t.git_view and not vim.tbl_contains(project_buffers(), vim.api.nvim_get_current_buf())
			and project_buffers()[1]
		if first then
			vim.api.nvim_set_current_buf(first)
		else
			hand_off(direction)
		end
	end
end
vim.keymap.set("n", "<M-Left>", move("h", "Left"), { desc = "move to left window" })
vim.keymap.set("n", "<M-Right>", move("l", "Right"), { desc = "move to right window" })
vim.keymap.set("n", "<M-Up>", move("k", "Up"), { desc = "move to window above" })
vim.keymap.set("n", "<M-Down>", move("j", "Down"), { desc = "move to window below" })

-- A new agent session next to Neovim, in its project: like CTRL|ALT Enter in WezTerm, a split to the
-- right running claude, then a shell so the pane stays when the agent exits. Started as the shell's
-- command rather than typed in, since zsh prompts start in vi normal mode. Neovims of the project
-- follow it (packs/git.lua).
vim.keymap.set("n", "<leader>n", function()
	if not vim.env.WEZTERM_PANE then
		vim.notify("new agent: not running in WezTerm", vim.log.levels.WARN)
		return
	end
	local shell = vim.env.SHELL or "zsh"
	vim.system({
		"wezterm", "cli", "split-pane", "--right",
		"--pane-id", vim.env.WEZTERM_PANE,
		"--cwd", vim.fn.getcwd(),
		"--", shell, "-ic", "claude; exec " .. shell,
	}, { text = true }, function(res)
		if res.code ~= 0 then
			vim.schedule(function()
				vim.notify("new agent: " .. (res.stderr or "split failed"), vim.log.levels.ERROR)
			end)
		end
	end)
end, { desc = "new agent session" })

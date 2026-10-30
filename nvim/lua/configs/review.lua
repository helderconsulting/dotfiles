-- Review comments: note lines in any buffer (including CodeDiff panes), then send them all as one
-- prompt to an agent running in another WezTerm pane. Agent panes are found through the state
-- files written by ~/.config/wezterm/bin/agent-status.
local M = {}

local ns = vim.api.nvim_create_namespace("review")
local state_dir = (vim.env.XDG_STATE_HOME or (vim.env.HOME .. "/.local/state")) .. "/agent-status"

---@class ReviewComment
---@field key string buffer name the comment belongs to
---@field path string path shown to the agent, relative to the repo root
---@field rev? string revision for the old side of a diff
---@field line1 integer
---@field line2 integer
---@field text string
---@field buf? integer
---@field mark? integer

---@type ReviewComment[]
local comments = {}

-- Where a buffer's lines live: a working-tree file, or a file at a revision in a CodeDiff pane.
local function location(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	if name:match("^codediff://") then
		local root, rev, path = require("codediff.core.virtual_file").parse_url(name)
		if path then
			return { key = name, path = path, rev = rev, root = root }
		end
	elseif name ~= "" and vim.bo[buf].buftype == "" then
		local root = vim.fs.root(name, ".git")
		local path = root and vim.fs.relpath(root, name) or vim.fn.fnamemodify(name, ":~:.")
		return { key = name, path = path, root = root }
	end
end

-- Read line numbers back from the extmarks, which follow edits to the buffer.
local function sync(c)
	if not (c.buf and c.mark and vim.api.nvim_buf_is_valid(c.buf)) then
		return
	end
	local pos = vim.api.nvim_buf_get_extmark_by_id(c.buf, ns, c.mark, { details = true })
	if pos[1] then
		c.line1 = pos[1] + 1
		c.line2 = (pos[3].end_row or pos[1]) + 1
	end
end

-- Word-wrap a comment to the width left of the window showing it; virtual lines never wrap.
local function wrap(text, width)
	local out = {}
	for _, para in ipairs(vim.split(text, "\n")) do
		local line = ""
		for word in para:gmatch("%S+") do
			if line == "" then
				line = word
			elseif vim.fn.strdisplaywidth(line .. " " .. word) <= width then
				line = line .. " " .. word
			else
				table.insert(out, line)
				line = word
			end
		end
		table.insert(out, line)
	end
	return out
end

local prefix = "  ┃ "

-- Two extmarks per comment: one spanning the range (sign, tint, tracks edits) and one on the
-- last line that carries the comment text below the range.
local function render(c)
	sync(c)
	for _, id in ipairs({ c.mark, c.note }) do
		pcall(vim.api.nvim_buf_del_extmark, c.buf, ns, id)
	end
	local win = vim.fn.bufwinid(c.buf)
	local width = 80
	if win ~= -1 then
		width = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
	end
	width = math.max(math.min(width, 100) - vim.fn.strdisplaywidth(prefix) - 1, 20)
	local virt_lines = {}
	for _, line in ipairs(wrap(c.text, width)) do
		table.insert(virt_lines, { { prefix, "ReviewNoteSign" }, { line, "ReviewNote" } })
	end
	local last = vim.api.nvim_buf_line_count(c.buf)
	local row1, row2 = math.min(c.line1, last) - 1, math.min(c.line2, last) - 1
	c.mark = vim.api.nvim_buf_set_extmark(c.buf, ns, row1, 0, {
		end_row = row2,
		sign_text = "▍",
		sign_hl_group = "ReviewNoteSign",
		line_hl_group = "ReviewNoteLine",
		invalidate = true,
	})
	c.note = vim.api.nvim_buf_set_extmark(c.buf, ns, row2, 0, {
		virt_lines = virt_lines,
		invalidate = true,
	})
end

local function comment_at(buf, lnum)
	for i, c in ipairs(comments) do
		sync(c)
		if c.buf == buf and lnum >= c.line1 and lnum <= c.line2 then
			return c, i
		end
	end
end

-- Small floating editor that wraps and grows with its text, like a textarea.
-- <C-s> or <CR> in normal mode saves, <C-y> sends right away, q or <Esc> in normal mode cancels.
-- on_save(text, send_now)
local function edit(title, initial, on_save)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].filetype = "markdown"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial or "", "\n"))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "cursor",
		row = 1,
		col = 0,
		width = math.min(80, vim.o.columns - 4),
		height = 4,
		-- Blank border in the popup's own color: padding on every side, with the file path in
		-- the top edge and the key hints in the bottom edge.
		border = { " ", " ", " ", " ", " ", " ", " ", " " },
		title = { { "  " .. title, "ReviewNoteTitle" } },
		title_pos = "left",
		footer = { { "<C-s> save · <C-y> send · q cancel ", "ReviewNoteHint" } },
		footer_pos = "right",
		style = "minimal",
	})
	-- The float copies window options from where it opened; diff panes turn wrapping off.
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	-- An empty sign column widens the left padding; the title is indented to line up with the text.
	-- A blank winbar separates the path from the text.
	vim.wo[win].signcolumn = "yes:1"
	vim.wo[win].winbar = " "
	vim.wo[win].winhighlight = "Normal:ReviewNoteLine,EndOfBuffer:ReviewNoteLine,SignColumn:ReviewNoteLine,"
		.. "WinBar:ReviewNoteLine,FloatBorder:ReviewNoteLine"
	-- Winbar line plus wrapped text, between 3 and 12 text lines.
	local function fit()
		if vim.api.nvim_win_is_valid(win) then
			local lines = vim.api.nvim_win_text_height(win, {}).all
			vim.api.nvim_win_set_height(win, math.min(math.max(lines, 3), 12) + 1)
		end
	end
	fit()
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = buf, callback = fit })
	local function close()
		vim.cmd.stopinsert()
		pcall(vim.api.nvim_win_close, win, true)
	end
	local function save(send_now)
		local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
		close()
		-- stopinsert only takes effect once this mapping returns; acting right away would hand the
		-- pending mode change to the fzf picker that sending opens, leaving it unable to take input.
		vim.schedule(function()
			on_save(text, send_now)
		end)
	end
	vim.keymap.set({ "n", "i" }, "<C-s>", function()
		save(false)
	end, { buffer = buf })
	vim.keymap.set("n", "<CR>", function()
		save(false)
	end, { buffer = buf })
	vim.keymap.set({ "n", "i" }, "<C-y>", function()
		save(true)
	end, { buffer = buf })
	vim.keymap.set("n", "q", close, { buffer = buf })
	vim.keymap.set("n", "<Esc>", close, { buffer = buf })
	if not initial or initial == "" then
		vim.cmd.startinsert()
	end
end

function M.add(line1, line2)
	local buf = vim.api.nvim_get_current_buf()
	local loc = location(buf)
	if not loc then
		vim.notify("review: this buffer is not a file", vim.log.levels.WARN)
		return
	end
	local existing = comment_at(buf, line1)
	local range = line1 == line2 and tostring(line1) or (line1 .. "-" .. line2)
	edit(loc.path .. ":" .. range, existing and existing.text, function(text, send_now)
		if send_now then
			if text == "" then
				return
			end
			local c = vim.tbl_extend("force", loc, { line1 = line1, line2 = line2, text = text, buf = buf })
			-- A queued comment that gets sent on its own leaves the queue once it is out.
			M.send_comments({ c }, function()
				if existing then
					M.delete_at(buf, line1)
				end
			end)
			return
		end
		if existing then
			if text == "" then
				M.delete_at(buf, line1)
			else
				existing.text = text
				render(existing)
			end
			return
		end
		if text == "" then
			return
		end
		local c = vim.tbl_extend("force", loc, { line1 = line1, line2 = line2, text = text, buf = buf })
		table.insert(comments, c)
		render(c)
	end)
end

function M.delete_at(buf, lnum)
	local c, i = comment_at(buf, lnum)
	if not c then
		return
	end
	pcall(vim.api.nvim_buf_del_extmark, buf, ns, c.mark)
	pcall(vim.api.nvim_buf_del_extmark, buf, ns, c.note)
	table.remove(comments, i)
end

function M.clear()
	for _, c in ipairs(comments) do
		if c.buf and vim.api.nvim_buf_is_valid(c.buf) then
			vim.api.nvim_buf_clear_namespace(c.buf, ns, 0, -1)
		end
	end
	comments = {}
end

function M.list()
	local items = {}
	for _, c in ipairs(comments) do
		sync(c)
		local valid = c.buf and vim.api.nvim_buf_is_valid(c.buf)
		table.insert(items, {
			bufnr = valid and c.buf or nil,
			filename = not valid and not c.rev and c.key or nil,
			lnum = c.line1,
			end_lnum = c.line2,
			text = c.text:gsub("\n", " ⏎ "),
		})
	end
	vim.fn.setqflist({}, " ", { title = "Review comments", items = items })
	require("packs.fzf")
	require("fzf-lua").quickfix()
end

-- Comments as one prompt: location, the code it points at, then the note.
local function prompt(list)
	local parts = { "Review comments on the current changes:" }
	for i, c in ipairs(list) do
		sync(c)
		local range = c.line1 == c.line2 and tostring(c.line1) or (c.line1 .. "-" .. c.line2)
		local where = c.path .. ":" .. range
		if c.rev then
			where = where .. " (old version at " .. c.rev:sub(1, 12) .. ")"
		end
		local block = { ("%d. %s"):format(i, where) }
		if c.buf and vim.api.nvim_buf_is_valid(c.buf) then
			local code = vim.api.nvim_buf_get_lines(c.buf, c.line1 - 1, c.line2, false)
			table.insert(block, "```" .. vim.bo[c.buf].filetype)
			vim.list_extend(block, code)
			table.insert(block, "```")
		end
		table.insert(block, c.text)
		table.insert(parts, table.concat(block, "\n"))
	end
	return table.concat(parts, "\n\n")
end

local claude_spinner = { ["◐"] = true, ["◓"] = true, ["◑"] = true, ["◒"] = true }

local function same_path(a, b)
	return a and b and (vim.uv.fs_realpath(a) or a) == (vim.uv.fs_realpath(b) or b)
end

-- Agent panes from the state files, joined with `wezterm cli list` to drop closed panes.
-- Panes in the worktree `root` come first, then idle before busy.
local function agent_panes(root)
	local out = vim.system({ "wezterm", "cli", "list", "--format", "json" }, { text = true }):wait()
	if out.code ~= 0 then
		return {}
	end
	local panes = {}
	for _, p in ipairs(vim.json.decode(out.stdout)) do
		local agent, state, agent_root, branch
		local f = io.open(state_dir .. "/" .. p.pane_id)
		if f then
			-- agent, state, root, branch, worktree, title (see wezterm/bin/agent-status)
			local fields = vim.split(f:read("*l") or "", "\t")
			agent, state, agent_root, branch = fields[1], fields[2], fields[3], fields[4]
			f:close()
		end
		-- Claude Code prefixes its title with ✳ when idle and a spinner while busy. That also covers
		-- sessions whose hooks haven't written a state file yet, and turns cancelled without a hook.
		local glyph = p.title:match("^(%S+) ")
		if glyph == "✳" then
			agent, state = agent or "claude", "idle"
		elseif not agent and claude_spinner[glyph] then
			agent, state = "claude", "working"
		end
		if agent then
			local cwd = vim.fs.normalize(vim.uri_to_fname(p.cwd))
			agent_root = agent_root ~= "" and agent_root or vim.fs.root(cwd, ".git") or cwd
			table.insert(panes, {
				id = p.pane_id,
				agent = agent,
				state = state,
				root = agent_root,
				branch = branch or "",
				here = same_path(agent_root, root),
				title = p.title:gsub("^[^%w]+", ""),
			})
		end
	end
	local rank = { idle = 1, done = 1, waiting = 2, working = 3 }
	table.sort(panes, function(a, b)
		if a.here ~= b.here then
			return a.here
		end
		if rank[a.state] ~= rank[b.state] then
			return (rank[a.state] or 9) < (rank[b.state] or 9)
		end
		return a.id < b.id
	end)
	return panes
end

local function send_to(pane_id, text)
	local cli = { "wezterm", "cli", "send-text", "--pane-id", tostring(pane_id) }
	-- Paste the prompt, then submit it with a separate Enter once the paste has landed.
	vim.system(cli, { stdin = text }, function(res)
		if res.code ~= 0 then
			vim.schedule(function()
				vim.notify("review: send failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
			end)
			return
		end
		vim.defer_fn(function()
			vim.system(vim.list_extend(vim.deepcopy(cli), { "--no-paste", "\r" }))
		end, 150)
	end)
end

-- Send list as one prompt to the agent working in the comments' worktree. With exactly one agent
-- there it goes straight to it; otherwise pick with fzf-lua, agents in that worktree first. Never to
-- an agent waiting on a permission prompt.
function M.send_comments(list, on_sent)
	local root = list[1].root
	for _, c in ipairs(list) do
		if not same_path(c.root, root) then
			root = nil
		end
	end
	local panes = agent_panes(root)
	if #panes == 0 then
		vim.notify("review: no agent panes found", vim.log.levels.WARN)
		return
	end
	local text = prompt(list)
	local function deliver(p)
		-- A waiting agent shows a permission prompt; the pasted text and Enter would answer it.
		if p.state == "waiting" then
			vim.notify(("review: %s is waiting on a prompt, answer it first"):format(p.title), vim.log.levels.WARN)
			return
		end
		send_to(p.id, text)
		vim.notify(("review: sent %d comment(s) to %s (%s)"):format(#list, p.title, p.branch))
		on_sent()
	end
	local here = vim.tbl_filter(function(p)
		return p.here
	end, panes)
	if #here == 1 and here[1].state ~= "waiting" then
		deliver(here[1])
		return
	end
	require("packs.fzf")
	local fzf = require("fzf-lua")
	local utils = require("fzf-lua.utils")
	local colors = { idle = "#3F6F3F", done = "#77DD77", working = "#A58BD3", waiting = "#E0955A" }
	local entries, by_entry = {}, {}
	for _, p in ipairs(panes) do
		local entry = ("%s  %s  %s  %s"):format(
			utils.ansi_from_rgb(colors[p.state] or colors.idle, ("%-8s"):format(p.state)),
			p.title,
			utils.ansi_from_rgb(p.here and "#55BB55" or "#3F6F3F", p.branch),
			utils.ansi_from_rgb("#3F6F3F", vim.fn.fnamemodify(p.root, ":~"))
		)
		table.insert(entries, entry)
		by_entry[utils.strip_ansi_coloring(entry)] = p
	end
	fzf.fzf_exec(entries, {
		prompt = ("Send %d comment%s> "):format(#list, #list == 1 and "" or "s"),
		fzf_opts = { ["--ansi"] = true },
		actions = {
			["enter"] = function(selected)
				local p = selected and by_entry[utils.strip_ansi_coloring(selected[1])]
				if p then
					deliver(p)
				end
			end,
		},
	})
end

-- Send every queued comment, then clear the queue.
function M.send()
	if #comments == 0 then
		vim.notify("review: no comments to send", vim.log.levels.INFO)
		return
	end
	M.send_comments(comments, M.clear)
end

-- CodeDiff recreates its revision buffers when switching files; put comments back on them.
vim.api.nvim_create_autocmd("BufWinEnter", {
	group = vim.api.nvim_create_augroup("ReviewComments", { clear = true }),
	callback = function(ev)
		local name = vim.api.nvim_buf_get_name(ev.buf)
		for _, c in ipairs(comments) do
			if c.key == name and (c.buf ~= ev.buf or not c.mark) then
				c.buf, c.mark, c.note = ev.buf, nil, nil
				render(c)
			end
		end
	end,
})

-- Re-wrap comment text when a window showing it changes width.
vim.api.nvim_create_autocmd("WinResized", {
	group = "ReviewComments",
	callback = function()
		for _, win in ipairs(vim.v.event.windows) do
			local buf = vim.api.nvim_win_get_buf(win)
			for _, c in ipairs(comments) do
				if c.buf == buf then
					render(c)
				end
			end
		end
	end,
})

vim.keymap.set("n", "<leader>ra", function()
	local lnum = vim.fn.line(".")
	M.add(lnum, lnum)
end, { desc = "add review comment" })
vim.keymap.set("x", "<leader>ra", function()
	local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
	vim.cmd("normal! \27")
	M.add(math.min(l1, l2), math.max(l1, l2))
end, { desc = "add review comment" })
vim.keymap.set("n", "<leader>re", function()
	local c = comment_at(vim.api.nvim_get_current_buf(), vim.fn.line("."))
	if c then
		M.add(c.line1, c.line2)
	else
		vim.notify("review: no comment on this line", vim.log.levels.INFO)
	end
end, { desc = "edit review comment" })
vim.keymap.set("n", "<leader>rd", function()
	M.delete_at(vim.api.nvim_get_current_buf(), vim.fn.line("."))
end, { desc = "delete review comment" })
vim.keymap.set("n", "<leader>rl", M.list, { desc = "list review comments" })
vim.keymap.set("n", "<leader>rs", M.send, { desc = "send review to agent" })
vim.keymap.set("n", "<leader>rc", M.clear, { desc = "clear review comments" })

return M

-- Review comments: note lines in any buffer (including CodeDiff panes), then send them all as one
-- prompt to an agent running in another WezTerm pane. Agent panes are found through the state
-- files written by ~/.config/wezterm/bin/agent-status.
local M = {}

local ns = vim.api.nvim_create_namespace("review")
local state_dir = (vim.env.XDG_STATE_HOME or (vim.env.HOME .. "/.local/state")) .. "/agent-status"
local review_dir = state_dir .. "/review"
local review_cli = "~/.config/wezterm/bin/review"

---@class ReviewComment
---@field id string
---@field status "draft"|"sent"|"resolved"
---@field reply? string
---@field root? string
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
local ready = {}
local approved = {}

local function real(path)
	return vim.uv.fs_realpath(path) or path
end

local function same_path(a, b)
	return a and b and real(a) == real(b)
end

math.randomseed(vim.uv.hrtime())
local function new_id()
	while true do
		local id = ("%04x"):format(math.random(0, 0xffff))
		local taken = false
		for _, c in ipairs(comments) do
			taken = taken or c.id == id
		end
		if not taken then
			return id
		end
	end
end

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
	if pos[1] and not pos[3].invalid then
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

local looks = {
	draft = { sign = "ReviewNoteSign", text = "ReviewNote", line = "ReviewNoteLine" },
	sent = { sign = "ReviewSentSign", text = "ReviewSent", line = "ReviewNoteLine" },
	resolved = { sign = "ReviewResolvedSign", text = "ReviewResolved" },
}

-- Two extmarks per comment: one spanning the range (sign, tint, tracks edits) and one on the
-- last line that carries the comment text below the range.
local attach

local function render(c)
	sync(c)
	attach(c.buf)
	for _, id in ipairs({ c.mark, c.note }) do
		pcall(vim.api.nvim_buf_del_extmark, c.buf, ns, id)
	end
	local win = vim.fn.bufwinid(c.buf)
	local width = 80
	if win ~= -1 then
		width = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
	end
	width = math.max(math.min(width, 100) - vim.fn.strdisplaywidth(prefix) - 1, 20)
	local look = looks[c.status] or looks.draft
	local virt_lines = {}
	for _, line in ipairs(wrap(c.text, width)) do
		table.insert(virt_lines, { { prefix, look.sign }, { line, look.text } })
	end
	if c.status == "sent" then
		table.insert(virt_lines, { { prefix, look.sign }, { "sent", look.sign }, { " · waiting for the agent", "ReviewStatus" } })
	elseif c.status == "resolved" then
		local reply = c.reply and c.reply ~= "" and wrap(c.reply, width - 11) or { "" }
		for i, line in ipairs(reply) do
			table.insert(virt_lines, {
				{ prefix, look.sign },
				{ i == 1 and "resolved" or "        ", look.sign },
				{ line ~= "" and ("   " .. line) or "", "ReviewStatus" },
			})
		end
	end
	local last = vim.api.nvim_buf_line_count(c.buf)
	local row1, row2 = math.min(c.line1, last) - 1, math.min(c.line2, last) - 1
	c.mark = vim.api.nvim_buf_set_extmark(c.buf, ns, row1, 0, {
		end_row = row2,
		sign_text = "▍",
		sign_hl_group = look.sign,
		line_hl_group = look.line,
		invalidate = true,
	})
	c.note = vim.api.nvim_buf_set_extmark(c.buf, ns, row2, 0, {
		virt_lines = virt_lines,
		invalidate = true,
	})
end

local attached = {}

local function broken(c)
	for _, id in ipairs({ c.mark, c.note }) do
		local pos = id and vim.api.nvim_buf_get_extmark_by_id(c.buf, ns, id, { details = true }) or {}
		if not pos[1] or pos[3].invalid then
			return true
		end
	end
	return false
end

local function repair(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	for _, c in ipairs(comments) do
		if c.buf == buf and broken(c) then
			render(c)
		end
	end
end

attach = function(buf)
	if attached[buf] or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	attached[buf] = true
	local pending = false
	local function later()
		if not pending then
			pending = true
			vim.schedule(function()
				pending = false
				repair(buf)
			end)
		end
	end
	vim.api.nvim_buf_attach(buf, false, {
		on_lines = later,
		on_reload = later,
		on_detach = function()
			attached[buf] = nil
		end,
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

local function unmark(c)
	if c.buf and vim.api.nvim_buf_is_valid(c.buf) then
		pcall(vim.api.nvim_buf_del_extmark, c.buf, ns, c.mark)
		pcall(vim.api.nvim_buf_del_extmark, c.buf, ns, c.note)
	end
	c.mark, c.note = nil, nil
end

local function show_marks(c)
	if c.buf and vim.api.nvim_buf_is_valid(c.buf) and vim.api.nvim_buf_is_loaded(c.buf) then
		render(c)
	end
end

local function find_buf(name)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(buf) == name then
			return buf
		end
	end
end

local function log_event(event)
	vim.fn.mkdir(state_dir, "p")
	local f = io.open(state_dir .. "/threads.jsonl", "a")
	if f then
		event.type, event.at = "review", os.time()
		f:write(vim.json.encode(event), "\n")
		f:close()
	end
end

local function store_file(root)
	return review_dir .. "/" .. (real(root):gsub("/", "%%")) .. ".json"
end

local function read_store(root)
	local f = io.open(store_file(root))
	local ok, data = pcall(vim.json.decode, f and f:read("*a") or "", { luanil = { object = true, array = true } })
	if f then
		f:close()
	end
	data = ok and type(data) == "table" and data or {}
	data.comments = type(data.comments) == "table" and data.comments or {}
	return data
end

local function write_store(root, data)
	vim.fn.mkdir(review_dir, "p")
	local path = store_file(root)
	local tmp = path .. "." .. vim.fn.getpid()
	local f = io.open(tmp, "w")
	if not f then
		return
	end
	f:write(vim.json.encode(data))
	f:close()
	os.rename(tmp, path)
	if vim.env.WEZTERM_PANE then
		vim.system({ "wezterm", "cli", "set-window-title", "agents " .. vim.fn.getpid() })
	end
end

local function counts(root)
	local n = { draft = 0, sent = 0, resolved = 0 }
	for _, c in ipairs(comments) do
		if same_path(c.root, root) then
			n[c.status] = n[c.status] + 1
		end
	end
	return n
end

function M.summary(root)
	local n, r = counts(root), ready[real(root)]
	return {
		ready = r ~= nil,
		approved = approved[real(root)] ~= nil,
		note = r and r.note or nil,
		draft = n.draft,
		sent = n.sent,
		resolved = n.resolved,
	}
end

local function changed()
	vim.api.nvim_exec_autocmds("User", { pattern = "ReviewChanged" })
end

local function persist(root, opts)
	if not root then
		return
	end
	local data = read_store(root)
	data.comments = {}
	if opts and opts.clear_ready then
		data.ready, data.approved = nil, nil
		ready[real(root)], approved[real(root)] = nil, nil
	end
	if opts and opts.approve then
		data.ready, data.approved = nil, { at = os.time(), session = opts.session }
		ready[real(root)], approved[real(root)] = nil, data.approved
	end
	for _, c in ipairs(comments) do
		if c.status ~= "draft" and same_path(c.root, root) then
			sync(c)
			table.insert(data.comments, {
				id = c.id,
				status = c.status,
				reply = c.reply,
				at = c.at,
				resolved_at = c.resolved_at,
				path = c.path,
				rev = c.rev,
				key = c.key,
				line1 = c.line1,
				line2 = c.line2,
				text = c.text,
			})
		end
	end
	write_store(root, data)
	changed()
end

local function import(root)
	local data = read_store(root)
	ready[real(root)] = type(data.ready) == "table" and data.ready or nil
	approved[real(root)] = type(data.approved) == "table" and data.approved or nil
	local stored = {}
	for _, s in ipairs(data.comments) do
		if type(s) == "table" and s.id and s.key and s.path and s.line1 then
			stored[s.id] = s
		end
	end
	local kept = {}
	for _, c in ipairs(comments) do
		local s = stored[c.id]
		if c.status == "draft" or not same_path(c.root, root) then
			table.insert(kept, c)
		elseif s then
			stored[c.id] = nil
			local changed = s.status ~= c.status or s.reply ~= c.reply or s.text ~= c.text
			c.status, c.reply, c.text, c.at, c.resolved_at = s.status, s.reply, s.text, s.at, s.resolved_at
			table.insert(kept, c)
			if changed then
				show_marks(c)
			end
		else
			unmark(c)
		end
	end
	for _, s in pairs(stored) do
		local c = {
			id = s.id,
			status = s.status == "resolved" and "resolved" or "sent",
			reply = s.reply,
			at = s.at,
			resolved_at = s.resolved_at,
			root = root,
			key = s.key,
			path = s.path,
			rev = s.rev,
			line1 = s.line1,
			line2 = s.line2 or s.line1,
			text = s.text or "",
			buf = find_buf(s.key),
		}
		table.insert(kept, c)
		show_marks(c)
	end
	comments = kept
	changed()
end

local watched, pending = {}, {}
local watcher, debounce
local handle_show

local function ensure_watcher()
	if watcher then
		return
	end
	vim.fn.mkdir(review_dir, "p")
	watcher, debounce = vim.uv.new_fs_event(), vim.uv.new_timer()
	watcher:start(review_dir, {}, function(_, filename)
		local base = filename and vim.fs.basename(filename)
		if base == "show" then
			vim.schedule(function()
				handle_show()
			end)
			return
		end
		local changed = base and watched[base]
		if changed then
			pending[changed] = true
			debounce:start(100, 0, vim.schedule_wrap(function()
				local roots = pending
				pending = {}
				for r in pairs(roots) do
					import(r)
				end
			end))
		end
	end)
end

local function watch(root)
	if not root then
		return
	end
	ensure_watcher()
	watched[vim.fs.basename(store_file(root))] = root
	import(root)
end
M.watch = watch

-- Small floating editor that wraps and grows with its text, like a textarea.
-- <C-s> or <CR> in normal mode saves, <C-S-s> sends right away, q or <Esc> in normal mode cancels, and
-- so does leaving it (a click elsewhere).
-- It spans the window it opens from, its left edge on that window's number column, under the cursor
-- line, or above it when the window has no room below; it never grows past that window.
-- on_save(text, send_now)
local function edit(title, initial, on_save)
	local origin = vim.api.nvim_get_current_win()
	local line = vim.fn.winline()
	local origin_height = vim.api.nvim_win_get_height(origin)
	-- The border takes a row above and below and the winbar one more, around at least 3 text lines.
	local below = origin_height - line - 3
	local above = line - 1 - 3
	local up = below < 3 and above > below
	local room = math.max(up and above or below, 1)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial or "", "\n"))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "win",
		win = origin,
		-- Under the cursor line, or with the bottom edge on the line above it.
		anchor = up and "SW" or "NW",
		row = up and line - 1 or line,
		col = 0,
		width = math.max(vim.api.nvim_win_get_width(origin) - 2, 10),
		height = math.min(4, room),
		-- Blank border in the popup's own color: padding on every side, with the file path in
		-- the top edge and the key hints in the bottom edge.
		border = { " ", " ", " ", " ", " ", " ", " ", " " },
		title = { { "  " .. title, "ReviewNoteTitle" } },
		title_pos = "left",
		footer = { { "Ctrl + s save · Ctrl + S send · q cancel ", "ReviewNoteHint" } },
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
	-- Winbar line plus wrapped text, between 3 and 12 text lines, and no more than the window has room
	-- for; past that it scrolls.
	local function fit()
		if vim.api.nvim_win_is_valid(win) then
			local lines = vim.api.nvim_win_text_height(win, {}).all
			vim.api.nvim_win_set_height(win, math.max(math.min(math.max(lines, 3), 12, room - 1), 1) + 1)
		end
	end
	fit()
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = buf, callback = fit })
	local function close()
		vim.cmd.stopinsert()
		pcall(vim.api.nvim_win_close, win, true)
	end
	-- Leaving it, a click elsewhere included, cancels like q; the close waits until the move is done.
	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = buf,
		once = true,
		callback = function()
			vim.schedule(close)
		end,
	})
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
	vim.keymap.set({ "n", "i" }, "<C-S-s>", function()
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
	watch(loc.root)
	local existing = comment_at(buf, line1)
	local range = line1 == line2 and tostring(line1) or (line1 .. "-" .. line2)
	edit(loc.path .. ":" .. range, existing and existing.text, function(text, send_now)
		if text == "" then
			if existing then
				M.delete_at(buf, line1)
			end
			return
		end
		local c = existing
		if c then
			if c.text ~= text then
				local was = c.status
				c.text, c.status, c.reply = text, "draft", nil
				if was ~= "draft" then
					persist(c.root)
				end
			end
		else
			c = vim.tbl_extend("force", loc, {
				id = new_id(),
				status = "draft",
				line1 = line1,
				line2 = line2,
				text = text,
				buf = buf,
			})
			table.insert(comments, c)
		end
		render(c)
		changed()
		if send_now then
			M.send_comments({ c })
		end
	end)
end

function M.delete_at(buf, lnum)
	local c, i = comment_at(buf, lnum)
	if not c then
		return
	end
	unmark(c)
	table.remove(comments, i)
	if c.status ~= "draft" then
		persist(c.root)
	end
	changed()
end

function M.clear()
	local roots = {}
	for _, c in ipairs(comments) do
		unmark(c)
		if c.root and c.status ~= "draft" then
			roots[real(c.root)] = c.root
		end
	end
	comments = {}
	for _, root in pairs(roots) do
		persist(root)
	end
	changed()
end

local function position(root, path, line)
	return { root and real(root) or "", path, line }
end

local function before(a, b)
	for i = 1, 3 do
		if a[i] ~= b[i] then
			return a[i] < b[i]
		end
	end
	return false
end

local function ordered()
	local list = {}
	for _, c in ipairs(comments) do
		sync(c)
		table.insert(list, c)
	end
	table.sort(list, function(a, b)
		return before(position(a.root, a.path, a.line1), position(b.root, b.path, b.line1))
	end)
	return list
end

local function window_showing(key)
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == key then
			return win
		end
	end
end

local function place(win, c)
	vim.api.nvim_set_current_win(win)
	local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
	vim.api.nvim_win_set_cursor(win, { math.min(c.line1, last), 0 })
	vim.cmd("normal! zz")
end

function M.show(c)
	sync(c)
	local win = window_showing(c.key)
	if win then
		return place(win, c)
	end
	local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
	local tab = vim.api.nvim_get_current_tabpage()
	local session = ok and lifecycle.get_session(tab)
	local panel = session and lifecycle.get_panel(tab)
	local explorer = panel and panel.name == "explorer" and panel.view
	if explorer and explorer.tree and same_path(session.git_root, c.root) then
		for _, file in ipairs(require("codediff.ui.explorer").get_all_files(explorer.tree)) do
			if file.data.path == c.path then
				if file.node._line and vim.api.nvim_win_is_valid(explorer.winid) then
					pcall(vim.api.nvim_win_set_cursor, explorer.winid, { file.node._line, 0 })
				end
				explorer.on_file_select(file.data)
				local tries, timer = 0, vim.uv.new_timer()
				timer:start(30, 30, vim.schedule_wrap(function()
					tries = tries + 1
					local shown = window_showing(c.key)
					if shown or tries > 100 then
						timer:stop()
						timer:close()
						if shown then
							place(shown, c)
						end
					end
				end))
				return
			end
		end
	end
	if c.rev then
		vim.notify("review: " .. c.path .. " is not in this diff", vim.log.levels.INFO)
		return
	end
	if vim.t.git_view then
		require("packs.git").editor_tab()
	end
	vim.cmd.edit(vim.fn.fnameescape(c.key))
	place(vim.api.nvim_get_current_win(), c)
end

local function common_dir(path)
	local out = vim.system({ "git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir" }, { text = true }):wait()
	return out.code == 0 and vim.trim(out.stdout) or nil
end

handle_show = function()
	if vim.g.sidebar or vim.g.docker_view then
		return
	end
	local f = io.open(review_dir .. "/show")
	local ok, req = pcall(vim.json.decode, f and f:read("*a") or "")
	if f then
		f:close()
	end
	if not ok or type(req) ~= "table" or not req.root or os.time() - (tonumber(req.at) or 0) > 5 then
		return
	end
	local mine = common_dir(vim.env.PWD or vim.fn.getcwd())
	if not mine or common_dir(req.root) ~= mine then
		return
	end
	watch(req.root)
	local target
	for _, c in ipairs(comments) do
		if c.id == req.id and same_path(c.root, req.root) then
			target = c
		end
	end
	if not target then
		return
	end
	local okc, lifecycle = pcall(require, "codediff.ui.lifecycle")
	if okc then
		for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
			local session = lifecycle.get_session(tab)
			if session and same_path(session.git_root, req.root) then
				vim.api.nvim_set_current_tabpage(tab)
				break
			end
		end
	end
	M.show(target)
	if vim.env.WEZTERM_PANE then
		vim.system({ "wezterm", "cli", "activate-pane", "--pane-id", vim.env.WEZTERM_PANE })
	end
end

function M.list()
	local list = ordered()
	if #list == 0 then
		vim.notify("review: no comments", vim.log.levels.INFO)
		return
	end
	require("packs.fzf")
	local fzf = require("fzf-lua")
	local utils = require("fzf-lua.utils")
	local colors = { draft = "#A58BD3", sent = "#E0955A", resolved = "#55BB55" }
	local entries, by_entry = {}, {}
	for _, c in ipairs(list) do
		local range = c.line1 == c.line2 and tostring(c.line1) or (c.line1 .. "-" .. c.line2)
		local entry = ("%s  %s  %s"):format(
			utils.ansi_from_rgb(colors[c.status], ("%-8s"):format(c.status == "draft" and "review" or c.status)),
			utils.ansi_from_rgb("#55BB55", c.path .. ":" .. range),
			utils.ansi_from_rgb("#6A6280", (c.text:gsub("\n", " ")))
		)
		table.insert(entries, entry)
		by_entry[utils.strip_ansi_coloring(entry)] = c
	end
	fzf.fzf_exec(entries, {
		prompt = "Review comments> ",
		fzf_opts = { ["--ansi"] = true, ["--no-sort"] = true },
		actions = {
			["enter"] = function(selected)
				local c = selected and by_entry[utils.strip_ansi_coloring(selected[1])]
				if c then
					M.show(c)
				end
			end,
		},
	})
end

-- Comments as one prompt: location, the code it points at, then the note.
local function prompt(list)
	local parts = { "Review comments on the current changes:" }
	local root = list[1].root
	for i, c in ipairs(list) do
		sync(c)
		local range = c.line1 == c.line2 and tostring(c.line1) or (c.line1 .. "-" .. c.line2)
		local where = c.path .. ":" .. range
		if c.rev then
			where = where .. " (old version at " .. c.rev:sub(1, 12) .. ")"
		end
		local block = { ("%d. [%s] %s"):format(i, c.id, where) }
		if c.buf and vim.api.nvim_buf_is_valid(c.buf) then
			local code = vim.api.nvim_buf_get_lines(c.buf, c.line1 - 1, c.line2, false)
			table.insert(block, "```" .. vim.bo[c.buf].filetype)
			vim.list_extend(block, code)
			table.insert(block, "```")
		end
		table.insert(block, c.text)
		table.insert(parts, table.concat(block, "\n"))
	end
	if root then
		local cli = ("%s -C %s"):format(review_cli, vim.fn.shellescape(real(root)))
		table.insert(parts, table.concat({
			"When you have handled a comment, mark it resolved with a one-line note on what you changed:",
			("`%s resolve <id> \"<note>\"`"):format(cli),
			"If you disagree or need input, leave it open and say why.",
			("Once all are handled, mark the work ready for review: `%s ready \"<short summary>\"`"):format(cli),
		}, "\n"))
	end
	return table.concat(parts, "\n\n")
end

local claude_spinner = { ["◐"] = true, ["◓"] = true, ["◑"] = true, ["◒"] = true }

-- Agent panes from the state files, joined with `wezterm cli list` to drop closed panes.
-- Panes in the worktree `root` come first, then idle before busy.
local function agent_panes(root)
	local out = vim.system({ "wezterm", "cli", "list", "--format", "json" }, { text = true }):wait()
	if out.code ~= 0 then
		return {}
	end
	local panes = {}
	for _, p in ipairs(vim.json.decode(out.stdout)) do
		local agent, state, agent_root, branch, session
		local f = io.open(state_dir .. "/" .. p.pane_id)
		if f then
			-- agent, state, root, branch, worktree, title (see wezterm/bin/agent-status)
			local fields = vim.split(f:read("*l") or "", "\t")
			agent, state, agent_root, branch, session = fields[1], fields[2], fields[3], fields[4], fields[7]
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
				session = session or "",
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
local function pick_agent(root, label, on_pick)
	local panes = agent_panes(root)
	if #panes == 0 then
		vim.notify("review: no agent panes found", vim.log.levels.WARN)
		return
	end
	local function deliver(p)
		-- A waiting agent shows a permission prompt; the pasted text and Enter would answer it.
		if p.state == "waiting" then
			vim.notify(("review: %s is waiting on a prompt, answer it first"):format(p.title), vim.log.levels.WARN)
			return
		end
		on_pick(p)
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
		prompt = label .. "> ",
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

function M.send_comments(list)
	local root = list[1].root
	for _, c in ipairs(list) do
		if not same_path(c.root, root) then
			root = nil
		end
	end
	local text = prompt(list)
	pick_agent(root, ("Send %d comment%s"):format(#list, #list == 1 and "" or "s"), function(p)
		send_to(p.id, text)
		vim.notify(("review: sent %d comment(s) to %s (%s)"):format(#list, p.title, p.branch))
		local roots = {}
		for _, c in ipairs(list) do
			c.status, c.reply, c.at = "sent", nil, os.time()
			show_marks(c)
			if c.root then
				sync(c)
				log_event({
					event = "sent",
					root = real(c.root),
					id = c.id,
					path = c.path,
					line1 = c.line1,
					line2 = c.line2,
					text = c.text,
					agent = p.title,
				})
			end
			if c.root then
				roots[real(c.root)] = c.root
			end
		end
		for _, r in pairs(roots) do
			persist(r, { clear_ready = true })
		end
		changed()
	end)
end

local function current_root()
	local tab_root = vim.t.git_view_root
	if tab_root then
		return tab_root
	end
	local loc = location(vim.api.nvim_get_current_buf())
	return loc and loc.root or vim.fs.root(vim.fn.getcwd(), ".git")
end

function M.approve()
	local root = current_root()
	if not root then
		return vim.notify("review: not in a git repository", vim.log.levels.WARN)
	end
	for _, c in ipairs(comments) do
		if c.status == "draft" and same_path(c.root, root) then
			return vim.notify("review: send or clear the unsent comments first", vim.log.levels.WARN)
		end
	end
	watch(root)
	pick_agent(root, "Approve " .. vim.fs.basename(root), function(p)
		send_to(p.id, "Review approved: the changes on this branch are ready for a merge request.")
		persist(root, { approve = true, session = p.session })
		log_event({ event = "approved", root = real(root), agent = p.title, session = p.session })
		vim.notify(("review: approved %s, told %s (%s)"):format(vim.fs.basename(root), p.title, p.branch))
	end)
end

-- Send every queued comment; they stay as sent until the agent resolves them.
function M.send()
	local drafts = vim.tbl_filter(function(c)
		return c.status == "draft"
	end, comments)
	if #drafts == 0 then
		vim.notify("review: no comments to send", vim.log.levels.INFO)
		return
	end
	M.send_comments(drafts)
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

vim.api.nvim_create_autocmd("User", {
	group = "ReviewComments",
	pattern = "CodeDiffOpen",
	callback = function()
		vim.schedule(function()
			local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
			local session = ok and lifecycle.get_session(vim.api.nvim_get_current_tabpage())
			if session and session.git_root then
				watch(session.git_root)
			end
		end)
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
vim.keymap.set("n", "<leader>rf", M.list, { desc = "find review comments" })
vim.keymap.set("n", "<leader>rs", M.send, { desc = "send review to agent" })
vim.keymap.set("n", "<leader>rp", M.approve, { desc = "approve review" })
vim.keymap.set("n", "<leader>rc", M.clear, { desc = "clear review comments" })

ensure_watcher()

return M

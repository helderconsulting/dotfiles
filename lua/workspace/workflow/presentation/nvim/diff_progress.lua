local app = require("workspace.workbench.presentation.nvim.app")

local M = {}

M.flush_after = 5000
M.restore_limit = 5000

local pending, marked = {}, {}
local ns = vim.api.nvim_create_namespace("diff_progress")
local timer = vim.uv.new_timer()

local function progress()
	return app.services().diff_progress_process
end

app.on("diff_progress", function(change)
	if change.deleted then
		progress():forget(change.id)
	end
end)

function M.flush()
	progress():flush()
end

local function touch(later)
	if not later then
		timer:start(M.flush_after, 0, vim.schedule_wrap(M.flush))
	end
end

function M.stamp(root, path)
	local st = vim.uv.fs_stat(root .. "/" .. path)
	return st and ("%d.%d:%d"):format(st.mtime.sec, st.mtime.nsec, st.size) or "gone"
end

local function lines(buf, range)
	if not (buf and vim.api.nvim_buf_is_valid(buf) and range) then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_lines(buf, range.start_line - 1, range.end_line - 1, false), "\n")
end

local function key(text)
	return vim.fn.sha256(text):sub(1, 16)
end

local function hunks(session)
	if session.single_side then
		local buf = session[session.single_side .. "_bufnr"]
		local count = buf and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_line_count(buf) or 1
		local whole = { start_line = 1, end_line = count + 1 }
		return { { key = key(session.single_side .. "\0" .. lines(buf, whole)), modified = whole, original = whole } }
	end
	local list = {}
	for _, c in ipairs(session.stored_diff_result and session.stored_diff_result.changes or {}) do
		local added = lines(session.modified_bufnr, c.modified)
		local text = added ~= "" and ("+" .. added) or ("-" .. lines(session.original_bufnr, c.original))
		table.insert(list, { key = key(text), original = c.original, modified = c.modified })
	end
	return list
end

local function current(tab)
	local lifecycle = require("codediff.ui.lifecycle")
	local session, panel = lifecycle.get_session(tab), lifecycle.get_panel(tab)
	local explorer = panel and panel.view
	local path = explorer and explorer.data and explorer.data.current_file_path
	if not (session and session.git_root and path) then
		return nil
	end
	return session, session.git_root, path
end

local shown = {}

local function clear_marks(tab)
	for buf in pairs(marked[tab] or {}) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		end
	end
	marked[tab] = nil
end

local function draw(tab)
	clear_marks(tab)
	local view = shown[tab]
	local buf = view and view.session.modified_bufnr
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	local last = vim.api.nvim_buf_line_count(buf)
	for _, h in ipairs(view.hunks) do
		if progress():has_seen(view.root, view.path, h.key) then
			local first = math.max(1, math.min(h.modified.start_line, last))
			local stop = math.max(first, math.min(h.modified.end_line - 1, last))
			vim.api.nvim_buf_set_extmark(buf, ns, first - 1, 0, { end_row = stop - 1, sign_text = "▍", sign_hl_group = "DiffSeenSign", priority = 5 })
			marked[tab] = marked[tab] or {}
			marked[tab][buf] = true
		end
	end
end

local function redraw_explorer(tab)
	local panel = require("codediff.ui.lifecycle").get_panel(tab)
	local tree = panel and panel.view and panel.view.tree
	if tree then
		pcall(tree.render, tree)
	end
end

function M.rendered(tab)
	local session, root, path = current(tab)
	if not session then
		return
	end
	local list = hunks(session)
	shown[tab] = { session = session, root = root, path = path, hunks = list }
	local keys = vim.tbl_map(function(h)
		return h.key
	end, list)
	if progress():know(root, path, keys, M.stamp(root, path)) then
		touch(true)
		redraw_explorer(tab)
	end
	draw(tab)
	M.land(tab)
end

local function covers(range, line)
	if range.start_line == range.end_line then
		return line == range.start_line or line == range.start_line - 1
	end
	return line >= range.start_line and line < range.end_line
end

function M.moved()
	local tab = vim.api.nvim_get_current_tabpage()
	local view = shown[tab]
	if not view or pending[tab] then
		return
	end
	local session, win = view.session, vim.api.nvim_get_current_win()
	local side = win == session.modified_win and "modified" or win == session.original_win and session.layout ~= "inline" and "original" or nil
	if not side then
		return
	end
	local line = vim.api.nvim_win_get_cursor(win)[1]
	local changed = side == "modified" and progress():visit(view.root, view.path, line, app.now())
	local saw = false
	for _, h in ipairs(view.hunks) do
		if covers(h[side], line) and progress():see(view.root, view.path, h.key) then
			saw = true
		end
	end
	if saw then
		draw(tab)
		redraw_explorer(tab)
	end
	if changed or saw then
		touch()
	end
end

function M.restore(tab, root, show)
	local at = progress():position(root)
	if not at then
		return
	end
	local p = { at = at, show = show }
	pending[tab] = p
	vim.defer_fn(function()
		if pending[tab] == p then
			pending[tab] = nil
		end
	end, M.restore_limit)
end

local function original_line(changes, line)
	local shift = 0
	for _, c in ipairs(changes or {}) do
		if c.modified.start_line <= line and line < c.modified.end_line then
			return math.min(c.original.start_line + (line - c.modified.start_line), math.max(c.original.end_line - 1, c.original.start_line))
		end
		if c.modified.end_line <= line then
			shift = shift + (c.modified.end_line - c.modified.start_line) - (c.original.end_line - c.original.start_line)
		end
	end
	return math.max(1, line - shift)
end

local function target(win)
	local tab = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win)
	local p = tab and pending[tab]
	if not p then
		return nil
	end
	local _, _, path = current(tab)
	return path == p.at.path and p or nil
end

function M.landing(win, lines_diff, orig_cursor, mod_cursor)
	local p = target(win)
	if not p then
		return orig_cursor, mod_cursor
	end
	p.applied = true
	local line = p.at.line
	return { original_line(lines_diff and lines_diff.changes, line), 0 }, { line, 0 }
end

function M.land_inline(win)
	local p = target(win)
	if not p then
		return
	end
	p.applied = true
	local line = math.max(1, math.min(p.at.line, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))))
	vim.api.nvim_win_set_cursor(win, { line, 0 })
	vim.api.nvim_win_call(win, function()
		vim.cmd("normal! zz")
	end)
end

function M.land(tab)
	local p = pending[tab]
	local view = shown[tab]
	if not (p and view) then
		return
	end
	if p.applied then
		pending[tab] = nil
		return
	end
	if view.path == p.at.path or p.asked or tab ~= vim.api.nvim_get_current_tabpage() then
		return
	end
	p.asked = true
	if not p.show(p.at.path, p.at.line) then
		pending[tab] = nil
	end
end

function M.badge(root, path)
	return root and progress():badge(root, path, M.stamp(root, path)) or nil
end

function M.closed(tab)
	if not tab then
		return M.flush()
	end
	clear_marks(tab)
	shown[tab], pending[tab] = nil, nil
	M.flush()
	local now = vim.api.nvim_get_current_tabpage()
	if shown[now] then
		draw(now)
	end
end

return M

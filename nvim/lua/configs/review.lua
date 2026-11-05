local app = require("configs.app")
local editor = require("configs.comment_editor")
local box = require("configs.comment_box")
local Review, Draft = app.models.Review, app.models.Draft

local M = {}

local ns = vim.api.nvim_create_namespace("review")
local marks = {}
local counts_cache = {}

local looks = {
	draft = { sign = "ReviewNoteSign", line = "ReviewNoteLine" },
	sent = { sign = "ReviewSentSign", line = "ReviewNoteLine" },
	resolved = { sign = "ReviewResolvedSign" },
}

local function real(path)
	return path and (vim.uv.fs_realpath(path) or path)
end

local function key_of(root)
	return Review.key(real(root))
end

local function get(root)
	return root and app.store():get(Review, key_of(root))
end

local function update(root, fn)
	return app.store():update(Review, key_of(root), function(r)
		r.root = real(root)
		return fn(r, app.now())
	end)
end

local function all()
	return app.store():all(Review)
end

local function location(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	if vim.b[buf].answer_session then
		return { key = name, path = "answer", root = vim.b[buf].answer_root }
	elseif name:match("^codediff://") then
		local root, rev, path = require("codediff.core.virtual_file").parse_url(name)
		if path then
			return { key = name, path = path, rev = rev, root = root }
		end
	elseif name ~= "" and vim.bo[buf].buftype == "" then
		local root = vim.fs.root(name, ".git")
		return { key = name, path = root and vim.fs.relpath(root, name) or vim.fn.fnamemodify(name, ":~:."), root = root }
	end
end

local function find_buf(name)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == name then
			return buf
		end
	end
end

local function tracked_lines(c)
	local m = marks[c.id]
	if not (m and m.mark and vim.api.nvim_buf_is_valid(m.buf)) then
		return c.line1, c.line2
	end
	local pos = vim.api.nvim_buf_get_extmark_by_id(m.buf, ns, m.mark, { details = true })
	if pos[1] and not pos[3].invalid then
		return pos[1] + 1, (pos[3].end_row or pos[1]) + 1
	end
	return c.line1, c.line2
end

local function unmark(id)
	local m = marks[id]
	if m and vim.api.nvim_buf_is_valid(m.buf) then
		pcall(vim.api.nvim_buf_del_extmark, m.buf, ns, m.mark)
		pcall(vim.api.nvim_buf_del_extmark, m.buf, ns, m.note)
	end
	marks[id] = nil
end

local function draw(c)
	local line1, line2 = tracked_lines(c)
	unmark(c.id)
	local buf = find_buf(c.key)
	if not buf or (c.path == "answer" and vim.api.nvim_buf_line_count(buf) < line2) then
		return
	end
	local look = looks[c.state] or looks.draft
	local width = box.width(vim.fn.bufwinid(buf))
	local status = c.state == "sent" and "sent · waiting for the agent" or c.state == "resolved" and "resolved" or nil
	local lines = box.note(c.text or "", width, status, c.state == "resolved" and c.reply or nil)
	local last = vim.api.nvim_buf_line_count(buf)
	local row1, row2 = math.min(line1, last) - 1, math.min(line2, last) - 1
	marks[c.id] = {
		buf = buf,
		mark = vim.api.nvim_buf_set_extmark(buf, ns, row1, 0, { end_row = row2, sign_text = "▍", sign_hl_group = look.sign, line_hl_group = look.line, invalidate = true }),
		note = vim.api.nvim_buf_set_extmark(buf, ns, row2, 0, { virt_lines = lines, invalidate = true }),
	}
end

local function draw_all()
	counts_cache = {}
	local live = {}
	for _, r in ipairs(all()) do
		for _, c in ipairs(r.comments) do
			live[c.id] = true
			draw(c)
		end
	end
	for id in pairs(marks) do
		if not live[id] then
			unmark(id)
		end
	end
	vim.api.nvim_exec_autocmds("User", { pattern = "ReviewChanged" })
end

local function comment_at(buf, lnum)
	local name = vim.api.nvim_buf_get_name(buf)
	for _, r in ipairs(all()) do
		for _, c in ipairs(r.comments) do
			local l1, l2 = tracked_lines(c)
			if c.key == name and lnum >= l1 and lnum <= l2 then
				return c, r
			end
		end
	end
end

function M.counts(root)
	local r = get(root)
	return r and r:counts() or { draft = 0, sent = 0, resolved = 0 }
end

function M.summary(root)
	local r = get(root)
	local n = M.counts(root)
	return { ready = r and r.state == "ready" or false, approved = r and r.state == "approved" or false, note = r and r.ready and r.ready.note, draft = n.draft, sent = n.sent, resolved = n.resolved }
end

function M.drafts_for(root)
	local r = get(root)
	return r and r:drafts() or {}
end

function M.add(line1, line2)
	local buf = vim.api.nvim_get_current_buf()
	local loc = location(buf)
	if not (loc and loc.root) then
		return vim.notify("review: this buffer is not in a git repository", vim.log.levels.WARN)
	end
	local existing = comment_at(buf, line1)
	local range = line1 == line2 and tostring(line1) or (line1 .. "-" .. line2)
	local inline = { buf = buf, line = existing and select(2, tracked_lines(existing)) or line2 }
	inline.on_todo = function(text, images)
		local quote = { (loc.path == "answer" and "On the agent's reply" or (loc.path .. ":" .. range)) .. ":" }
		for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)) do
			table.insert(quote, "> " .. l)
		end
		local comment = Draft.expand(text, images)
		local spec = { title = comment:match("[^\n]+") or comment, description = table.concat(quote, "\n"), criteria = { "Given , when , then " } }
		require("configs.todos").add_to(nil, loc.root, app.models.Todo.render(spec))
	end
	if existing and marks[existing.id] then
		pcall(vim.api.nvim_buf_del_extmark, buf, ns, marks[existing.id].note)
		inline.restore = draw_all
	end
	editor.open(loc.path .. ":" .. range, existing and existing.text, function(text, send_now, images)
		local id
		update(loc.root, function(r, now)
			if existing and text == "" then
				return r:delete(existing.id, now) ~= nil
			elseif existing then
				local c = r:edit(existing.id, text, now)
				c.images = images
				id = existing.id
				return c ~= nil
			elseif text ~= "" then
				id = r:add({ key = loc.key, path = loc.path, rev = loc.rev, line1 = line1, line2 = line2, text = text, images = images }, math.random, now).id
				return true
			end
			return false
		end)
		if send_now and id then
			local r = get(loc.root)
			M.send_comments(loc.root, { r:comment(id) })
		end
	end, existing and existing.images, inline)
end

function M.delete_at(buf, lnum)
	local c, r = comment_at(buf, lnum)
	if c then
		update(r.root, function(review, now)
			return review:delete(c.id, now) ~= nil
		end)
	end
end

function M.clear()
	for _, r in ipairs(all()) do
		update(r.root, function(review)
			review:clear()
		end)
	end
end

function M.quote(c)
	local l1, l2 = tracked_lines(c)
	if not l1 then
		return {}
	end
	local buf = find_buf(c.key)
	if buf then
		return vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
	end
	if c.rev or not c.key or vim.fn.filereadable(c.key) == 0 then
		return {}
	end
	return vim.list_slice(vim.fn.readfile(c.key, "", l2), l1, l2)
end

function M.prompt(list, root)
	local cli = ("%s -C %s"):format(Review.cli, vim.fn.shellescape(real(root)))
	return Review.prompt(list, cli, M.quote, function(c)
		return Draft.expand(c.text, c.images)
	end)
end

function M.send(root, list, agent_id)
	local ids = {}
	for _, c in ipairs(list) do
		ids[c.id] = true
	end
	local sent = {}
	update(root, function(r, now)
		local outgoing = {}
		for _, c in ipairs(r.comments) do
			if ids[c.id] then
				c.line1, c.line2 = tracked_lines(c)
				table.insert(c.path == "answer" and sent or outgoing, c)
			end
		end
		for _, c in ipairs(sent) do
			r:delete(c.id, now)
		end
		sent = r:send(outgoing, now, agent_id)
	end)
	for _, c in ipairs(sent) do
		app.store():log({ type = "review", event = "sent", root = real(root), id = c.id, path = c.path, line1 = c.line1, line2 = c.line2, text = c.text, session = agent_id })
	end
end

local function pick_agent(root, label, on_pick)
	local agent, candidates = Review.recipient(app.agents(), real(root), app.view().agent)
	if agent then
		return on_pick(agent)
	end
	if #candidates == 0 then
		return vim.notify("review: no running agents", vim.log.levels.WARN)
	end
	local entries = vim.tbl_map(function(a)
		return { tag = a:status(), value = a:display_name(), description = a.worktree or a.branch or "", agent = a }
	end, candidates)
	require("configs.model_picker").pick(entries, { prompt = label, header = "Enter sends it to that agent" }, function(choice)
		on_pick(choice.agent)
	end)
end

function M.send_comments(root, list)
	local text = M.prompt(list, root)
	pick_agent(root, ("send %d comment%s to"):format(#list, #list == 1 and "" or "s"), function(agent)
		require("configs.runner").message(agent, text, function(ok)
			if ok then
				M.send(root, list, agent.id)
				vim.notify(("review: sent %d comment(s) to %s"):format(#list, agent:display_name()))
			end
		end)
	end)
end

local function current_root()
	if vim.t.git_view_root then
		return vim.t.git_view_root
	end
	local loc = location(vim.api.nvim_get_current_buf())
	return loc and loc.root or vim.fs.root(vim.fn.getcwd(), ".git")
end

function M.send_all()
	local root = current_root()
	local list = root and M.drafts_for(root) or {}
	if #list == 0 then
		return vim.notify("review: no comments to send", vim.log.levels.INFO)
	end
	M.send_comments(root, list)
end

function M.approve()
	local root = current_root()
	if not root then
		return vim.notify("review: nothing to approve here", vim.log.levels.WARN)
	end
	local r = get(root) or Review.for_root(real(root))
	local ok, why = r:can_approve()
	if not ok then
		return vim.notify("review: " .. why, vim.log.levels.WARN)
	end
	pick_agent(root, "approve " .. vim.fs.basename(root) .. " for", function(agent)
		local approved, reason
		local tree = require("workspace.nvim").code_tree(root)
		update(root, function(review, now)
			approved, reason = review:approve(agent.id, now, tree, agent:is_busy())
			return approved
		end)
		if not approved then
			return vim.notify("review: " .. reason, vim.log.levels.WARN)
		end
		require("configs.runner").message(agent, "Review approved: the changes on this branch are ready for a merge request.")
		app.store():log({ type = "review", event = "approved", root = real(root), session = agent.id })
	end)
end

local function workspace()
	local w = app.workspace_model()
	return app.models.Workspace:new({ root = real(w and w.root or app.folder()) })
end

function M.list()
	local entries, by_entry = {}, {}
	local here = workspace()
	for _, r in ipairs(all()) do
		for _, c in ipairs(here:contains(real(r.root) or "") and r.comments or {}) do
			local entry = ("%-8s  %s  %s"):format(c.state == "draft" and "review" or c.state, c:location(), c:one_line())
			table.insert(entries, entry)
			by_entry[entry] = c
		end
	end
	if #entries == 0 then
		return vim.notify("review: no comments in this workspace", vim.log.levels.INFO)
	end
	vim.ui.select(entries, { prompt = "review comments" }, function(entry)
		if entry then
			M.show(by_entry[entry])
		end
	end)
end

function M.show(c)
	local line1 = tracked_lines(c)
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == c.key then
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_win_set_cursor(win, { math.min(line1, vim.api.nvim_buf_line_count(0)), 0 })
			return vim.cmd("normal! zz")
		end
	end
	if not c.key then
		return vim.notify("review: " .. c:location() .. ": " .. c:one_line(), vim.log.levels.INFO)
	end
	if c.rev or c.path == "answer" then
		return vim.notify("review: " .. c.path .. " is not open here", vim.log.levels.INFO)
	end
	if vim.t.git_view == "codediff" and require("packs.git").show_in_diff(c.path, line1) then
		return
	end
	if vim.t.git_view then
		require("packs.git").editor_tab()
	end
	vim.cmd.edit(vim.fn.fnameescape(c.key))
	vim.api.nvim_win_set_cursor(0, { math.min(line1, vim.api.nvim_buf_line_count(0)), 0 })
	vim.cmd("normal! zz")
end

function M.step(direction)
	local root = current_root()
	local r = root and get(root)
	local list = r and r:in_files() or {}
	if #list == 0 then
		return vim.notify("review: no comments on files here", vim.log.levels.INFO)
	end
	local loc = location(vim.api.nvim_get_current_buf())
	local here = loc and real(loc.root) == real(root) and loc.path or nil
	local c = Review.step(list, here, here and vim.fn.line(".") or nil, direction)
	for i, item in ipairs(list) do
		if item == c then
			vim.api.nvim_echo({ { ("comment %d of %d · %s"):format(i, #list, c:location()), "Comment" } }, false, {})
		end
	end
	M.show(c)
end

function M.file_counts(root)
	root = real(root)
	if not root then
		return {}
	end
	if not counts_cache[root] then
		local r = get(root)
		counts_cache[root] = r and r:by_path() or {}
	end
	return counts_cache[root]
end

function M.reveal(request)
	local r = get(request.root)
	local c = r and r:comment(request.id)
	if c then
		M.show(c)
		app.focus("editor")
	end
end

function M.inline_input(buf, line, hint, on_save, on_cancel)
	editor.open(nil, "", function(text)
		on_save(text)
	end, nil, { buf = buf, line = line, hint = hint, on_cancel = on_cancel })
end

local group = vim.api.nvim_create_augroup("ReviewComments", { clear = true })
vim.api.nvim_create_autocmd("BufWinEnter", { group = group, callback = vim.schedule_wrap(draw_all) })
vim.api.nvim_create_autocmd("User", { group = group, pattern = "AnswerFilled", callback = vim.schedule_wrap(draw_all) })
vim.api.nvim_create_autocmd("WinResized", { group = group, callback = draw_all })
app.on("reviews", draw_all)

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
	if not c then
		return vim.notify("review: no comment on this line", vim.log.levels.INFO)
	end
	M.add(tracked_lines(c))
end, { desc = "edit review comment" })
vim.keymap.set("n", "<leader>rd", function()
	M.delete_at(vim.api.nvim_get_current_buf(), vim.fn.line("."))
end, { desc = "delete review comment" })
vim.keymap.set("n", "<leader>rf", M.list, { desc = "find review comments" })
vim.keymap.set("n", "]r", function()
	M.step(1)
end, { desc = "next review comment" })
vim.keymap.set("n", "[r", function()
	M.step(-1)
end, { desc = "previous review comment" })
vim.keymap.set("n", "<leader>rs", M.send_all, { desc = "send review to agent" })
vim.keymap.set("n", "<leader>rp", M.approve, { desc = "approve review" })
vim.keymap.set("n", "<leader>rc", M.clear, { desc = "clear review comments" })

return M

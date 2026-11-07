local app = require("workspace.workbench.presentation.nvim.app")
local editor = require("workspace.workflow.presentation.nvim.comment_editor")
local box = require("workspace.conversations.presentation.nvim.comment_box")
local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")
local view_mapper = require("workspace.workflow.presentation.mappers.review_view_mapper")

local M = {}

local ns = vim.api.nvim_create_namespace("review")
local marks = {}
local counts_cache = {}

local function real(path)
	return path and (vim.uv.fs_realpath(path) or path)
end

local function reviews()
	return app.services().review_process
end

local function all_comments()
	return view_mapper.to_comment_view_models(reviews():all_comments())
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
	local width = box.width(vim.fn.bufwinid(buf))
	local lines = box.note(c.text or "", width, c.status, c.reply)
	local last = vim.api.nvim_buf_line_count(buf)
	local row1, row2 = math.min(line1, last) - 1, math.min(line2, last) - 1
	marks[c.id] = {
		buf = buf,
		mark = vim.api.nvim_buf_set_extmark(buf, ns, row1, 0, { end_row = row2, sign_text = "▍", sign_hl_group = c.sign_highlight, line_hl_group = c.line_highlight, invalidate = true }),
		note = vim.api.nvim_buf_set_extmark(buf, ns, row2, 0, { virt_lines = lines, invalidate = true }),
	}
end

local function draw_all()
	counts_cache = {}
	local live = {}
	for _, c in ipairs(all_comments()) do
		live[c.id] = true
		draw(c)
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
	for _, c in ipairs(all_comments()) do
		local l1, l2 = tracked_lines(c)
		if c.key == name and lnum >= l1 and lnum <= l2 then
			return c
		end
	end
end

function M.counts(root)
	return reviews():summary(real(root))
end

function M.summary(root)
	return reviews():summary(real(root))
end

function M.drafts_for(root)
	return view_mapper.to_comment_view_models(reviews():draft_comments(real(root)))
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
		require("workspace.workflow.presentation.nvim.mandatum_actions").add_from_review(loc.root, quote, text, images)
	end
	if existing and marks[existing.id] then
		pcall(vim.api.nvim_buf_del_extmark, buf, ns, marks[existing.id].note)
		inline.restore = draw_all
	end
	editor.open(loc.path .. ":" .. range, existing and existing.text, function(text, send_now, images)
		local root = real(loc.root)
		local id = reviews():save_comment(view_mapper.to_save_comment_command(root, loc, line1, line2, text, images, existing))
		if send_now and id then
			M.send_comments(root, { view_mapper.to_comment_view_model(reviews():comment(root, id)) })
		end
	end, existing and existing.images, inline)
end

function M.delete_at(buf, lnum)
	local c = comment_at(buf, lnum)
	if c then
		reviews():delete_comment(view_mapper.to_delete_comment_command(c))
	end
end

function M.clear()
	reviews():clear_all()
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

local function quote_dto(dto)
	return M.quote(view_mapper.to_comment_view_model(dto))
end

local function tracked(list)
	local lines = {}
	for _, c in ipairs(list) do
		lines[c.id] = { tracked_lines(c) }
	end
	return lines
end

function M.prompt(list, root)
	return reviews():prompt(view_mapper.to_send_comments_command(real(root), list, nil, quote_dto, tracked(list)))
end

function M.send(root, list, agent_id)
	reviews():mark_sent(view_mapper.to_send_comments_command(real(root), list, agent_id, quote_dto, tracked(list)))
end

local function pick_agent(root, label, on_pick)
	local agent, candidates = reviews():recipient(real(root), app.screen(ConversationScreen).agent)
	if agent then
		return on_pick(view_mapper.to_recipient_view_model(agent))
	end
	if #candidates == 0 then
		return vim.notify("review: no running agents", vim.log.levels.WARN)
	end
	local entries = view_mapper.to_recipient_view_models(candidates)
	require("workspace.legio.presentation.nvim.model_picker").pick(entries, { prompt = label, header = "Enter sends it to that agent" }, on_pick)
end

function M.send_comments(root, list)
	pick_agent(root, ("send %d comment%s to"):format(#list, #list == 1 and "" or "s"), function(agent)
		reviews():send_comments(view_mapper.to_send_comments_command(real(root), list, agent.id, quote_dto, tracked(list)), function(ok)
			if ok then
				vim.notify(("review: sent %d comment(s) to %s"):format(#list, agent.name))
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
	local ok, why = reviews():can_approve(real(root))
	if not ok then
		return vim.notify("review: " .. why, vim.log.levels.WARN)
	end
	pick_agent(root, "approve " .. vim.fs.basename(root) .. " for", function(agent)
		local approved, reason = reviews():approve(view_mapper.to_approve_command(real(root), agent))
		if not approved then
			return vim.notify("review: " .. reason, vim.log.levels.WARN)
		end
	end)
end

local function workspace_folder()
	local w = app.workspace_dto()
	return real(w and w.root or app.folder())
end

function M.list()
	local entries, by_entry = {}, {}
	for _, c in ipairs(view_mapper.to_comment_view_models(reviews():comments_in_folder(workspace_folder()))) do
		table.insert(entries, c.list_label)
		by_entry[c.list_label] = c
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
		return vim.notify("review: " .. c.location .. ": " .. c.summary, vim.log.levels.INFO)
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
	local root = real(current_root())
	local loc = location(vim.api.nvim_get_current_buf())
	local here = loc and root and real(loc.root) == root and loc.path or nil
	local dto, index, total = nil, nil, nil
	if root then
		dto, index, total = reviews():next_comment(root, here, here and vim.fn.line(".") or nil, direction)
	end
	if not dto then
		return vim.notify("review: no comments on files here", vim.log.levels.INFO)
	end
	local c = view_mapper.to_comment_view_model(dto)
	vim.api.nvim_echo({ { ("comment %d of %d · %s"):format(index, total, c.location), "Comment" } }, false, {})
	M.show(c)
end

function M.file_counts(root)
	root = real(root)
	if not root then
		return {}
	end
	if not counts_cache[root] then
		counts_cache[root] = view_mapper.to_counts_by_path(reviews():file_counts(root))
	end
	return counts_cache[root]
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

local app = require("workspace.workbench.presentation.nvim.app")
local miles_view_mapper = require("workspace.legio.presentation.mappers.miles_view_mapper")
local mapper = require("workspace.conversations.presentation.mappers.inquiry_view_mapper")
local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")

local M = {}

local function drafting()
	return app.services().drafting
end

function M.key(target)
	return drafting():key(target)
end

function M.starts_session(target)
	return drafting():starts_session(target)
end

function M.file(target)
	return drafting():file(target)
end

function M.load(target)
	return drafting():load(target)
end

function M.write(target, text)
	drafting():write(mapper.to_write_draft_command(target, text))
end

function M.discard(target)
	drafting():discard(target)
end

function M.save_clipboard_image()
	return drafting():capture_image()
end

local function paste_keys(buf, target)
	vim.keymap.set("i", "<C-v>", function()
		local path = M.save_clipboard_image()
		if not path then
			return vim.api.nvim_paste(vim.fn.getreg("+"), false, -1)
		end
		vim.api.nvim_paste(drafting():attach_image(mapper.to_attach_image_command(target, path)), false, -1)
	end, { buffer = buf, desc = "paste a screenshot or text" })
end

local function deliver(draft, done)
	local target = draft.target
	if target.expeditio or target.mandatum then
		local ok, why = require("workspace.workflow.presentation.nvim.mandatum_actions").save(target, draft.message)
		if not ok then
			vim.notify(why or "couldn't save it", vim.log.levels.WARN)
		end
		return done(ok ~= false and ok ~= nil, target.expeditio and "expeditio" or "mandatum")
	end
	app.services().miles_runner:deliver(miles_view_mapper.to_deliver_command(target, draft.message), done)
end

function M.send(target, done)
	local review = require("workspace.workflow.presentation.nvim.review_marks")
	local miles = target.agent and app.services().roster:get(target.agent)
	local root = miles and miles.root
	local comments = root and review.drafts_for(root) or {}
	local draft =
		drafting():outgoing(mapper.to_outgoing_command(target, #comments > 0 and review.prompt(comments, root) or nil))
	if not draft then
		vim.notify("nothing to send", vim.log.levels.WARN)
		return done(false)
	end
	deliver(draft, function(ok, how)
		if ok then
			M.discard(target)
			if #comments > 0 then
				review.send(root, comments, target.agent)
			end
			local said = { held = "held until this turn ends: ", mandatum = "saved ", expeditio = "saved " }
			vim.notify((said[how] or "sent to ") .. (target.name or "the agent"))
		end
		done(ok, ok and draft.message or nil)
	end)
end

function M.edit(win, target, done, opts)
	local file = M.file(target)
	if not vim.uv.fs_stat(file) then
		M.write(target, "")
	end
	local buf = vim.fn.bufadd(file)
	vim.b[buf].draft = true
	vim.b[buf].no_lsp = true
	vim.bo[buf].autoread = true
	vim.fn.bufload(buf)
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_set_current_win(win)
	for option, value in pairs({
		wrap = true,
		linebreak = true,
		number = false,
		relativenumber = false,
		signcolumn = "yes:1",
		foldcolumn = "2",
		winbar = " ",
	}) do
		vim.api.nvim_set_option_value(option, value, { win = win, scope = "local" })
	end
	local function text()
		return vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
	end
	local function save()
		if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
			vim.api.nvim_buf_call(buf, function()
				vim.cmd("silent! write")
			end)
		end
	end
	local group = vim.api.nvim_create_augroup("Draft" .. buf, { clear = true })
	vim.api.nvim_create_autocmd(
		{ "BufLeave", "InsertLeave", "FocusLost" },
		{ group = group, buffer = buf, callback = save }
	)
	local function close_buffer()
		vim.bo[buf].modified = false
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
				pcall(vim.api.nvim_buf_delete, buf, { force = true })
			end
		end)
	end
	local function leave(keep)
		vim.cmd.stopinsert()
		if keep and text() ~= "" then
			save()
		else
			M.discard(target)
		end
		close_buffer()
		vim.schedule(function()
			done(false)
		end)
	end
	local function back()
		leave(true)
	end
	local function discard()
		leave(false)
	end
	local function send()
		vim.cmd.stopinsert()
		save()
		M.send(target, function(ok, message)
			if ok then
				close_buffer()
				done(true, message)
			end
		end)
	end
	local verb = target.expeditio and "save the expeditio"
		or target.mandatum and "save the mandatum"
		or "send to the agent"
	vim.keymap.set({ "n", "i" }, "<C-s>", send, { buffer = buf, desc = verb })
	vim.keymap.set("n", "<leader>s", send, { buffer = buf, desc = verb })
	paste_keys(buf, target)
	vim.keymap.set("n", "q", back, { buffer = buf, desc = "keep the draft and go back" })
	vim.keymap.set("n", "<Esc>", discard, { buffer = buf, desc = "discard the draft" })
	if text() == "" and not (opts and opts.quiet) then
		vim.cmd.startinsert()
	end
	return buf
end

function M.compose(target)
	if not app.workspace then
		return vim.notify("drafts are written in a workspace's conversation view", vim.log.levels.WARN)
	end
	app.update_screen(ConversationScreen, function(v)
		v:compose(target)
	end)
	app.focus("conversation")
end

return M

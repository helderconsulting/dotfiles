local app = require("configs.app")
local runner = require("configs.runner")
local Draft = app.models.Draft

local M = {}

local function read(path)
	local f = io.open(path)
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	return text
end

local function write(path, text)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	local f = io.open(path, "w")
	if f then
		f:write(text)
		f:close()
	end
end

function M.file(target)
	return app.paths.draft(Draft.key(target))
end

local function images_file(target)
	return (M.file(target):gsub("%.md$", ".images.json"))
end

function M.load(target)
	local file = M.file(target)
	local st = vim.uv.fs_stat(file)
	if not st then
		return nil
	end
	local ok, images = pcall(vim.json.decode, read(images_file(target)) or "")
	return Draft.new(target, vim.trim(read(file) or ""), ok and type(images) == "table" and images or {}, st.mtime.sec, st.birthtime and st.birthtime.sec)
end

function M.write(target, text)
	write(M.file(target), text)
end

function M.discard(target)
	os.remove(M.file(target))
	os.remove(images_file(target))
end

function M.save_clipboard_image()
	vim.fn.mkdir(app.paths.images, "p")
	local path = ("%s/%s-%d.png"):format(app.paths.images, os.date("%Y%m%d-%H%M%S"), vim.uv.hrtime() % 1000)
	local res = vim.system({
		"osascript",
		"-e",
		"set png to (the clipboard as «class PNGf»)",
		"-e",
		('set f to open for access POSIX file "%s" with write permission'):format(path),
		"-e",
		"write png to f",
		"-e",
		"close access f",
	}):wait()
	if res.code ~= 0 then
		os.remove(path)
		return nil
	end
	return path
end

local function paste_keys(buf, target)
	vim.keymap.set("i", "<C-v>", function()
		local path = M.save_clipboard_image()
		if not path then
			return vim.api.nvim_paste(vim.fn.getreg("+"), false, -1)
		end
		local draft = M.load(target) or Draft.new(target)
		local tag = draft:attach(path)
		write(images_file(target), vim.json.encode(draft.images))
		vim.api.nvim_paste(tag, false, -1)
	end, { buffer = buf, desc = "paste a screenshot or text" })
end

function M.send(target, done)
	local draft = M.load(target)
	local review = require("configs.review")
	local agent = target.agent and app.agent(target.agent)
	local root = agent and agent.root
	local comments = root and review.drafts_for(root) or {}
	if (not draft or draft:is_empty()) and #comments == 0 then
		vim.notify("nothing to send", vim.log.levels.WARN)
		return done(false)
	end
	draft = (draft or Draft.new(target)):with_review(#comments > 0 and review.prompt(comments, root) or nil)
	runner.deliver(draft, function(ok, how)
		if ok then
			M.discard(target)
			if #comments > 0 then
				review.send(root, comments, target.agent)
			end
			local said = { held = "held until this turn ends: ", todo = "saved todo: " }
			vim.notify((said[how] or "sent to ") .. (target.name or "the agent"))
		end
		done(ok, ok and draft:message() or nil)
	end)
end

function M.edit(win, target, done, opts)
	local file = M.file(target)
	if not vim.uv.fs_stat(file) then
		write(file, "")
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
	for option, value in pairs({ wrap = true, linebreak = true, number = false, relativenumber = false, signcolumn = "yes:1", foldcolumn = "2", winbar = " " }) do
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
	vim.api.nvim_create_autocmd({ "BufLeave", "InsertLeave", "FocusLost" }, { group = group, buffer = buf, callback = save })
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
	local verb = target.todo and "save the todo" or "send to the agent"
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
	app.update_view(function(v)
		v:compose(target)
	end)
	app.focus("conversation")
end

return M

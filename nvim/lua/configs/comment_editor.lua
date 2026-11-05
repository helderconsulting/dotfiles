local M = {}

local reserve_ns = vim.api.nvim_create_namespace("review_reserve")

function M.open(title, initial, on_save, images, inline)
	images = vim.deepcopy(images or {})
	title = title or ""
	local saved = false
	local origin = vim.api.nvim_get_current_win()
	local line = vim.fn.winline()
	local origin_height = vim.api.nvim_win_get_height(origin)
	local below = origin_height - line - 3
	local above = line - 1 - 3
	local up = below < 3 and above > below
	local room = math.max(up and above or below, 1)
	local indent = 0
	if vim.b[vim.api.nvim_win_get_buf(origin)].answer_session then
		indent = math.max(vim.fn.getwininfo(origin)[1].textoff - 3, 0)
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial or "", "\n"))
	local placement = {
		relative = "win",
		win = origin,
		anchor = up and "SW" or "NW",
		row = up and line - 1 or line,
		col = indent,
	}
	local reserve
	if inline then
		local info = vim.fn.getwininfo(origin)[1]
		local last = vim.api.nvim_buf_get_lines(inline.buf, inline.line - 1, inline.line, false)[1] or ""
		local last_col = vim.wo[origin].wrap and math.max(#last, 1) or 1
		local pos = vim.fn.screenpos(origin, inline.line, last_col)
		if pos.row > 0 then
			placement = {
				relative = "win",
				win = origin,
				bufpos = { inline.line - 1, last_col - 1 },
				anchor = "NW",
				row = 1,
				col = info.textoff - (pos.col - info.wincol),
			}
			room = math.max(info.height - (pos.row - info.winrow) - 1, 6)
			local mark
			reserve = function(rows)
				if vim.api.nvim_buf_is_valid(inline.buf) then
					local blank = {}
					for _ = 1, rows do
						table.insert(blank, { { " ", "Normal" } })
					end
					mark = vim.api.nvim_buf_set_extmark(inline.buf, reserve_ns, inline.line - 1, 0, { id = mark, virt_lines = blank })
				end
			end
		end
	end
	local style = reserve and {
		width = math.max(vim.fn.getwininfo(origin)[1].width - vim.fn.getwininfo(origin)[1].textoff, 10),
		height = math.min(3, room),
		border = { "", " ", "", "", "", " ", "", "" },
		footer = { { inline.hint or (inline.on_todo and "Ctrl + s save · Ctrl + S send · Ctrl + t todo · q cancel " or "Ctrl + s save · Ctrl + S send · q cancel "), "AnswerCommentStatus" } },
		footer_pos = "right",
		style = "minimal",
	}
	local win = vim.api.nvim_open_win(buf, true, vim.tbl_extend("force", placement, style or {
		width = math.max(vim.api.nvim_win_get_width(origin) - indent - 2, 10),
		height = math.min(4, room),
		border = { " ", " ", " ", " ", " ", " ", " ", " " },
		title = { { "  " .. title, "ReviewNoteTitle" } },
		title_pos = "left",
		footer = { { (inline and inline.on_todo) and "Ctrl + s save · Ctrl + S send · Ctrl + t todo · q cancel " or "Ctrl + s save · Ctrl + S send · q cancel ", "ReviewNoteHint" } },
		footer_pos = "right",
		style = "minimal",
	}))
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].signcolumn = "yes:1"
	if reserve then
		vim.wo[win].winhighlight = "Normal:AnswerCommentText,EndOfBuffer:AnswerCommentText,SignColumn:AnswerComment,"
			.. "FloatBorder:AnswerComment,FloatFooter:AnswerCommentStatus"
	else
		vim.wo[win].winbar = " "
		vim.wo[win].winhighlight = "Normal:ReviewNoteLine,EndOfBuffer:ReviewNoteLine,SignColumn:ReviewNoteLine,"
			.. "WinBar:ReviewNoteLine,FloatBorder:ReviewNoteLine"
	end
	local function fit()
		if vim.api.nvim_win_is_valid(win) then
			local lines = vim.api.nvim_win_text_height(win, {}).all
			local height = math.max(math.min(math.max(lines, 3), 12, room - 1), 1) + (reserve and 0 or 1)
			vim.api.nvim_win_set_height(win, height)
			if reserve then
				reserve(height + 2)
			end
		end
	end
	fit()
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = buf, callback = fit })
	local function close()
		vim.cmd.stopinsert()
		pcall(vim.api.nvim_win_close, win, true)
		if inline and vim.api.nvim_buf_is_valid(inline.buf) then
			vim.api.nvim_buf_clear_namespace(inline.buf, reserve_ns, 0, -1)
		end
		if inline and inline.restore then
			vim.schedule(inline.restore)
		end
		if inline and inline.on_cancel and not saved then
			vim.schedule(inline.on_cancel)
		end
	end
	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = buf,
		once = true,
		callback = function()
			vim.schedule(close)
		end,
	})
	local function save(send_now)
		local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
		saved = true
		close()
		vim.schedule(function()
			on_save(text, send_now, images)
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
	if inline and inline.on_todo then
		vim.keymap.set({ "n", "i" }, "<C-t>", function()
			local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
			close()
			if text ~= "" then
				vim.schedule(function()
					inline.on_todo(text, images)
				end)
			end
		end, { buffer = buf })
	end
	vim.keymap.set("n", "q", close, { buffer = buf })
	vim.keymap.set("n", "<Esc>", close, { buffer = buf })
	vim.keymap.set("i", "<C-v>", function()
		local path = require("configs.drafts").save_clipboard_image()
		if not path then
			return vim.api.nvim_paste(vim.fn.getreg("+"), false, -1)
		end
		local n = 1
		while images[tostring(n)] do
			n = n + 1
		end
		images[tostring(n)] = path
		vim.api.nvim_paste("[Image #" .. n .. "]", false, -1)
	end, { buffer = buf })
	if not initial or initial == "" then
		vim.cmd.startinsert()
	end
end

return M

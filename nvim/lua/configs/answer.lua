local format = require("workspace.format")
local Review = require("workspace.models.review")
local box = require("configs.comment_box")

local M = {}

local block_width = 64
local prompt_ns = vim.api.nvim_create_namespace("answer_prompt")

function M.clock(t)
	return format.clock(t)
end

function M.wrap_text(text, width)
	local out, line = {}, ""
	for found in text:gmatch("%S+") do
		local word = found
		while vim.fn.strdisplaywidth(word) > width do
			if line ~= "" then
				table.insert(out, line)
				line = ""
			end
			table.insert(out, vim.fn.strcharpart(word, 0, width))
			word = vim.fn.strcharpart(word, width)
		end
		if line == "" then
			line = word
		elseif vim.fn.strdisplaywidth(line .. " " .. word) <= width then
			line = line .. " " .. word
		else
			table.insert(out, line)
			line = word
		end
	end
	if line ~= "" or #out == 0 then
		table.insert(out, line)
	end
	return out
end

local function prompt_lines(lines, text, count)
	for _, raw in ipairs(vim.split(text, "\n")) do
		if count >= 40 then
			table.insert(lines, "  …")
			return count
		end
		raw = raw:gsub("%[Image: source: [^%]]+%]", "(image)")
		local quote = raw:match("^>%s?")
		local body = quote and raw:sub(#quote + 1) or raw
		for _, part in ipairs(M.wrap_text(body, block_width)) do
			if part == "" then
				table.insert(lines, quote and "  >" or "")
			else
				table.insert(lines, (quote and "  > " or "  ") .. part)
			end
			count = count + 1
		end
	end
	return count
end

local function comment_lines(lines, parts, comments)
	for _, part in ipairs(parts) do
		if part.heading then
			table.insert(lines, "  " .. part.heading)
		else
			table.insert(lines, "")
			table.insert(comments, {
				row = #lines - 1,
				quote = part.quote,
				text = (part.text:gsub("%[Image: source: [^%]]+%]", "(image)")),
				status = part.label and (part.label:gsub("^%[%x+%]%s*", "")) or nil,
			})
		end
	end
end

local function turn_lines(turn, in_progress)
	local lines, comments = { "" }, {}
	if turn.from then
		table.insert(lines, "  from " .. turn.from)
		table.insert(lines, "")
	end
	local parts = Review.parse_prompt(turn.prompt)
	if parts then
		comment_lines(lines, parts, comments)
	else
		prompt_lines(lines, turn.prompt, 0)
	end
	table.insert(lines, "")
	local block = #lines
	if in_progress then
		return lines, block, comments
	end
	table.insert(lines, "")
	vim.list_extend(lines, vim.split(#turn.reply == 0 and "_no reply_" or table.concat(turn.reply, "\n\n"), "\n"))
	return lines, block, comments
end

local function decorate(buf, block, comments)
	vim.api.nvim_buf_clear_namespace(buf, prompt_ns, 0, -1)
	for _, c in ipairs(comments or {}) do
		local rows = box.code(c.quote, vim.o.columns, nil, block_width + 4)
		vim.list_extend(rows, box.note(c.text, vim.o.columns, c.status, nil, block_width + 4))
		vim.api.nvim_buf_set_extmark(buf, prompt_ns, c.row, 0, { virt_lines = rows })
	end
	for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, block, false)) do
		local row = i - 1
		vim.api.nvim_buf_set_extmark(buf, prompt_ns, row, 0, { line_hl_group = "AnswerPrompt", priority = 50 })
		local indent, quote = line:match("^(%s*)(>%s?)")
		if quote then
			vim.api.nvim_buf_set_extmark(buf, prompt_ns, row, #indent, {
				end_col = #indent + #quote,
				conceal = "",
				virt_text = { { "│ ", "AnswerQuoteBar" } },
				virt_text_pos = "inline",
			})
			vim.api.nvim_buf_set_extmark(buf, prompt_ns, row, #indent + #quote, { end_col = #line, hl_group = "AnswerQuote", priority = 200 })
		elseif line ~= "" then
			vim.api.nvim_buf_set_extmark(buf, prompt_ns, row, 0, { end_col = #line, hl_group = "AnswerPromptText", priority = 200 })
		end
		local from = 1
		while true do
			local start, finish = line:find("(image)", from, true)
			if not start then
				break
			end
			vim.api.nvim_buf_set_extmark(buf, prompt_ns, row, start - 1, { end_col = finish, hl_group = "AnswerQuoteBar", priority = 210 })
			from = finish + 1
		end
	end
end

local function fill(buf, lines, block, comments)
	local old = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	if vim.deep_equal(old, lines) then
		return decorate(buf, block, comments)
	end
	local first = 1
	while first <= #old and first <= #lines and old[first] == lines[first] do
		first = first + 1
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, first - 1, -1, false, vim.list_slice(lines, first))
	vim.bo[buf].modifiable = false
	decorate(buf, block, comments)
	vim.api.nvim_exec_autocmds("User", { pattern = "AnswerFilled", data = { buf = buf } })
end

local function scratch(name)
	local buf = vim.fn.bufnr(name)
	if buf == -1 then
		buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, name)
	end
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].modifiable = false
	return buf
end

function M.pending_buffer(text)
	local buf = scratch("answer://pending")
	fill(buf, turn_lines({ prompt = text, reply = {} }, true))
	return buf
end

function M.entry_buffer(doc)
	local buf = scratch("answer://entry")
	local lines = { "", "  " .. doc.header, "" }
	vim.list_extend(lines, doc.lines)
	fill(buf, lines, #lines, {})
	return buf
end

function M.placeholder(text)
	local buf = scratch("answer://placeholder")
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "  " .. text })
	vim.bo[buf].modifiable = false
	return buf
end

function M.buffer(transcript, i, root, in_progress)
	local buf = scratch(("answer://%s/%d"):format(transcript.id, i))
	vim.b[buf].answer_root = root
	vim.b[buf].answer_session = transcript.id
	vim.b[buf].answer_turn = i
	fill(buf, turn_lines(transcript:turn(i), in_progress))
	return buf
end

function M.window_options(win)
	for option, value in pairs({
		wrap = true,
		linebreak = true,
		breakindent = true,
		number = false,
		relativenumber = false,
		signcolumn = "yes:1",
		foldcolumn = "2",
		conceallevel = 2,
		concealcursor = "nc",
		foldenable = false,
		winbar = " ",
	}) do
		vim.api.nvim_set_option_value(option, value, { win = win, scope = "local" })
	end
end

return M

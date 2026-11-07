local M = {}

function M.wrap(text, width)
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

function M.width(win)
	if win and win ~= -1 and vim.api.nvim_win_is_valid(win) then
		return vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
	end
	return 72
end

local function pad(text, width)
	return text .. string.rep(" ", math.max(width - vim.fn.strdisplaywidth(text), 0))
end

local function row(text, hl, width)
	return { { pad(text, width), hl } }
end

function M.code(lines, width, sign, wrap_width)
	local rows = {}
	for _, line in ipairs(lines) do
		for _, l in ipairs(wrap_width and M.wrap(line, wrap_width - 2) or { line }) do
			table.insert(rows, { { "▍", sign or "ReviewSentSign" }, { pad(" " .. l, width - 1), "ReviewNoteLine" } })
		end
	end
	return rows
end

function M.note(text, width, status, reply, wrap_width)
	local inner = math.max((wrap_width or width) - 4, 20)
	local rows = { row("", "AnswerComment", width) }
	for _, l in ipairs(M.wrap(text, inner)) do
		table.insert(rows, row("  " .. l, "AnswerCommentText", width))
	end
	if status then
		table.insert(rows, row("", "AnswerComment", width))
		table.insert(rows, row("  " .. status, "AnswerCommentStatus", width))
		for _, l in ipairs(reply and M.wrap(reply, inner) or {}) do
			if l ~= "" then
				table.insert(rows, row("  " .. l, "AnswerCommentStatus", width))
			end
		end
	end
	table.insert(rows, row("", "AnswerComment", width))
	return rows
end

return M

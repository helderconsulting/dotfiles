local M = {}

M.height = 3
M.heading = 1

local kinds = { ok = "CardOk", busy = "CardBusy", bad = "CardBad", off = "CardOff" }

function M.fit(text, width)
	text = (text or ""):gsub("\n.*", "")
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end
	return vim.fn.strcharpart(text, 0, math.max(width - 1, 0)) .. "…"
end

function M.first_line(index)
	return M.heading + (index - 1) * M.height + 1
end

function M.index_at(line)
	return line > M.heading and math.floor((line - M.heading - 1) / M.height) + 1 or nil
end

function M.render(buf, win, ns, list, card, opts)
	opts = opts or {}
	local selected, active, marked = opts.selected, opts.active, opts.multi and opts.marked or nil
	local inset = opts.multi and 4 or 3
	if not (buf and vim.api.nvim_buf_is_valid(buf) and win and vim.api.nvim_win_is_valid(win)) then
		return
	end
	local width = vim.api.nvim_win_get_width(win)
	local lines, marks = { "" }, {}
	local function mark(line, col, end_col, group, line_group)
		table.insert(marks, { line = line, col = col, end_col = end_col, group = group, line_group = line_group })
	end
	for i, e in ipairs(list) do
		local chosen = i == selected
		local text = card(e)
		local kind = kinds[e.kind] or "CardOff"
		local mark_on = marked and marked[e.id]
		local bg = chosen and (active == false and kind .. "BgInactive" or kind .. "Bg") or mark_on and "CardMarkedBg" or nil
		local rows = {
			{ M.fit(text[1], width - inset), chosen and active ~= false and kind .. "Current" or kind },
			{ M.fit(text[2], width - inset), kind .. "Detail" },
			{ M.fit(text[3], width - inset), kind },
		}
		for _, row in ipairs(rows) do
			local gap = mark_on and "▌ " or opts.multi and "  " or " "
			local line_text = "▌" .. gap .. row[1]
			table.insert(lines, line_text)
			mark(#lines - 1, 0, #"▌", kind)
			mark(#lines - 1, #"▌", #line_text, row[2], bg)
			if mark_on then
				mark(#lines - 1, #"▌", #"▌▌", "CardMarked")
			end
		end
		if chosen and active ~= false then
			local card_bg = vim.api.nvim_get_hl(0, { name = kind .. "Bg" }).bg
			local fg = mark_on and vim.api.nvim_get_hl(0, { name = "CardMarked" }).fg or card_bg
			vim.api.nvim_set_hl(0, "CardCursor", { fg = fg, bg = card_bg })
		end
	end
	if #list == 0 then
		table.insert(lines, "  " .. (opts.empty or "nothing here"))
		mark(#lines - 1, 0, #lines[#lines], "CardOffDetail")
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, m in ipairs(marks) do
		vim.api.nvim_buf_set_extmark(buf, ns, m.line, m.col, {
			end_col = m.end_col,
			hl_group = m.group,
			line_hl_group = m.line_group,
		})
	end
	if selected then
		vim.api.nvim_win_set_cursor(win, { M.first_line(selected), #"▌" })
	end
end

return M

local M = {}

M.height = 3
M.heading = 1

local kinds = { ok = "CardOk", busy = "CardBusy", bad = "CardBad", off = "CardOff" }
local layouts = {}

function M.fit(text, width)
	text = (text or ""):gsub("\n.*", "")
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end
	return vim.fn.strcharpart(text, 0, math.max(width - 1, 0)) .. "…"
end

function M.wrap(text, width, max)
	local out = {}
	width = math.max(width, 1)
	for para in ((text or "") .. "\n"):gmatch("(.-)\n") do
		if para:match("^%s*$") then
			if #out > 0 and out[#out] ~= "" then
				table.insert(out, "")
			end
		else
			local indent = para:match("^%s*"):sub(1, math.floor(width / 2))
			local line = ""
			for word in para:gmatch("%S+") do
				local candidate = line == "" and (indent .. word) or (line .. " " .. word)
				if vim.fn.strdisplaywidth(candidate) <= width then
					line = candidate
				else
					if line ~= "" then
						table.insert(out, line)
					end
					line = indent .. word
					while vim.fn.strdisplaywidth(line) > width do
						table.insert(out, vim.fn.strcharpart(line, 0, width))
						line = vim.fn.strcharpart(line, width)
					end
				end
			end
			if line ~= "" then
				table.insert(out, line)
			end
		end
	end
	while #out > 0 and out[#out] == "" do
		table.remove(out)
	end
	if #out == 0 then
		out = { "" }
	end
	if max and #out > max then
		out = vim.list_slice(out, 1, max)
		local last = out[max]
		if vim.fn.strdisplaywidth(last) + 2 > width then
			last = vim.fn.strcharpart(last, 0, math.max(width - 2, 0)):gsub("%s+$", "")
		end
		out[max] = last .. " …"
	end
	return out
end

function M.first_line(index, buf)
	local starts = buf and layouts[buf]
	if starts then
		return starts[index] or M.heading + 1
	end
	return M.heading + (index - 1) * M.height + 1
end

function M.index_at(line, buf)
	local starts = buf and layouts[buf]
	if starts then
		local found
		for i, start in ipairs(starts) do
			if start <= line then
				found = i
			end
		end
		return found
	end
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
	local lines, marks, starts = { "" }, {}, {}
	local function mark(line, col, end_col, group, line_group)
		table.insert(marks, { line = line, col = col, end_col = end_col, group = group, line_group = line_group })
	end
	for i, e in ipairs(list) do
		local chosen = i == selected
		local text = card(e)
		local kind = kinds[e.kind] or "CardOff"
		local mark_on = marked and marked[e.id]
		local bg = chosen and (active == false and kind .. "BgInactive" or kind .. "Bg") or mark_on and "CardMarkedBg" or nil
		local groups = { chosen and active ~= false and kind .. "Current" or kind, kind .. "Detail", kind }
		local rows = {}
		for k = 1, 3 do
			local parts
			if opts.wrap and k < 3 then
				local max = k == 1 and 2 or chosen and math.max(vim.api.nvim_win_get_height(win) - 6, 3) or 2
				parts = M.wrap(text[k], width - inset, max)
			else
				parts = { M.fit(text[k], width - inset) }
			end
			for _, part in ipairs(parts) do
				table.insert(rows, { part, groups[k] })
			end
		end
		starts[i] = #lines + 1
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
	layouts[buf] = opts.wrap and starts or nil
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
		vim.api.nvim_win_set_cursor(win, { M.first_line(selected, buf), #"▌" })
	end
end

return M

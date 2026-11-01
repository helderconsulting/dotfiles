local M = {}

M.height = 3
M.heading = 1

local kind_groups = { ok = "SidebarOk", busy = "SidebarBusy", bad = "SidebarBad", off = "SidebarOff" }

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

function M.render(buf, win, ns, list, card, selected, empty, active)
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
		local kind = kind_groups[e.kind] or "SidebarOff"
		local rows = {
			{ M.fit(text[1], width - 3), chosen and active ~= false and "SidebarNameCurrent" or "SidebarName" },
			{ M.fit(text[2], width - 3), "SidebarDetail" },
			{ M.fit(text[3], width - 3), kind },
		}
		for _, row in ipairs(rows) do
			local line_text = "▌ " .. row[1]
			table.insert(lines, line_text)
			mark(#lines - 1, 0, #"▌", kind)
			mark(#lines - 1, #"▌", #line_text, row[2], chosen and (active == false and "SidebarCardInactive" or "SidebarCard") or nil)
		end
	end
	if #list == 0 then
		table.insert(lines, "  " .. (empty or "nothing here"))
		mark(#lines - 1, 0, #lines[#lines], "SidebarDetail")
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

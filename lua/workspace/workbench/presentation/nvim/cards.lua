local M = {}

M.height = 3
M.dot = "  ●"
M.heading = 1

local kinds = { ok = "CardOk", busy = "CardBusy", bad = "CardBad", off = "CardOff", limit = "CardLimit" }

M.meter_width = 10

M.meter_line = "━"

function M.meter(m, room, kind)
	if not m.fraction then
		local text = M.fit(m.label or "", room)
		return text, { { 0, #text, kind .. "Detail" } }
	end
	local filled = math.max(0, math.min(M.meter_width, math.floor(m.fraction * M.meter_width + 0.5)))
	local percent = ("%4s "):format(m.percent or "")
	local bar = string.rep(M.meter_line, M.meter_width)
	local text = M.fit(percent .. bar .. ((m.label or "") ~= "" and ("  " .. m.label) or ""), room)
	local start = #percent
	local split, track = start + #string.rep(M.meter_line, filled), start + #bar
	local spans = {}
	for _, span in ipairs({
		{ 0, start, kind },
		{ start, split, kind },
		{ split, track, kind .. "Track" },
		{ track, #text, kind .. "Detail" },
	}) do
		local from, to = math.min(span[1], #text), math.min(span[2], #text)
		if to > from then
			table.insert(spans, { from, to, span[3] })
		end
	end
	return text, spans
end
local decorations = { ok = "Strong", busy = "Emph", bad = "Alert", off = "Detail" }

function M.segments(list, room, kind)
	local text = ""
	for _, seg in ipairs(list) do
		text = text .. seg[1]
	end
	text = M.fit(text, room)
	local spans, at = {}, 0
	for _, seg in ipairs(list) do
		local stop = math.min(at + #seg[1], #text)
		if seg[2] == "lead" and stop > at then
			table.insert(spans, { at, stop, "CardLead" })
		elseif seg[2] and decorations[seg[2]] and stop > at then
			table.insert(spans, { at, stop, (kind or "CardOff") .. decorations[seg[2]] })
		end
		at = at + #seg[1]
	end
	return text, spans
end

local layouts = {}
local stickies = {}

local written = {}

local function pin(buf, key, win, ns, lines, marks, first, last, row)
	stickies[buf] = stickies[buf] or {}
	local s = stickies[buf][key]
	if not first then
		if s and s.win and vim.api.nvim_win_is_valid(s.win) then
			vim.api.nvim_win_hide(s.win)
		end
		return
	end
	if not s then
		s = { buf = vim.api.nvim_create_buf(false, true) }
		stickies[buf][key] = s
	end
	local content = vim.list_slice(lines, first, last)
	local shown = vim.tbl_filter(function(m)
		return m.line >= first - 1 and m.line <= last - 1
	end, marks)
	local key = vim.inspect({ content, shown, first })
	if s.key ~= key then
		s.key = key
		vim.bo[s.buf].modifiable = true
		vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, content)
		vim.bo[s.buf].modifiable = false
		vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
		for _, m in ipairs(shown) do
			vim.api.nvim_buf_set_extmark(s.buf, ns, m.line - first + 1, m.col, {
				end_col = m.end_col,
				hl_group = m.group,
				line_hl_group = m.line_group,
			})
		end
	end
	local config = {
		relative = "win",
		win = win,
		row = row,
		col = 0,
		width = vim.api.nvim_win_get_width(win),
		height = last - first + 1,
		focusable = false,
		style = "minimal",
		border = "none",
		zindex = 20,
	}
	if s.win and vim.api.nvim_win_is_valid(s.win) then
		vim.api.nvim_win_set_config(s.win, config)
	else
		s.win = vim.api.nvim_open_win(s.buf, false, vim.tbl_extend("force", config, { noautocmd = true }))
		vim.wo[s.win].winhighlight = "NormalFloat:Normal"
	end
end

function M.fit(text, width)
	text = (text or ""):gsub("\n.*", "")
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end
	return vim.fn.strcharpart(text, 0, math.max(width - 1, 0)) .. "…"
end

function M.wrap(text, width)
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
	return out
end

local function find(starts, line)
	local found
	for i, start in ipairs(starts or {}) do
		if start <= line then
			found = i
		end
	end
	return found
end

function M.first_line(index, buf)
	local layout = buf and layouts[buf]
	if layout then
		return layout.starts[index] or M.heading + 1
	end
	return M.heading + (index - 1) * M.height + 1
end

function M.index_at(line, buf)
	local layout = buf and layouts[buf]
	if layout then
		return find(layout.starts, line)
	end
	return line > M.heading and math.floor((line - M.heading - 1) / M.height) + 1 or nil
end

function M.inline_line(buf, index)
	local layout = layouts[buf]
	for k, t in ipairs(layout and layout.inline_index or {}) do
		if t == index then
			return layout.inline_starts[k]
		end
	end
end

function M.inline_at(line, buf)
	local layout = buf and layouts[buf]
	if not (layout and layout.inline_first and line >= layout.inline_first and line <= layout.inline_last) then
		return nil
	end
	local i = find(layout.inline_starts, line)
	return i and layout.inline_index[i]
end

function M.render(buf, win, ns, list, card, opts)
	opts = opts or {}
	local selected, active, marked = opts.selected, opts.active, opts.multi and opts.marked or nil
	if not (buf and vim.api.nvim_buf_is_valid(buf) and win and vim.api.nvim_win_is_valid(win)) then
		return
	end
	local width = vim.api.nvim_win_get_width(win)
	local height = vim.api.nvim_win_get_height(win)
	local lines, marks = opts.frozen and {} or { opts.title and (" " .. opts.title) or "" }, {}
	local layout = { starts = {}, inline_starts = {}, inline_index = {} }
	local cursor, view_end, focus
	local function mark(line, col, end_col, group, line_group)
		table.insert(marks, { line = line, col = col, end_col = end_col, group = group, line_group = line_group })
	end
	if opts.title and not opts.frozen then
		mark(0, 0, #lines[1], "CardOffDetail")
	end
	local function add(e, text, o)
		local kind = kinds[e.kind] or "CardOff"
		local bg = o.chosen and (o.active == false and kind .. "BgInactive" or kind .. "Bg") or o.mark_on and "CardMarkedBg" or nil
		local groups = { o.chosen and o.active ~= false and kind .. "Current" or kind, kind .. "Detail", kind }
		local indent = o.indent .. (e.indent or "")
		local prefix = indent .. (e.bar or "▌")
		local inset = vim.fn.strdisplaywidth(indent) + (o.multi and 4 or 3)
		local rows = {}
		local count = 3
		if o.wrap then
			count = #text
		else
			while type(text[count + 1]) == "table" do
				count = count + 1
			end
		end
		for k = 1, o.rows or count do
			local parts
			local room = width - inset - (k == 1 and e.unread and vim.fn.strdisplaywidth(M.dot) or 0)
			if type(text[k]) == "table" and text[k].segments then
				local plain = ""
				for _, seg in ipairs(text[k].segments) do
					plain = plain .. seg[1]
				end
				if o.wrap and vim.fn.strdisplaywidth(plain) > room then
					parts = M.wrap(plain, room)
				else
					local line, spans = M.segments(text[k].segments, room, kind)
					table.insert(rows, { line, groups[k] or groups[2], spans = spans })
					parts = {}
				end
			elseif type(text[k]) == "table" then
				local full = M.meter(text[k], math.huge, kind)
				if o.wrap and vim.fn.strdisplaywidth(full) > room then
					parts = M.wrap(full, room)
				else
					local line, spans = M.meter(text[k], room, kind)
					table.insert(rows, { line, groups[3], spans = spans })
					parts = {}
				end
			elseif o.wrap then
				parts = M.wrap(text[k], room)
			else
				parts = { M.fit(text[k], room) }
			end
			for _, part in ipairs(parts) do
				table.insert(rows, { part, groups[math.min(k, 3)] })
			end
		end
		if e.unread and rows[1] then
			rows[1].dot = true
		end
		local first = #lines + 1
		for _, row in ipairs(rows) do
			local gap = o.mark_on and "▌ " or o.multi and "  " or " "
			local line_text = prefix .. gap .. row[1] .. (row.dot and M.dot or "")
			table.insert(lines, line_text)
			mark(#lines - 1, #indent, #prefix, kind)
			mark(#lines - 1, #prefix, #line_text, row[2], bg)
			for _, span in ipairs(row.spans or {}) do
				local at = #prefix + #gap
				mark(#lines - 1, at + span[1], at + span[2], span[3])
			end
			if row.dot then
				mark(#lines - 1, #line_text - #M.dot, #line_text, "CardUnread")
			end
			if o.mark_on then
				mark(#lines - 1, #prefix, #prefix + #"▌", "CardMarked")
			end
		end
		if o.chosen and o.active ~= false then
			local card_bg = vim.api.nvim_get_hl(0, { name = kind .. "Bg" }).bg
			local fg = o.mark_on and vim.api.nvim_get_hl(0, { name = "CardMarked" }).fg or card_bg
			vim.api.nvim_set_hl(0, "CardCursor", { fg = fg, bg = card_bg })
			cursor = { first, #prefix }
		end
		return first
	end
	for i, e in ipairs(list) do
		local chosen = i == selected
		if e.space_before and not opts.frozen then
			table.insert(lines, "")
		end
		layout.starts[i] = add(e, card(e), {
			chosen = chosen,
			active = active,
			mark_on = marked and marked[e.id],
			multi = opts.multi,
			indent = "",
			wrap = opts.wrap == true,
			rows = opts.rows,
		})
		if chosen then
			view_end = #lines
		end
		local inline = chosen and opts.inline
		if inline and #inline.items > 0 then
			local from = inline.from or inline.limit and math.max(1, #inline.items - inline.limit + 1) or 1
			local to = math.min(inline.to or #inline.items, #inline.items)
			local first_hint = inline.active
				and ((inline.selected or from) .. " of " .. #inline.items .. " · " .. ((inline.unread or 0) > 0 and (inline.unread .. " new") or from > 1 and ("↑ " .. (from - 1) .. " newer") or "latest"))
				or nil
			if first_hint then
				table.insert(lines, "")
				table.insert(lines, "  " .. first_hint)
				mark(#lines - 1, 0, #lines[#lines], "CardOffDetail")
				table.insert(lines, "")
			end
			layout.inline_first = #lines + 1
			for t = from, to do
				local item = inline.items[t]
				table.insert(layout.inline_starts, add(item, inline.card(item), {
					chosen = t == inline.selected,
					active = inline.active,
					indent = "  ",
					wrap = true,
				}))
				table.insert(layout.inline_index, t)
				if inline.active and t == inline.selected then
					view_end = #lines
					focus = { layout.inline_starts[#layout.inline_starts], #lines }
				end
			end
			layout.inline_last = #lines
			local last_hint = inline.active and (to < #inline.items and ("↓ " .. (#inline.items - to) .. " older") or "start of thread") or nil
			if last_hint then
				table.insert(lines, "")
				table.insert(lines, "  " .. last_hint)
				mark(#lines - 1, 0, #lines[#lines], "CardOffDetail")
				if inline.selected == to then
					view_end = #lines
				end
				if not opts.frozen then
					table.insert(lines, "")
				end
			end
			if inline.selected and inline.active then
				for k, t in ipairs(layout.inline_index) do
					if t == inline.selected then
						cursor = { layout.inline_starts[k], #"  ▌" }
					end
				end
			elseif chosen then
				cursor = { layout.starts[i], #"▌" }
			end
		end
	end
	layouts[buf] = layout
	if #list == 0 then
		table.insert(lines, "  " .. (opts.empty or "nothing here"))
		mark(#lines - 1, 0, #lines[#lines], "CardOffDetail")
	end
	local key = vim.inspect({ lines, marks })
	if written[buf] ~= key then
		written[buf] = key
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
	end
	local head, foot
	if selected then
		cursor = cursor or { M.first_line(selected, buf), #"▌" }
		vim.api.nvim_win_set_cursor(win, cursor)
		if opts.frozen and layout.inline_first then
			local fixed_top = layout.inline_first - 1
			local fixed_bottom = #lines - layout.inline_last
			local area = math.max(height - fixed_top - fixed_bottom, 1)
			local top = 1
			if focus then
				top = math.floor((focus[1] + focus[2]) / 2 - fixed_top - (area - 1) / 2 + 0.5)
				top = math.min(top, #lines - height + 1)
				top = math.min(top, focus[1] - fixed_top)
			end
			top = math.max(1, top)
			vim.api.nvim_win_call(win, function()
				vim.fn.winrestview({ topline = top })
			end)
			if top > 1 then
				head = { 1, fixed_top, 0 }
			end
			if fixed_bottom > 0 and top + height - 1 < #lines then
				foot = { #lines - fixed_bottom + 1, #lines, height - fixed_bottom }
			end
		elseif opts.keep_visible and view_end then
			vim.api.nvim_win_call(win, function()
				local top = vim.fn.winsaveview().topline
				top = math.max(top, view_end - height + 1)
				top = math.max(1, math.min(top, cursor[1] - 1))
				vim.fn.winrestview({ topline = top })
			end)
		end
	end
	if opts.keep_visible or opts.frozen or stickies[buf] then
		pin(buf, "head", win, ns, lines, marks, head and head[1], head and head[2], head and head[3])
		pin(buf, "foot", win, ns, lines, marks, foot and foot[1], foot and foot[2], foot and foot[3])
	end
end

return M

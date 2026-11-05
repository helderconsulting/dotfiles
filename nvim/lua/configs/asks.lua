local app = require("configs.app")
local answer = require("configs.answer")
local Ask = app.models.Ask

local M = {}

local ns = vim.api.nvim_create_namespace("asks")

local function agent_name(session, cwd)
	local agent = app.agent(session)
	return agent and agent:display_name() or vim.fs.basename(cwd or "agent")
end

local function text_width(win)
	if not (win and vim.api.nvim_win_is_valid(win)) then
		return 72
	end
	local info = vim.fn.getwininfo(win)[1]
	return info.width - info.textoff
end

local function rows(win)
	local list, r = {}, {}
	function r.add(segments, style)
		table.insert(list, { segments = segments, style = style })
	end
	function r.heading(name, rest)
		r.add({})
		r.add({ { "  " .. name, "AskTitle" }, { rest, "AnswerDim" } })
		r.add({})
	end
	function r.text(paras)
		for _, para in ipairs(paras) do
			for _, part in ipairs(answer.wrap_text(para, 64)) do
				r.add({ { part == "" and "" or ("  " .. part) } })
			end
		end
	end
	function r.choices(choices, selected, hints)
		r.add({})
		r.add({}, "AnswerComment")
		for i, c in ipairs(choices) do
			local style = i == selected and "AskCurrent" or "AnswerComment"
			local segments = { { "  " .. c.key .. "  ", "AnswerCommentStatus" }, { c.label, c.chosen and "AskChosen" or "AnswerCommentText" } }
			if c.extra then
				table.insert(segments, { c.extra, "AnswerCommentStatus" })
			end
			r.add(segments, style)
			if c.description and c.description ~= "" then
				r.add({ { "     " .. c.description, "AnswerCommentStatus" } }, style)
			end
		end
		r.add({}, "AnswerComment")
		local hint = table.concat(hints, " · ") .. " "
		r.add({ { string.rep(" ", math.max(text_width(win) - vim.fn.strdisplaywidth(hint), 2)) .. hint, "AnswerCommentStatus" } }, "AnswerComment")
	end
	function r.write(buf)
		local lines, marks = {}, {}
		for i, row in ipairs(list) do
			local text = ""
			for _, seg in ipairs(row.segments) do
				if seg[2] and seg[1] ~= "" then
					table.insert(marks, { i - 1, #text, #text + #seg[1], seg[2] })
				end
				text = text .. seg[1]
			end
			lines[i] = text
		end
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		for i, row in ipairs(list) do
			if row.style then
				vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = row.style })
			end
		end
		for _, m in ipairs(marks) do
			vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
		end
		return #list
	end
	return r
end

local function new_buffer(name)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	local old = vim.fn.bufnr("^" .. vim.fn.escape(name, "\\[]*?~.") .. "$")
	if old ~= -1 then
		require("configs.bufs").wipe(old, buf)
	end
	vim.api.nvim_buf_set_name(buf, name)
	return buf
end

local function map(buf, key, fn)
	vim.keymap.set("n", key, fn, { buffer = buf, nowait = true })
end

local function update(id, fn)
	app.store():update(Ask, id, function(ask)
		if not ask:is_pending() then
			return false
		end
		return fn(ask, app.now())
	end)
end

local function choose(buf, count, selected, show, pick)
	for _, key in ipairs({ "j", "<Down>" }) do
		map(buf, key, function()
			show(math.min(selected() + 1, count()))
		end)
	end
	for _, key in ipairs({ "k", "<Up>" }) do
		map(buf, key, function()
			show(math.max(selected() - 1, 1))
		end)
	end
	map(buf, "<CR>", function()
		pick(selected())
	end)
end

local function permission(ask, win)
	local buf = new_buffer("ask://" .. ask.id)
	local choices, selected = ask:permission_choices(), 1
	local function decide(c)
		update(ask.id, function(a, now)
			a:decide(c.decision, now)
		end)
	end
	local function show(i)
		selected = i or selected
		local r = rows(win)
		r.heading(agent_name(ask.session, ask.cwd), " wants to use " .. tostring(ask.tool))
		r.text(ask:details())
		r.choices(choices, selected, { "t terminal" })
		r.write(buf)
	end
	for _, c in ipairs(choices) do
		map(buf, c.key, function()
			decide(c)
		end)
	end
	choose(buf, function()
		return #choices
	end, function()
		return selected
	end, show, function(i)
		decide(choices[i])
	end)
	map(buf, "t", function()
		update(ask.id, function(a, now)
			a:dismiss(now)
		end)
	end)
	show()
	return buf
end

local function question(ask, win)
	local buf = new_buffer("ask://" .. ask.id)
	local questions = ask:questions()
	local answers, index, chosen, selected = {}, 1, {}, 1
	local show
	local function record(value)
		answers[questions[index].question] = value
		index, chosen, selected = index + 1, {}, 1
		if index > #questions then
			return update(ask.id, function(a, now)
				a:answer(answers, now)
			end)
		end
		show()
	end
	local function pick(i)
		local q = questions[index]
		local option = q.options and q.options[i]
		if not option then
			return
		end
		if q.multiSelect then
			chosen[i] = not chosen[i] or nil
			return show()
		end
		record(option.label)
	end
	show = function(i)
		selected = i or selected
		local q = questions[index]
		local choices = {}
		for n, option in ipairs(q.options or {}) do
			table.insert(choices, { key = tostring(n), label = option.label, description = option.description, chosen = chosen[n], extra = chosen[n] and " · selected" or nil })
		end
		local hints = { "o other answer" }
		if q.multiSelect then
			table.insert(hints, "Ctrl + s done")
		end
		table.insert(hints, "t terminal")
		local r = rows(win)
		r.heading(agent_name(ask.session, ask.cwd), " asks · " .. (q.header or "question") .. (#questions > 1 and (" · " .. index .. " of " .. #questions) or ""))
		r.text({ q.question })
		r.choices(choices, selected, hints)
		return r.write(buf)
	end
	for n = 1, 9 do
		map(buf, tostring(n), function()
			selected = n
			pick(n)
		end)
	end
	choose(buf, function()
		return #(questions[index].options or {})
	end, function()
		return selected
	end, show, pick)
	map(buf, "<C-s>", function()
		local labels = {}
		for n, option in ipairs(questions[index].options or {}) do
			if chosen[n] then
				table.insert(labels, option.label)
			end
		end
		if questions[index].multiSelect and #labels > 0 then
			record(table.concat(labels, ", "))
		end
	end)
	map(buf, "o", function()
		require("configs.review").inline_input(buf, show(), "Ctrl + s submit · q back ", function(text)
			if text ~= "" then
				record(text)
			else
				show()
			end
		end, show)
	end)
	map(buf, "t", function()
		update(ask.id, function(a, now)
			a:dismiss(now)
		end)
	end)
	show()
	return buf
end

function M.buffer(id, win)
	local ask = app.store():get(Ask, id)
	if not (ask and ask:is_pending()) then
		return nil
	end
	return ask:is_question() and question(ask, win) or permission(ask, win)
end

local function exchange(entry, win)
	local buf = new_buffer("exchange://" .. tostring(entry.session) .. "/" .. tostring(entry.peer))
	local me = agent_name(entry.session)
	local r = rows(win)
	r.heading(me, " and " .. tostring(entry.name) .. (entry.turn and (" · turn " .. entry.turn) or ""))
	for _, m in ipairs(entry.messages or {}) do
		local from, to = me, entry.name
		if not m.mine then
			from, to = to, from
		end
		r.add({ { "  " .. from, "AskTitle" }, { " to " .. to .. " · " .. app.age(m.at) .. " ago", "AnswerDim" } })
		r.text(vim.split(m.text or "", "\n", { plain = true }))
		r.add({})
	end
	r.write(buf)
	return buf
end

function M.history(entry, win)
	if entry.type == "exchange" then
		return exchange(entry, win)
	end
	local buf = new_buffer("ask-history://" .. tostring(entry.at))
	local ask = Ask:new(entry)
	local r = rows(win)
	local when = entry.decision == "terminal" and "answered in the terminal" or (app.age(entry.at) .. " ago")
	if ask:is_question() then
		local questions = ask:questions()
		for qi, q in ipairs(questions) do
			local given = (entry.answers or {})[q.question]
			local picked, matched = {}, false
			for part in tostring(given or ""):gmatch("[^,]+") do
				picked[vim.trim(part)] = true
			end
			r.heading(agent_name(entry.session, entry.root), " asked · " .. (q.header or "question") .. (#questions > 1 and (" · " .. qi .. " of " .. #questions) or ""))
			r.text({ q.question })
			local choices = {}
			for n, option in ipairs(q.options or {}) do
				local hit = picked[option.label] == true
				matched = matched or hit
				table.insert(choices, { key = tostring(n), label = option.label, description = option.description, chosen = hit, extra = hit and " · your answer" or nil })
			end
			if given and not matched then
				table.insert(choices, { key = "o", label = given, chosen = true, extra = " · your answer" })
			end
			r.choices(choices, nil, { when })
		end
	else
		r.heading(agent_name(entry.session, entry.root), " wanted to use " .. tostring(entry.tool))
		r.text(ask:details())
		local choices = ask:permission_choices()
		for _, c in ipairs(choices) do
			if c.decision == entry.decision then
				c.chosen, c.extra = true, (c.extra or "") .. " · your answer"
			end
		end
		r.choices(choices, nil, { when })
	end
	r.write(buf)
	return buf
end

return M

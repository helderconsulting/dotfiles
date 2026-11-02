local M = {}

local state_dir = (vim.env.XDG_STATE_HOME or (vim.env.HOME .. "/.local/state")) .. "/agent-status"

local function cli(...)
	local out = vim.system({ "wezterm", "cli", ... }, { text = true }):wait()
	return out.code == 0 and out.stdout or nil
end

local function is_agent(id)
	local f = io.open(state_dir .. "/" .. id)
	if f then
		f:close()
		return true
	end
	return false
end

local function measure(me)
	local ok, list = pcall(vim.json.decode, cli("list", "--format", "json") or "")
	if not ok or type(list) ~= "table" then
		return nil
	end
	local tab
	for _, p in ipairs(list) do
		if p.pane_id == me then
			tab = p.tab_id
		end
	end
	local panes = {}
	for _, p in ipairs(list) do
		if p.tab_id == tab then
			table.insert(panes, {
				id = p.pane_id,
				x = p.left_col,
				y = p.top_row,
				w = p.size.cols,
				h = p.size.rows,
				active = p.is_active,
				agent = p.pane_id ~= me and is_agent(p.pane_id),
			})
		end
	end
	return panes
end

local function find(panes, id)
	for _, p in ipairs(panes) do
		if p.id == id then
			return p
		end
	end
end

local function bands(panes, key)
	local groups, keys = {}, {}
	for _, p in ipairs(panes) do
		if p.agent then
			if not groups[p[key]] then
				groups[p[key]] = {}
				table.insert(keys, p[key])
			end
			table.insert(groups[p[key]], p)
		end
	end
	table.sort(keys)
	local out = {}
	for _, k in ipairs(keys) do
		local band = groups[k]
		table.sort(band, function(x, y)
			return key == "y" and x.x < y.x or key == "x" and x.y < y.y
		end)
		table.insert(out, band)
	end
	return out
end

local function grid_right(panes)
	local right
	for _, p in ipairs(panes) do
		if p.agent then
			right = math.max(right or 0, p.x + p.w)
		end
	end
	return right
end

local function try(me, axis, edge, target)
	local panes = measure(me)
	if not panes then
		return
	end
	local pos = axis == "x" and "x" or "y"
	local size = axis == "x" and "w" or "h"
	local before, after = {}, {}
	for _, p in ipairs(panes) do
		if p[pos] + p[size] == edge then
			table.insert(before, p)
		elseif p[pos] == edge + 1 then
			table.insert(after, p)
		end
	end
	local candidates = {}
	for _, group in ipairs({ before, after }) do
		for _, p in ipairs(group) do
			if not p.agent then
				table.insert(candidates, { pane = p, side = group == before and "before" or "after" })
			end
		end
	end
	for _, group in ipairs({ before, after }) do
		for _, p in ipairs(group) do
			if p.agent then
				table.insert(candidates, { pane = p, side = group == before and "before" or "after" })
			end
		end
	end
	local amount = math.abs(target - edge)
	local forward = axis == "x" and "Right" or "Down"
	local back = axis == "x" and "Left" or "Up"
	local dir, undo = target > edge and forward or back, target > edge and back or forward
	for _, c in ipairs(candidates) do
		cli("activate-pane", "--pane-id", tostring(c.pane.id))
		cli("adjust-pane-size", "--pane-id", tostring(c.pane.id), "--amount", tostring(amount), dir)
		local now = find(measure(me) or {}, c.pane.id)
		local moved = now
			and (c.side == "before" and now[pos] + now[size] == target or c.side == "after" and now[pos] == target + 1)
		if moved then
			return true
		end
		cli("adjust-pane-size", "--pane-id", tostring(c.pane.id), "--amount", tostring(amount), undo)
	end
end

local function mark()
	local f = io.open(state_dir .. "/balancing", "w")
	if f then
		f:write(os.time(), "\n")
		f:close()
	end
end

local busy = false

local function steps(ps, me, size)
	local plan = { { axis = "x", target = size.sidebar_edge, edge = function(now)
		local s = find(now, me)
		return s and s.x + s.w
	end } }
	if not size.grid_width then
		return plan
	end
	if size.others then
		table.insert(plan, { axis = "x", target = size.grid_left + size.grid_width, edge = grid_right })
	end
	for r, row in ipairs(bands(ps, "y")) do
		local k = #row
		local w = math.floor((size.grid_width - (k - 1)) / k)
		for j = 1, k - 1 do
			table.insert(plan, { axis = "x", target = size.grid_left + j * w + (j - 1), edge = function(now)
				local band = bands(now, "y")[r]
				local p = band and band[j]
				return p and p.x + p.w
			end })
		end
	end
	for c, col in ipairs(bands(ps, "x")) do
		local m = #col
		local h = math.floor((size.bottom - size.top - (m - 1)) / m)
		for j = 1, m - 1 do
			table.insert(plan, { axis = "y", target = size.top + j * h + (j - 1), edge = function(now)
				local band = bands(now, "x")[c]
				local p = band and band[j]
				return p and p.y + p.h
			end })
		end
	end
	return plan
end

function M.balance(sidebar_width)
	local me = tonumber(vim.env.WEZTERM_PANE or "")
	if busy or not me then
		return
	end
	local panes = measure(me)
	local self = panes and find(panes, me)
	if not self then
		return
	end
	busy = true
	local active, total = nil, 0
	for _, p in ipairs(panes) do
		if p.active then
			active = p.id
		end
		total = math.max(total, p.x + p.w)
	end
	local size = { sidebar_edge = self.x + (sidebar_width or self.w) }
	local right = grid_right(panes)
	if right then
		local left, others, top, bottom = right, 0, nil, 0
		for _, p in ipairs(panes) do
			if p.agent then
				left = math.min(left, p.x)
				top = math.min(top or p.y, p.y)
				bottom = math.max(bottom, p.y + p.h)
			elseif p.id ~= me and p.x >= right then
				others = math.max(others, p.x + p.w - right - 1)
			end
		end
		local rest = total - size.sidebar_edge - 1
		size.grid_left = size.sidebar_edge + 1
		size.grid_width = others > 0 and math.floor((rest - 1) * (right - left) / (right - left + others) + 0.5) or rest
		size.others = others > 0
		size.top, size.bottom = top, bottom
	end
	local moved = false
	for _ = 1, 4 do
		local settled = true
		for _, step in ipairs(steps(measure(me) or {}, me, size)) do
			local now = measure(me)
			local edge = now and step.edge(now)
			if edge and edge ~= step.target then
				settled, moved = false, true
				mark()
				try(me, step.axis, edge, step.target)
			end
		end
		if settled then
			break
		end
	end
	if moved and active then
		cli("activate-pane", "--pane-id", tostring(active))
		mark()
	end
	busy = false
end

return M
